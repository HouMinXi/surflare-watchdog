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
[ISP Modem 192.168.1.1] (PPPoE passthrough)
      |
      eth0 (WAN, 192.168.1.100 modem-access)
      |
[N100 iStoreOS]  pppoe-wan (100.65.x.x)
      |
      br-lan (192.168.100.1/24)
      +-- eth1/eth2/eth3 (bridge)
            |
            LAN devices (.2 mesh, .10 x500, .11 admin-PC,
                          .147 Mac/AnyConnect, .212 vivo, ...)
```

## nftables Architecture (Rule Mode)

### Packet Flow: LAN Device to Internet

```
LAN device
  |
  v
+-------------------------------------------------------+
| sw_lan_tproxy prerouting (mangle-10)                  |
|  1. private dest? ---------> return (direct)          |
|  2. in bypass_devices? ----> return (empty in rule)   |
|  3. in auto_bypass? -------> return (AnyConnect)      |
|  4. DTLS UDP/443 0xFEFD? --> add auto_bypass, return  |
|  5. TCP? ------------------> tproxy :10800 (mark 0x1) |
|  6. UDP/443 (QUIC)? -------> tproxy :10800 (mark 0x1) |
|  7. other UDP? ------------> fall through (accept)     |
+-------------------------------------------------------+
  |                              |
  | (non-tproxy'd)               | (tproxy'd TCP + QUIC)
  v                              v
+-----------------------------+  surflare-proxy (:10800)
| killswitch forward (-10)    |    |
|  bypass_ipv4 (CN)? -> accept|    +-> CN dest: direct ISP
|  bypass_src? --------> accept|    +-> non-CN: VPN tunnel
|  lan_ranges? --------> accept|
|  NTP UDP/123? -------> accept|
|  log ks-fwd-mon             |
|  IPv6: reject icmpv6        |
|  IPv4: reject icmp          |
+-----------------------------+
```

### Packet Flow: Router to Internet

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

### nftables Tables Summary

| Table | Chain | Priority | Role |
|-------|-------|----------|------|
| `ip sw_lan_tproxy` | prerouting | mangle-10 | LAN TCP + QUIC to surflare-proxy |
| `ip dns_enforce` | prerouting | mangle-20 | Force LAN DNS through router |
| `inet surflare` | output | mangle | Router traffic to surflare-proxy |
| `inet surflare` | prerouting | mangle | tproxy marked packets to :10800 |
| `inet killswitch` | output | filter+20 | Router leak protection (policy drop) |
| `inet killswitch` | forward | filter-10 | LAN leak protection + IP audit log |
| `inet surflare_moat` | prerouting | raw | TCP fingerprint detection |
| `inet fw4` | forward | filter | OpenWrt zone firewall (policy drop) |

### Key difference from global mode

In global mode, `_setup_chnroute()` loads CN CIDRs into the `inet surflare`
output chain as kernel-level accept rules.  In rule mode, surflare-proxy
handles the CN/non-CN split at the application layer, so no cn_ipv4 accept
rules are added to the surflare output chain.

`bypass_ipv4` in the killswitch is populated in both modes (VPN-down
resilience + LAN CN UDP direct routing).  `bypass_devices` is empty in
rule mode (proxy handles CN; no per-device MAC bypass needed).

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

This log is critical for auditing which LAN devices attempted to access
foreign destinations during VPN downtime.  CN traffic (matched by
`bypass_ipv4`) is accepted silently -- only non-CN traffic triggers the
log + REJECT.

## Configuration

Rule mode is the default for router platforms.  No explicit configuration
needed -- `MODE=""` resolves to `rule` when `PLATFORM=router`.

To verify on a running system:

```bash
# Check mode
grep '^MODE=' /usr/local/sbin/surflare_watchdog.sh

# Verify surflare-proxy is in Smart Routing mode
curl -s http://127.0.0.1:10800/api/config 2>/dev/null | grep -o '"mode":"[^"]*"'
```
