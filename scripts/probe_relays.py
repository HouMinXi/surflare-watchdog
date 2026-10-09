#!/usr/bin/env python3
"""probe_relays.py -- Surflare relay/exit chain diagnostic probe.

Runs on the router (OpenWrt python3-light) or any host that can reach the
relays. Reads the live sing-box config, so no credentials are stored here.

Modes:
  map    -- list relays and the active exit chain group (offline)
  quick  -- TCP+TLS handshake latency to each relay (CN -> relay leg)
  chain  -- HTTP CONNECT through each relay to a target (relay -> internet leg)
  exit   -- full production chain: relay -> exit (socks5 or http) -> target

Examples:
  python3 probe_relays.py map
  python3 probe_relays.py quick --samples 3
  python3 probe_relays.py exit --samples 5 --target 1.1.1.1:443

Stdlib only. Deliberately avoids logging / concurrent.futures / statistics,
which are missing from OpenWrt python3-light. Credentials read from the
config are never printed.
"""
import argparse
import base64
import json
import re
import socket
import ssl
import sys
import threading
import time

DEFAULT_CONFIG = "/tmp/singbox-config-patched.json"
DEFAULT_TARGET = "1.1.1.1:443"

RELAY_TAG = re.compile(r"^public_\d+$")
GROUP_TAG = re.compile(r"^mh_via_.+_to_.+$")

# socks5 reply codes (RFC 1928)
SOCKS_REP = {
    0x00: "ok",
    0x01: "general-failure",
    0x02: "not-allowed",
    0x03: "net-unreachable",
    0x04: "host-unreachable",
    0x05: "conn-refused",
    0x06: "ttl-expired",
    0x07: "cmd-unsupported",
    0x08: "addr-unsupported",
}


class Relay:
    """One public relay outbound (http proxy over TLS)."""

    # A relay is a value bag; the argument count mirrors the config fields.
    # pylint: disable=too-many-arguments,too-many-positional-arguments
    # pylint: disable=too-few-public-methods
    __slots__ = ("host", "password", "port", "tag", "tls", "user")

    def __init__(self, tag, host, port, user, password, tls):
        self.tag = tag
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.tls = tls


class ExitMember:
    """One relay->exit chain member of the active urltest group."""

    # pylint: disable=too-many-arguments,too-many-positional-arguments
    # pylint: disable=too-few-public-methods
    __slots__ = ("host", "kind", "password", "port", "relay_tag", "tag", "user")

    def __init__(self, tag, relay_tag, host, port, kind, user, password):
        self.tag = tag
        self.relay_tag = relay_tag
        self.host = host
        self.port = port
        self.kind = kind  # "socks" or "http"
        self.user = user
        self.password = password


def parse_config(path):
    """Extract relays and the active exit chain group from a sing-box config.

    Returns (relays, group_tag, members). members is empty when no
    mh_via_*_to_* group exists (e.g. direct single-hop session).
    """
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    outbounds = data.get("outbounds", [])
    by_tag = {}
    for ob in outbounds:
        tag = ob.get("tag", "")
        if tag:
            by_tag[tag] = ob

    relays = []
    for ob in outbounds:
        tag = ob.get("tag", "")
        if ob.get("type") == "http" and RELAY_TAG.match(tag):
            relays.append(Relay(
                tag=tag,
                host=ob.get("server", ""),
                port=int(ob.get("server_port", 443)),
                user=ob.get("username", ""),
                password=ob.get("password", ""),
                tls=bool(ob.get("tls", {}).get("enabled")),
            ))

    group_tag = ""
    members = []
    groups = [o for o in outbounds if GROUP_TAG.match(o.get("tag", ""))]
    if groups:
        # The live session has exactly one chain group; if several exist
        # (stale config), the biggest one is the active pool.
        groups.sort(key=lambda g: len(g.get("outbounds", [])), reverse=True)
        group = groups[0]
        group_tag = group.get("tag", "")
        for member_tag in group.get("outbounds", []):
            mob = by_tag.get(member_tag)
            if not mob:
                continue
            detour = mob.get("detour", "")
            # Live configs detour chain members via the relay's
            # "udp_public_NN" twin; the plain "public_NN" outbound is the
            # http relay we probe.
            detour = detour.removeprefix("udp_")
            members.append(ExitMember(
                tag=member_tag,
                relay_tag=detour,
                host=mob.get("server", ""),
                port=int(mob.get("server_port", 0)),
                kind=mob.get("type", "http"),
                user=mob.get("username", ""),
                password=mob.get("password", ""),
            ))
    return relays, group_tag, members


def _b64(user, password):
    raw = f"{user}:{password}"
    return base64.b64encode(raw.encode("utf-8")).decode("ascii")


def _tcp_connect(host, port, timeout):
    sock = socket.create_connection((host, port), timeout=timeout)
    sock.settimeout(timeout)
    return sock


def _parse_target(target):
    """Split "host:port"; IPv6 literals use the [::1]:443 form."""
    if target.startswith("["):
        host, sep, rest = target[1:].partition("]:")
        if not sep:
            raise ValueError(f"invalid target {target!r} (want [v6]:port)")
        return host, int(rest)
    host, port = target.rsplit(":", 1)
    return host, int(port)


def _tls_wrap(sock, host, insecure=True):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    if insecure:
        # Latency probe only: the production config marks these hops
        # insecure:true (IP-based SNI), and the probe sends no user data
        # beyond a CONNECT to the fixed target. Verification would add
        # failure modes unrelated to what we measure.
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    return ctx.wrap_socket(sock, server_hostname=host or None)


def _http_connect(sock, host, port, user, password, timeout):
    # pylint: disable=too-many-arguments,too-many-positional-arguments
    """Issue a HTTP CONNECT on an already-connected socket."""
    sock.settimeout(timeout)
    req = (
        f"CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n"
        f"Proxy-Authorization: Basic {_b64(user, password)}\r\n\r\n"
    )
    sock.sendall(req.encode("ascii"))
    buf = _recv_headers(sock)
    status = buf.split(b"\r\n", 1)[0].decode("latin-1")
    parts = status.split()
    if len(parts) < 2 or parts[1] != "200":
        raise OSError(f"CONNECT rejected: {status}")
    return buf.split(b"\r\n\r\n", 1)[1]


def _recv_exact(sock, n):
    """Read exactly n bytes; TCP may split a reply across recv() calls."""
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise OSError("connection closed by peer")
        buf += chunk
    return buf


def _recv_headers(sock, limit=65536):
    """Read until CRLFCRLF; headers may arrive in fragments."""
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise OSError("connection closed by peer")
        if len(buf) + len(chunk) > limit:
            raise OSError("CONNECT response headers too large")
        buf += chunk
    return buf


def _socks5_addr(host):
    """Encode host as a socks5 ATYP address field (RFC 1928 section 5)."""
    try:
        return b"\x01" + socket.inet_pton(socket.AF_INET, host)
    except OSError:
        pass
    try:
        return b"\x04" + socket.inet_pton(socket.AF_INET6, host)
    except OSError:
        pass
    encoded = host.encode("idna")
    if len(encoded) > 255:
        raise OSError("target hostname too long for socks5")
    return b"\x03" + bytes([len(encoded)]) + encoded


def _socks5_auth_and_connect(sock, host, port, user, password):
    """socks5 username/password auth + CONNECT. Returns the rep code."""
    sock.sendall(b"\x05\x01\x02")
    resp = _recv_exact(sock, 2)
    if resp[0] != 0x05:
        raise OSError("bad socks5 greeting")
    if resp[1] == 0xFF:
        raise OSError("socks5: no acceptable auth method")
    if resp[1] == 0x02:
        u = user.encode("utf-8")
        p = password.encode("utf-8")
        sock.sendall(b"\x01" + bytes([len(u)]) + u + bytes([len(p)]) + p)
        auth = _recv_exact(sock, 2)
        if auth[1] != 0x00:
            # Distinct from a CONNECT rep:02 (policy denial at the exit):
            # this means the exit rejected our credentials.
            raise OSError("socks5 auth rejected by exit")
    elif resp[1] != 0x00:
        raise OSError(f"socks5: unsupported auth method 0x{resp[1]:02x}")
    sock.sendall(b"\x05\x01\x00" + _socks5_addr(host)
                 + port.to_bytes(2, "big"))
    head = _recv_exact(sock, 4)
    if head[0] != 0x05:
        raise OSError("bad socks5 reply")
    return head[1]


def probe_quick(relay, timeout):
    """TCP connect + TLS handshake to the relay itself.

    TCP alone is useless here: on the router the tproxy accepts the socket
    locally, so only a completed TLS handshake proves the relay answered.
    """
    t0 = time.monotonic()
    sock = _tcp_connect(relay.host, relay.port, timeout)
    try:
        if relay.tls:
            ts = time.monotonic()
            tls = _tls_wrap(sock, relay.host)
            tls.close()
            tls_ms = int((time.monotonic() - ts) * 1000)
            return {"ok": True, "tcp_ms": int((ts - t0) * 1000),
                    "tls_ms": tls_ms,
                    "total_ms": int((ts - t0) * 1000) + tls_ms,
                    "error": ""}
        tcp_ms = int((time.monotonic() - t0) * 1000)
        return {"ok": True, "tcp_ms": tcp_ms,
                "tls_ms": 0, "total_ms": tcp_ms, "error": ""}
    finally:
        try:
            sock.close()
        except OSError:
            pass


def probe_chain(relay, target_host, target_port, timeout):
    """CONNECT through the relay, then TLS to the target through the tunnel.

    hs_ms is the TLS handshake time to the relay itself; it is 0 for a
    plaintext relay (no relay TLS layer exists to measure).
    """
    t0 = time.monotonic()
    sock = _tcp_connect(relay.host, relay.port, timeout)
    try:
        if relay.tls:
            sock = _tls_wrap(sock, relay.host)
        t_hs = time.monotonic()
        try:
            _http_connect(sock, target_host, target_port,
                          relay.user, relay.password, timeout)
        except OSError as exc:
            # Keep the rejection message (407/403/closed) for the report.
            return {"ok": False,
                    "hs_ms": int((t_hs - t0) * 1000),
                    "proxy_connect_ms": 0, "target_tls_ms": 0,
                    "total_ms": int((time.monotonic() - t0) * 1000),
                    "error": str(exc)}
        t_conn = time.monotonic()
        if relay.tls:
            # The relay transport is already TLS; stacking a second TLS
            # layer fails the inner handshake (both layers read the same
            # stream). CONNECT 200 already proves relay->target
            # reachability, so skip the inner wrap here.
            t_tls = t_conn
        else:
            tls = _tls_wrap(sock, target_host)
            t_tls = time.monotonic()
            tls.close()
        return {"ok": True,
                "hs_ms": int((t_hs - t0) * 1000),
                "proxy_connect_ms": int((t_conn - t_hs) * 1000),
                "target_tls_ms": int((t_tls - t_conn) * 1000),
                "total_ms": int((t_tls - t0) * 1000), "error": ""}
    finally:
        try:
            sock.close()
        except OSError:
            pass


def probe_exit(member, relay, target_host, target_port, timeout):
    """Full production chain: relay -> exit -> target.

    Handles both exit flavors seen in the wild: socks5 (dedicated IP) and
    http (city nodes). Returns the socks5 rep code when applicable.
    """
    t0 = time.monotonic()
    sock = _tcp_connect(relay.host, relay.port, timeout)
    rep = -1
    try:
        if relay.tls:
            sock = _tls_wrap(sock, relay.host)
        t_hs = time.monotonic()
        t_relay_exit = None
        try:
            _http_connect(sock, member.host, member.port,
                          relay.user, relay.password, timeout)
            t_relay_exit = time.monotonic()
            if member.kind == "socks":
                rep = _socks5_auth_and_connect(sock, target_host,
                                               target_port,
                                               member.user, member.password)
                if rep != 0:
                    return {"ok": False, "rep": rep,
                            "hs_ms": int((t_hs - t0) * 1000),
                            "relay_exit_ms": int((t_relay_exit - t_hs)
                                                 * 1000),
                            "exit_target_ms": 0,
                            "total_ms": int((time.monotonic() - t0) * 1000),
                            "error": f"socks rep:{rep:02x} "
                                     f"({SOCKS_REP.get(rep, 'unknown')})"}
            else:
                _http_connect(sock, target_host, target_port,
                              member.user, member.password, timeout)
        except OSError as exc:
            # Protocol failures (407/403/closed) keep their message so the
            # report can tell a rejection window from a dead hop.
            return {"ok": False, "rep": rep,
                    "hs_ms": int((t_hs - t0) * 1000),
                    "relay_exit_ms": (int((t_relay_exit - t_hs) * 1000)
                                      if t_relay_exit else 0),
                    "exit_target_ms": 0,
                    "total_ms": int((time.monotonic() - t0) * 1000),
                    "error": str(exc)}
        t_exit_target = time.monotonic()
        return {"ok": True, "rep": rep,
                "hs_ms": int((t_hs - t0) * 1000),
                "relay_exit_ms": int((t_relay_exit - t_hs) * 1000),
                "exit_target_ms": int((t_exit_target - t_relay_exit) * 1000),
                "total_ms": int((t_exit_target - t0) * 1000), "error": ""}
    finally:
        try:
            sock.close()
        except OSError:
            pass


def _run_pool(items, fn, samples, threads, key=None):
    """Run fn(item) `samples` times per item across `threads` workers.

    Raw threading: OpenWrt python3-light has no concurrent.futures (its
    logging dependency is stripped). Results are grouped by key(item),
    default item.tag.
    """
    if key is None:
        def key(item):  # default grouping
            return item.tag
    jobs = []
    for item in items:
        for _ in range(samples):
            jobs.append(item)
    results = {}
    lock = threading.Lock()
    idx = [0]

    def worker():
        while True:
            with lock:
                if idx[0] >= len(jobs):
                    return
                item = jobs[idx[0]]
                idx[0] += 1
            try:
                res = fn(item)
            except Exception as exc:  # noqa: BLE001 -- probe must not kill the pool  # pylint: disable=broad-exception-caught
                res = {"ok": False, "error": type(exc).__name__}
            with lock:
                results.setdefault(key(item), []).append(res)

    pool = []
    for _ in range(min(threads, len(jobs))):
        th = threading.Thread(target=worker)
        th.daemon = True
        th.start()
        pool.append(th)
    for th in pool:
        th.join()
    return results


def summarize(results):
    """Per-tag stats: ok/total, mean total_ms over successful samples."""
    out = []
    for tag, samples in results.items():
        oks = [s for s in samples if s.get("ok")]
        total_ms = [s["total_ms"] for s in oks if "total_ms" in s]
        mean_ms = int(sum(total_ms) / len(total_ms)) if total_ms else 0
        errors = {}
        for s in samples:
            if not s.get("ok"):
                key = s.get("error", "?")
                errors[key] = errors.get(key, 0) + 1
        out.append({"tag": tag, "ok": len(oks), "n": len(samples),
                    "mean_ms": mean_ms, "errors": errors})
    out.sort(key=lambda r: (-r["ok"], r["mean_ms"]))
    return out


def cmd_map(args):
    """List relays and the exit chain group (offline)."""
    relays, group_tag, members = parse_config(args.config)
    print(f"config: {args.config}")
    print(f"relays: {len(relays)}")
    if group_tag:
        print(f"exit group: {group_tag} ({len(members)} members)")
        for m in members:
            print(f"  {m.tag:<46} via {m.relay_tag:<12} "
                  f"exit={m.host}:{m.port} ({m.kind})")
    else:
        print("exit group: none (single-hop session)")
    if args.geoip and relays:
        _geoip(relays)
    return 0


def _geoip(relays):
    """Annotate relays with ip-api.com city data (best effort)."""
    body = json.dumps([r.host for r in relays]).encode("ascii")
    # geoip is an optional annotation path; keep the import lazy.
    import urllib.request  # pylint: disable=import-outside-toplevel
    url = ("http://ip-api.com/batch?"
           "fields=query,city,country,org")
    req = urllib.request.Request(url, data=body,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            rows = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:  # noqa: BLE001 -- geoip is best-effort  # pylint: disable=broad-exception-caught
        print(f"geoip lookup failed: {type(exc).__name__}")
        return 1
    by_ip = {row.get("query"): row for row in rows}
    print("geoip:")
    for r in relays:
        row = by_ip.get(r.host, {})
        print(f"  {r.tag:<14} {r.host:<16} {row.get('city', '?')}, "
              f"{row.get('country', '?')} ({row.get('org', '?')})")
    return 0


def _resolve_relays(args):
    relays, group_tag, members = parse_config(args.config)
    if args.only:
        wanted = set(args.only.split(","))
        relays = [r for r in relays if r.tag in wanted]
    if not relays:
        print("no relays matched", file=sys.stderr)
        sys.exit(2)
    return relays, group_tag, members


def _report(rows, samples):
    print(f"{'tag':<14} {'ok':>9} {'mean_ms':>9} errors")
    for row in rows:
        errs = ",".join(f"{k} x{v}" for k, v in row["errors"].items())
        print(f"{row['tag']:<14} {row['ok']:>4}/{samples:<4} "
              f"{row['mean_ms']:>9} {errs}")


def cmd_quick(args):
    """Measure CN->relay TCP+TLS latency per relay."""
    relays, _g, _m = _resolve_relays(args)
    results = _run_pool(
        relays,
        lambda r: probe_quick(r, args.timeout),
        args.samples, args.threads)
    _report(summarize(results), args.samples)
    return 0


def cmd_chain(args):
    """Measure relay->internet reachability via CONNECT."""
    relays, _g, _m = _resolve_relays(args)
    th, tp = _parse_target(args.target)
    results = _run_pool(
        relays,
        lambda r: probe_chain(r, th, tp, args.timeout),
        args.samples, args.threads)
    _report(summarize(results), args.samples)
    return 0


def cmd_exit(args):
    """Measure the full relay->exit->target production chain."""
    relays, group_tag, members = _resolve_relays(args)
    if not members:
        print("no exit group in config (single-hop session?)", file=sys.stderr)
        return 2
    by_tag = {r.tag: r for r in relays}
    pairs = []
    for m in members:
        relay = by_tag.get(m.relay_tag)
        if relay:
            pairs.append((m, relay))
    if not pairs:
        print("exit group members do not resolve to known relays",
              file=sys.stderr)
        return 2
    print(f"exit group: {group_tag} ({len(pairs)} members, "
          f"exit={members[0].host}:{members[0].port} {members[0].kind})")
    th, tp = _parse_target(args.target)
    results = _run_pool(
        pairs,
        lambda pr: probe_exit(pr[0], pr[1], th, tp, args.timeout),
        args.samples, args.threads, key=lambda pr: pr[0].relay_tag)
    _report(summarize(results), args.samples)
    return 0


def build_parser():
    """Build the CLI argument parser."""
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--config", default=DEFAULT_CONFIG,
                   help="sing-box config path (default %(default)s)")
    sub = p.add_subparsers(dest="mode", required=True)
    for name, helptext in (("map", "list relays and exit group"),
                           ("quick", "TLS handshake latency per relay"),
                           ("chain", "CONNECT via relay to target"),
                           ("exit", "full relay -> exit -> target chain")):
        sp = sub.add_parser(name, help=helptext)
        sp.add_argument("--samples", type=int, default=3,
                        help="probe repetitions per relay (default 3)")
        sp.add_argument("--timeout", type=float, default=6.0,
                        help="per-socket timeout seconds (default 6)")
        sp.add_argument("--threads", type=int, default=12,
                        help="worker threads (default 12)")
        sp.add_argument("--only", default="",
                        help="comma-separated relay tags to probe")
        sp.add_argument("--target", default=DEFAULT_TARGET,
                        help="chain target host:port (default %(default)s)")
        sp.add_argument("--geoip", action="store_true",
                        help="map mode: annotate via ip-api.com batch")
    return p


def main(argv=None):
    """CLI entry point."""
    args = build_parser().parse_args(argv)
    if args.mode == "map":
        return cmd_map(args)
    if args.mode == "quick":
        return cmd_quick(args)
    if args.mode == "chain":
        return cmd_chain(args)
    if args.mode == "exit":
        return cmd_exit(args)
    return 2


if __name__ == "__main__":
    sys.exit(main())
