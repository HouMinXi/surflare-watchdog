#!/usr/bin/env python3
"""Load a tproxy template into a network namespace, send one datagram
to the control address from a peer namespace, and report whether it
reaches the control return.

Prints HIT, MISS, SETUP_FAIL or LOAD_FAIL.  Only HIT and MISS are a verdict on
the template; the other two say the probe could not build its sandbox, which
is not the template's fault and must not be reported as one.

The template's control set is filled with 203.0.113.10 and the return
rule gets a counter.  A packet that a rule in front stops never moves
that counter.
"""
import ctypes
import os
import re
import socket
import subprocess
import sys
import time

DEBUG = os.environ.get("CP_DEBUG") == "1"


def note(msg):
    """Timing and outcome, only when someone is asking why a probe lied."""
    if DEBUG:
        sys.stderr.write("[cp %.3f] %s\n" % (time.time(), msg))
        sys.stderr.flush()


libc = ctypes.CDLL(None, use_errno=True)
CLONE_NEWNET = 0x40000000


def sh(*args):
    """Run a command, return the completed process (rc inspected)."""
    return subprocess.run(args, capture_output=True, text=True,
                          check=False)


def main():
    """Load the template, send one datagram, print the verdict."""
    with open(sys.argv[1], encoding="utf-8") as f:
        src = f.read()
    # Tolerate any run of whitespace between the set and the verdict.
    # A literal single-space needle misses '@surflare_control  return'
    # silently and the probe then measures the wrong rule.
    src, n = re.subn(
        r"@surflare_control\s+return", "@surflare_control counter return", src)
    if n == 0:
        print("LOAD_FAIL")
        return
    note("template read, starting veth")
    for cmd in (
        ["ip", "link", "add", "veth0", "type", "veth", "peer", "name", "veth1"],
        ["ip", "link", "set", "veth0", "name", "br-lan"],
        ["ip", "link", "set", "br-lan", "up"],
        ["ip", "addr", "add", "198.51.100.1/24", "dev", "br-lan"],
        ["ip", "addr", "add", "203.0.113.10/32", "dev", "lo"],
        ["ip", "link", "set", "lo", "up"],
    ):
        done = sh(*cmd)
        if done.returncode != 0:
            note("parent setup failed: %s -> %s"
                 % (" ".join(cmd), done.stderr.strip()[:160]))
            print("SETUP_FAIL")
            return
    # Listen on the control address.  The SYN reaches it only if no
    # rule stops or redirects the packet.  A counter on the return can
    # be faked by a decoy rule; a completed handshake cannot.
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("203.0.113.10", 443))
    listener.listen(1)
    # A stopped packet and a slow handshake look the same from here: both leave
    # the listener empty.  The budget is what separates them, and it has to be
    # wide enough that contention cannot manufacture a verdict about the
    # template.
    listener.settimeout(3.0)
    loaded = subprocess.run(
        ["nft", "-f", "-"], input=src, capture_output=True, text=True,
        check=False)
    note("template loaded rc=%s" % loaded.returncode)
    if loaded.returncode != 0:
        note("nft refused it: %s" % loaded.stderr.strip()[:200])
        print("LOAD_FAIL")
        return
    sh("nft", "add", "element", "inet", "sw_lan_tproxy",
       "surflare_control", "{", "203.0.113.10", "}")

    # Three pipes, because the peer has to report what it saw and the parent
    # has to know when it is safe to hand over the link.  Moving veth1 into
    # `pid` before the child has unshared puts it in the parent's namespace:
    # every command in the child then fails, the connect returns ENETUNREACH,
    # and the old probe reported that as "a rule stops the packet".
    ready_r, ready_w = os.pipe()
    go_r, go_w = os.pipe()
    seen_r, seen_w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(ready_r)
        os.close(go_w)
        os.close(seen_r)
        libc.unshare(CLONE_NEWNET)
        os.write(ready_w, b"r")
        os.close(ready_w)
        os.read(go_r, 1)
        verdict = b"U"
        for cmd in (
            ["ip", "link", "set", "lo", "up"],
            ["ip", "link", "set", "veth1", "up"],
            ["ip", "addr", "add", "198.51.100.2/24", "dev", "veth1"],
            ["ip", "route", "add", "203.0.113.10/32", "via", "198.51.100.1"],
        ):
            done = sh(*cmd)
            if done.returncode != 0:
                note("child setup failed: %s -> %s"
                     % (" ".join(cmd), done.stderr.strip()[:160]))
                os.write(seen_w, verdict)
                os._exit(0)
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(3.0)
        t_connect = time.time()
        try:
            sock.connect(("203.0.113.10", 443))
            verdict = b"C"
            note("child connected in %.3fs" % (time.time() - t_connect))
        except ConnectionRefusedError:
            verdict = b"R"
            note("child refused after %.3fs" % (time.time() - t_connect))
        except TimeoutError:
            # TimeoutError is an OSError subclass, so this has to come first:
            # silence is what a dropped packet looks like, and calling it a
            # broken sandbox would replace a real MISS with an excuse.
            verdict = b"T"
            note("child saw silence for %.3fs" % (time.time() - t_connect))
        except OSError as exc:
            # ENETUNREACH and friends mean the sandbox is wrong, not the
            # template.  Only a timeout is silence, and only silence is a drop.
            verdict = b"U"
            note("child connect failed after %.3fs: %r"
                 % (time.time() - t_connect, exc))
        os.write(seen_w, verdict)
        os._exit(0)
    os.close(ready_w)
    os.close(go_r)
    os.close(seen_w)
    os.read(ready_r, 1)          # the child is in its own namespace now
    os.close(ready_r)
    moved = sh("ip", "link", "set", "veth1", "netns", str(pid))
    if moved.returncode != 0:
        note("handover failed: %s" % moved.stderr.strip()[:160])
        os.close(go_w)
        os.waitpid(pid, 0)
        print("SETUP_FAIL")
        return
    os.write(go_w, b"g")
    os.close(go_w)
    t_wait = time.time()
    os.waitpid(pid, 0)
    note("child exited after %.3fs" % (time.time() - t_wait))
    child_saw = os.read(seen_r, 1)
    os.close(seen_r)

    t_accept = time.time()
    try:
        conn, _ = listener.accept()
        conn.close()
        note("accepted %.3fs after the child exited" % (time.time() - t_accept))
        print("HIT")
    except TimeoutError:
        note("nothing to accept %.3fs after the child exited" % (time.time() - t_accept))
        if child_saw == b"U":
            print("SETUP_FAIL")
        else:
            print("MISS")


if __name__ == "__main__":
    main()