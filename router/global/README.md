# Router / Global Mode

All LAN TCP traffic is routed through the VPN tunnel via surflare-proxy;
QUIC (UDP/443) is rejected to force HTTP/2 fallback.  CN-destined
traffic bypasses tproxy at the kernel level
(`cn_direct` / `cn6_direct` sets) so CN apps see a domestic IP.  The
router's own output chain also uses chnroute (`cn_ipv4`/`cn_ipv6`) for
kernel-level CN bypass.

## When to Use

- Full encryption: every LAN device's non-CN traffic exits through VPN.
- CN apps (bilibili, Taobao, etc.) still need domestic IP for CDN
  acceleration and geo-detection.

## CN Direct Bypass (cn_direct)

LAN traffic to CN destinations bypasses tproxy and routes via ISP direct.
The `cn_direct` / `cn6_direct` sets in the tproxy table are populated by
`_load_tproxy_cn_direct()` from cn_ipv4.txt + cn_ipv4_extra.txt (cloud
CDN) + cn_ipv6.txt after each VPN connect.  This gives CN apps a domestic
IP while non-CN traffic still goes through VPN.

In rule mode these sets are empty (surflare-proxy handles CN split at
the application layer).

## Remaining Limitations

- CN IP list is static (updated weekly by `surflare_route_updater.sh`).
  A CN service using a non-CN IP (e.g. CN company with US CDN) will
  still go through VPN.
- CN UDP on non-standard ports (gaming, VoIP) passes through the
  killswitch `bypass_ipv4` directly (not tproxied, not through VPN).
  This is correct behavior -- these connections see the domestic ISP IP.

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

## nftables Chain Priority Map

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
|   3. in bypass_devices? ----------> return (MAC bypass)   |
|   4. in auto_bypass? -------------> return (AnyConnect)   |
|   5. in cn_direct? ---------------> return (CN ISP)  ***  |
|   6. in cn6_direct? --------------> return (CN ISP)  ***  |
|   7. DTLS 1.2 UDP/443 0xFEFD? ----> auto_bypass, return  |
|   8. IPv4 TCP? ---> tproxy ip to :10800   (mark 0x1)     |
|   9. IPv6 TCP? ---> tproxy ip6 to :10800  (mark 0x1)     |
|  10. IPv4 QUIC? --> reject (ICMP port-unreachable)        |
|  11. IPv6 QUIC? --> reject (ICMPv6 port-unreachable)      |
|  12. other UDP? --> fall through (accept)                 |
+----------------------------------------------------------+
  |                              |
  | (non-tproxy'd / CN direct)   | (tproxy'd TCP only)
  v                              v
+-----------------------------+  surflare-proxy (:10800)
| killswitch forward (-10)    |    |
|  established/related accept |    +-> ALL: VPN tunnel
|  server_ips? ---------> accept       (no CN split at proxy)
|  bypass_ipv4 (CN)? ---> accept
|  bypass_src? ---------> accept
|  lan_ranges? ---------> accept
|  NTP UDP/123? --------> accept
|  non-UDP? log "ks-fwd-mon:" (5/s)
|  IPv6: reject icmpv6
|  IPv4: reject icmp
+-----------------------------+

*** cn_direct/cn6_direct: populated from cn_ipv4.txt + cn_ipv4_extra.txt
    + cn_ipv6.txt after each VPN connect.  CN traffic returns here and
    goes ISP direct (bypasses both tproxy and VPN).
```

## Packet Flow: Router to Internet

```
Router process (opkg, curl, SSH)
  |
  v
+-----------------------------------------------+
| inet surflare output (mangle)                 |
|  mark 0xff? -> accept (tunnel)                |
|  server ports? -> accept                      |
|  loopback? -> accept                          |
|  DNS? -> mark 0x1                             |
|  private? -> accept                           |
|  cn_ipv4? -> accept (kernel CN bypass)   ***  |
|  TCP/UDP? -> mark 0x1 -> surflare-proxy       |
+-----------------------------------------------+
  |
  v
+-----------------------------------------------+
| killswitch output (filter+20, policy DROP)    |
|  server_ips? -> accept                        |
|  mark 0xff/0x1? -> accept                     |
|  bypass_ipv4 (CN)? -> accept                  |
|  lan_ranges? -> accept                        |
|  UDP -> reject (QUIC fallback)                |
|  IPv6 -> reject                               |
|  log ks-drop + DROP                           |
+-----------------------------------------------+

*** cn_ipv4 accept: global-only. Router's own CN traffic bypasses
    surflare-proxy at kernel level (opkg, curl to CN mirrors).
```

## nftables Tables Summary

| Table | Family | Chain | Priority | Role |
|-------|--------|-------|----------|------|
| `surflare_moat` | inet | prerouting | raw | WAN TCP FIN/RST monitor (window 78, log only) |
| `dns_enforce` | ip | prerouting | mangle-20 | Force LAN DNS through router (silent reject) |
| `sw_lan_tproxy` | inet | prerouting | mangle-10 | Dual-stack LAN TCP tproxy + QUIC reject + cn_direct bypass |
| `surflare` | inet | output, prerouting | mangle | Router traffic routing + cn_ipv4 accept |
| `killswitch` | inet | forward | filter-10 | LAN leak protection + IP audit log |
| `killswitch` | inet | output | filter+20 | Router leak protection (policy drop) |
| `fw4` | inet | forward | filter | OpenWrt zone firewall (policy drop) |

## Key Difference from Rule Mode

Two CN bypass mechanisms exist only in global mode:

1. **LAN cn_direct bypass** (`sw_lan_tproxy`): `_load_tproxy_cn_direct()`
   populates `cn_direct` / `cn6_direct` sets from cn_ipv4.txt +
   cn_ipv4_extra.txt + cn_ipv6.txt after each VPN connect.  CN-destined
   LAN traffic returns before tproxy, goes through killswitch forward
   (`bypass_ipv4` accepts it), exits via ISP direct.

2. **Router cn_ipv4 bypass** (`inet surflare` output): `_setup_chnroute()`
   inserts `ip daddr @cn_ipv4 accept` so the router's own CN traffic
   (opkg, curl) bypasses surflare-proxy at kernel level.

In rule mode, surflare-proxy handles CN/non-CN split at the application
layer.  Both `cn_direct` sets and `cn_ipv4` accept rules are absent.

`bypass_devices` is populated from `router/global/bypass-macs.conf`
(deployed to `/etc/surflare/bypass-macs.conf` by install.sh).  Bypassed
devices skip tproxy entirely -- ALL traffic (CN and non-CN) goes ISP
direct.  Their IPs are synced to killswitch `bypass_src` (forward
accept) and dns_enforce `vpn_bypass` (DNS exemption).  **WARNING:
bypassed devices have NO VPN protection for non-CN traffic.**

In rule mode, `bypass_devices` is empty (code guard skips population).

## VPN Downtime Behavior

- Router's own CN traffic: continues via `bypass_ipv4` (direct ISP route).
- LAN CN traffic: continues via killswitch forward `bypass_ipv4`.
- Non-CN UDP (router + LAN): silently **REJECT**ed (tproxy is TCP-only,
  so non-CN UDP has no VPN path -- killswitch blocks it by design).
- Non-CN non-UDP reaching killswitch: logged via `ks-fwd-mon` before
  reject -- this means TCP escaped tproxy, worth investigating.

## Configuration

Set `MODE="global"` in `surflare_watchdog.sh` (default for router is
`rule`, so global mode requires explicit override):

```bash
# In surflare_watchdog.sh, before PLATFORM detection:
MODE="global"
```

Or via install.sh sed on deployment:

```bash
sudo sed -i 's/^MODE=""/MODE="global"/' /usr/local/sbin/surflare_watchdog.sh
```

To verify on a running system:

```bash
# Check mode
grep '^MODE=' /usr/local/sbin/surflare_watchdog.sh

# Verify cn_direct sets are populated (global only, ~4700 CIDRs)
nft list set inet sw_lan_tproxy cn_direct | grep -c "/"

# Verify cn_ipv4 accept in surflare output
nft list chain inet surflare output | grep cn_ipv4
```
