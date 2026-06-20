# Router / Rule Mode (Smart Routing)

surflare-proxy splits traffic at the application layer: CN destinations
route directly via ISP, non-CN destinations route through the VPN tunnel.
This is the default mode for router deployments.

## When to Use

- LAN devices need CN apps (bilibili, xiaohongshu, Taobao, etc.) to
  detect a domestic IP address.
- Only non-CN traffic needs VPN protection.

## Network Topology

```
ISP (PPPoE)
    |
Modem (192.168.1.1, bridge mode)
    |
    | eth0 (192.168.1.100, modem management direct)
    |
N100 iStoreOS (8GB RAM, Intel J4125)
    |
    +-- pppoe-wan (100.65.x.x, PPPoE dial-up)
    +-- br-lan   (192.168.100.1/24, IPv6: 240e:xxx::1/60)
    |
    +-- WTA301 mesh AP   (.2 master, .3 child)
    +-- x500 Fedora      (.10)
    +-- admin-PC Windows (.11, hardcoded DNS)
    +-- Mac              (.147, AnyConnect DTLS auto_bypass)
    +-- Xiaomi 17 Ultra  (.160)
    +-- vivo X200 Pro    (.212)
    +-- houminxi phone   (.246)
```

eth0 directly reaches modem management (192.168.1.0/24), bypasses PPPoE.
The killswitch has explicit rules to allow this traffic.

## nftables Chain Priority Map

All tables that a LAN packet traverses, in priority order:

```
Hook        Table              Priority    Policy
==========  =================  ==========  ======
prerouting  surflare_moat      raw         accept
prerouting  dns_enforce        mangle-20   accept
prerouting  sw_lan_tproxy      mangle-10   accept
prerouting  surflare           mangle      accept
forward     killswitch         filter-10   accept
forward     surflare           mangle      accept
forward     fw4                filter      drop
output      surflare           mangle      accept
output      killswitch         +20         drop
```

## Packet Flow: LAN Device to Internet

```
LAN device (TCP/QUIC/DNS)
  |
  v
+----------------------------------------------------------+
| surflare_moat prerouting (raw)                           |
|   WAN-only (iifname != "br-lan"):                        |
|   detect upstream-injected FIN/RST (window 78)           |
|   counter + log "moat:" (no drop by default)             |
+----------------------------------------------------------+
  |
  v
+----------------------------------------------------------+
| dns_enforce prerouting (mangle-20)                       |
|   vpn_bypass set? --------> accept (corporate VPN devs)  |
|   DNS (UDP/TCP 53)? ------> reject (silent, no log)      |
|   non-DNS? ---------------> fall through                  |
+----------------------------------------------------------+
  |
  v
+----------------------------------------------------------+
| sw_lan_tproxy prerouting (mangle-10), table inet         |
|   1. IPv4 private dest? ----------> return (direct)      |
|   2. IPv6 private dest? ----------> return (direct)      |
|   3. in bypass_devices? ----------> return (empty/rule)   |
|   4. in auto_bypass? -------------> return (AnyConnect)   |
|   5. in cn_direct? ---------------> return (empty/rule)   |
|   6. in cn6_direct? --------------> return (empty/rule)   |
|   7. DTLS 1.2 UDP/443 0xFEFD? ----> auto_bypass, return  |
|   8. IPv4 TCP? ---> tproxy ip to :10800   (mark 0x1)     |
|   9. IPv6 TCP? ---> tproxy ip6 to :10800  (mark 0x1)     |
|  10. IPv4 QUIC? --> reject (ICMP port-unreachable)        |
|  11. IPv6 QUIC? --> reject (ICMPv6 port-unreachable)      |
|  12. other UDP? --> fall through (accept)                 |
+----------------------------------------------------------+
  |                              |
  | (non-tproxy'd)               | (tproxy'd TCP only)
  v                              v
+-----------------------------+  surflare-proxy (:10800)
| killswitch forward (-10)    |    |
|  established/related accept |    +-> CN dest: direct ISP
|  server_ips? ---------> accept    +-> non-CN: VPN tunnel
|  bypass_ipv4 (CN)? ---> accept
|  bypass_src? ---------> accept
|  lan_ranges? ---------> accept
|  NTP UDP/123? --------> accept
|  log "ks-fwd-mon:" (5/s burst 10)
|  IPv6: reject icmpv6
|  IPv4: reject icmp
+-----------------------------+
```

### Rule mode tproxy notes

- `cn_direct` / `cn6_direct` sets exist in the nft file but remain empty.
  The return rules never match; surflare-proxy handles CN split at the
  application layer.  Sets are present for structural parity with global
  mode (same table schema, different population).
- `bypass_devices` is empty: `_update_bypass_devices()` has a `MODE != "global"`
  guard that skips population in rule mode.  `router/rule/bypass-macs.conf`
  is comments-only; even if MACs were listed, the code guard prevents activation.
- `auto_bypass` is IPv4-only (`type ipv4_addr`).  DTLS detection rule
  uses `meta nfproto ipv4` to avoid IPv6 false matches.

## Packet Flow: Router to Internet

```
Router process (opkg, curl, SSH)
  |
  v
+-----------------------------------------------+
| inet surflare output (mangle)                 |
|  mark 0xff (surflare tunnel)? -> accept       |
|  server ports? -> accept                      |
|  loopback? -> accept                          |
|  DNS? -> mark 0x1                             |
|  private? -> accept                           |
|  TCP/UDP? -> mark 0x1 -> surflare-proxy       |
+-----------------------------------------------+
  |
  v
+-----------------------------------------------+
| killswitch output (filter+20, policy DROP)    |
|  server_ips? -> accept                        |
|  mark 0xff/0x1? -> accept                     |
|  bypass_ipv4 (CN)? -> accept (VPN-down only)  |
|  lan_ranges? -> accept                        |
|  UDP -> reject (QUIC fallback)                |
|  IPv6 -> reject                               |
|  log ks-drop + DROP                           |
+-----------------------------------------------+
```

## nftables Tables Summary

| Table | Family | Chain | Priority | Role |
|-------|--------|-------|----------|------|
| `surflare_moat` | inet | prerouting | raw | WAN TCP fingerprint detection (FIN/RST window 78) |
| `dns_enforce` | ip | prerouting | mangle-20 | Force LAN DNS through router (silent reject) |
| `sw_lan_tproxy` | inet | prerouting | mangle-10 | Dual-stack LAN TCP tproxy + QUIC reject |
| `surflare` | inet | output, prerouting | mangle | Router traffic routing + tproxy dispatch |
| `killswitch` | inet | forward | filter-10 | LAN leak protection + IP audit log |
| `killswitch` | inet | output | filter+20 | Router leak protection (policy drop) |
| `fw4` | inet | forward | filter | OpenWrt zone firewall (policy drop) |

## Key Difference from Global Mode

In global mode, `_load_tproxy_cn_direct()` populates the `cn_direct` /
`cn6_direct` sets from cn_ipv4.txt + cn_ipv4_extra.txt + cn_ipv6.txt,
so CN-destined LAN traffic returns before tproxy and routes via ISP
direct (domestic IP for CDN + geo-detection).

In rule mode, surflare-proxy handles CN/non-CN split at the application
layer.  The `cn_direct` / `cn6_direct` sets remain empty, and no
`cn_ipv4` accept rules are added to the surflare output chain.

`bypass_ipv4` in the killswitch is populated in both modes (VPN-down
resilience + LAN CN UDP direct routing).

## Dual-Stack Tproxy (table inet)

The tproxy table uses `table inet` (not `table ip`) so both IPv4 and
IPv6 TCP are proxied.  QUIC (UDP/443) is rejected (not tproxied) to
force HTTP/2 fallback -- QUIC-over-VPN causes 3s+ TTFB because CDN
anycast selects PoP by VPN exit IP.  Without IPv6 tproxy, Happy
Eyeballs causes LAN devices to prefer IPv6 for dual-stack destinations,
which would bypass the proxy and hit the killswitch forward chain,
producing `ks-fwd-mon` log noise (~49 entries per 2 minutes).

Rules use `meta nfproto ipv4` / `meta nfproto ipv6` to prevent
cross-family matching in the inet table.  The DTLS detection rule is
IPv4-only because `auto_bypass` is `type ipv4_addr`.

## Moat: TCP Fingerprint Detection

`surflare_moat` detects upstream-injected TCP FIN/RST packets by
matching unusual window sizes (32, 64, 78, 128).  The primary target is
window=78, a known GFW fingerprint.

Direction filter: `iifname != "br-lan"` ensures only WAN-originated
packets trigger detection.  Without this filter, normal LAN TCP
closures (iOS/macOS use window=78 for FIN+ACK) produce false positives
(~118 per 2 minutes from LAN devices alone).

Default mode is counter + log only.  Touch
`/run/surflare_watchdog.moat_strict` to enable drop.

## DNS Enforcement

`dns_enforce` silently rejects DNS queries (UDP/TCP port 53) from LAN
devices that bypass the router's DNS.  This prevents DNS leaks from
devices with hardcoded DNS servers (e.g. admin-PC .11 using 8.8.8.8).

No log output: DNS enforcement is a hygiene measure, not an IP leak
indicator.  Logging it would produce noise (148+ entries per minute
from admin-PC alone).

The `vpn_bypass` set exempts corporate VPN devices (e.g. Mac .147) that
need their own DNS for split-tunnel operation.

## Tombstone / Restore Lifecycle

VPN disconnect: each tproxy rule is replaced with a protocol-qualified
reject (TCP -> `reject with tcp reset`, UDP -> bare `reject`).  This
prevents LAN TCP connections from hanging on timeout during VPN outage.

VPN reconnect: the tombstoned table is destroyed and reloaded atomically
from `/etc/surflare-lan-tproxy.nft`.  Any nft load error is captured in
a WARN log (not swallowed).

## VPN Downtime Behavior

- Router's own CN traffic: continues via `bypass_ipv4` (direct ISP route).
- LAN CN traffic: continues via killswitch forward `bypass_ipv4`.
- Non-CN traffic (router + LAN): **REJECT** with `ks-fwd-mon` dmesg log.
  This is the IP leak protection: any LAN device attempting to reach a
  non-CN destination while VPN is down produces a dmesg entry.

## IP Leak Protection Logging

When VPN is down, the killswitch forward chain logs non-CN access attempts:

```
ks-fwd-mon: IN=br-lan OUT=pppoe-wan SRC=192.168.100.212 DST=104.18.32.7 ...
```

CN traffic (matched by `bypass_ipv4`) is accepted silently -- only
non-CN traffic triggers the log + REJECT.

## Configuration

Rule mode is the default for router platforms.  No explicit configuration
needed -- `MODE=""` resolves to `rule` when `PLATFORM=router`.

To verify on a running system:

```bash
# Check mode
grep '^MODE=' /usr/local/sbin/surflare_watchdog.sh

# Verify surflare-proxy is in Smart Routing mode
curl -s http://127.0.0.1:10800/api/config 2>/dev/null | grep -o '"mode":"[^"]*"'

# Verify dual-stack tproxy table
nft list table inet sw_lan_tproxy | head -3

# Check moat detection (should show 0 hits from LAN)
nft list chain inet surflare_moat prerouting | grep counter

# Verify dns-bypass log count (should be 0)
dmesg | grep -c "dns-bypass"
```
