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
|   log FIN/RST with window 78 (CN CDN server closes)     |
|   counter + log "moat:" (passive, no drop)               |
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
|   3. in bypass_devices? ----------> return (MAC list)     |
|   4. in auto_bypass? -------------> return (AnyConnect)   |
|   5. in cn_direct? ---------------> return (CN ISP)       |
|   6. in cn6_direct? --------------> return (CN ISP)       |
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
||  bypass_src? ---------> accept
||  z66 UDP/41641? ------> accept  (Tailscale WG underlay, memory 56)
||  z66 -> derp_asia? ---> accept  (DERP relay TCP/443 + STUN UDP/3478)
||  lan_ranges? ---------> accept
|  NTP UDP/123? --------> accept
|  TCP? log "ks-fwd-mon:" (5/s; ICMP/UDP silent)
|  IPv6: reject icmpv6
|  IPv4: reject icmp
+-----------------------------+
```

### Rule mode tproxy notes

- `cn_direct` / `cn6_direct` are loaded in both modes by
  `_load_tproxy_cn_direct()` (cn_ipv4.txt + extra + cn_ipv6.txt).
  Hits return before tproxy and before UDP/443 reject, so CN QUIC
  goes ISP direct.  Destinations not in the sets still reach
  sing-box in rule mode.
- `derp_asia` (Tailscale DERP sin/tok/hkg node IPs) is returned to the
  WAN before the tproxy rules for z66 (192.168.100.12) only, so z66's
  tailscaled measures and reaches Asia DERP over the ISP path instead of
  hairpinning through the US VPN exit (which pinned its home DERP to sfo
  and forced a 300-430ms relay).  The killswitch forward chain carries a
  same-named set accepting this traffic plus z66's WireGuard UDP/41641,
  outbound-only.  User-adjudicated 2026-09-01 (project memory 56 branch A).
- `bypass_devices` is filled from `/etc/surflare/bypass-macs.conf` in
  both modes (`_update_bypass_devices` has no MODE skip).  N100 live:
  .11 BT, .17 Mac/AnyConnect, .120 work laptop.  The example file in
  `router/rule/bypass-macs.conf` is placeholders only.
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
| `surflare_moat` | inet | prerouting | raw | WAN TCP FIN/RST monitor (window 78, log only) |
| `dns_enforce` | ip | prerouting | mangle-20 | Force LAN DNS through router (silent reject) |
| `sw_lan_tproxy` | inet | prerouting | mangle-10 | Dual-stack LAN TCP tproxy + QUIC reject |
| `surflare` | inet | output, prerouting | mangle | Router traffic routing + tproxy dispatch |
| `killswitch` | inet | forward | filter-10 | LAN leak protection + IP audit log |
| `killswitch` | inet | output | filter+20 | Router leak protection (policy drop) |
| `fw4` | inet | forward | filter | OpenWrt zone firewall (policy drop) |

## Key Difference from Global Mode

`_load_tproxy_cn_direct()` populates `cn_direct` / `cn6_direct` from
cn_ipv4.txt + cn_ipv4_extra.txt + cn_ipv6.txt in **both** modes, so
CN-destined LAN traffic (TCP and UDP/443) returns before tproxy /
QUIC reject and routes via ISP direct.

In rule mode sing-box still splits at the application layer for
destinations **not** in those sets.  Kernel `cn_direct` is additive,
not a substitute.  The surflare output chain still has no `cn_ipv4`
accept rules in rule mode (router-originated CN is a different path).

`bypass_ipv4` in the killswitch is populated in both modes (VPN-down
resilience + LAN CN UDP direct routing).

## Dual-Stack Tproxy (table inet)

The tproxy table uses `table inet` (not `table ip`) so both IPv4 and
IPv6 TCP are proxied.  QUIC (UDP/443) is rejected (not tproxied) to
force HTTP/2 fallback -- QUIC-over-VPN causes 3s+ TTFB because CDN
anycast selects PoP by VPN exit IP.  Without IPv6 tproxy, Happy
Eyeballs causes LAN devices to prefer IPv6 for dual-stack destinations,
which would bypass the proxy and be silently rejected by the
killswitch forward chain.

Rules use `meta nfproto ipv4` / `meta nfproto ipv6` to prevent
cross-family matching in the inet table.  The DTLS detection rule is
IPv4-only because `auto_bypass` is `type ipv4_addr`.

## Moat: WAN TCP FIN/RST Monitor

`surflare_moat` is a passive monitor at the raw prerouting hook.  It
logs WAN-inbound TCP packets that carry FIN or RST with window size 78.
It does NOT drop anything by default -- packets continue through
conntrack normally after being logged.

What triggers it in practice: Chinese CDN servers (Alibaba Cloud /
Tengine, Tencent, etc.) use window=78 on FIN-ACK when closing idle
connections.  When a LAN device connects to a CN server directly (rule
mode routes CN traffic via ISP), the server eventually sends FIN to
close the connection.  If conntrack still has the entry, the FIN is
handled normally AND logged.  If conntrack already expired the entry
(established timeout is 7440s / 2 hours on iStoreOS), the FIN is
logged and then dropped as INVALID by conntrack -- both are harmless.

Direction filter: `iifname != "br-lan"` ensures only WAN-originated
packets trigger detection.  Without this filter, normal LAN TCP
closures (iOS/macOS also use window=78 for FIN+ACK) produce false
positives (~118 per 2 minutes from LAN devices alone).

How to read the logs:

```
moat: SRC=47.96.x.x ... SPT=443 ... ACK FIN   -- CN server closing HTTPS, normal
moat: SRC=x.x.x.x   ... SPT=443 ... ACK RST   -- possible upstream injection
```

FIN from CN server IPs (SPT=443) is normal server behavior.  RST with
window=78 could indicate upstream injection -- the RST counter should
normally stay at 0.

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
- Non-CN UDP (router + LAN): silently **REJECT**ed (tproxy is TCP-only,
  so non-CN UDP has no VPN path -- killswitch blocks it by design).
- Non-CN TCP reaching killswitch: logged via `ks-fwd-mon` before
  reject -- this means TCP escaped tproxy, worth investigating.
  ICMP is rejected silently (Tailscale DERP pings have no VPN path).

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
