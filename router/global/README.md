# Router / Global Mode

All traffic from LAN devices is routed through the VPN tunnel at the
application layer (surflare-proxy).  The kernel output chain uses chnroute
(`cn_ipv4`/`cn_ipv6`) so the router's own processes bypass the VPN for CN
destinations.

## When to Use

- Privacy-focused household: every device's traffic exits through VPN.
- No requirement for CN apps (bilibili, xiaohongshu, etc.) to detect a
  domestic IP address.

## Known Limitations

- **CN apps on LAN devices see a foreign exit IP.**  surflare-proxy forwards
  all tproxy'd TCP through the VPN tunnel without CN/non-CN splitting.
  Apps that check geo-IP (bilibili, xiaohongshu, Taobao) will report "not
  in China" or degrade functionality.
- CN UDP from LAN devices (gaming, video conferencing) passes through the
  killswitch `bypass_ipv4` set and routes directly via ISP.  Only TCP is
  affected by the foreign-IP limitation.

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

## nftables Architecture (Global Mode)

### Packet Flow: LAN Device to Internet

```
LAN device
  |
  v
+-------------------------------------------------------+
| sw_lan_tproxy prerouting (mangle-10)                  |
|  1. private dest? ---------> return (direct)          |
|  2. in bypass_devices? ----> return (Thunder/.11)     |
|  3. in auto_bypass? -------> return (AnyConnect)      |
|  4. DTLS UDP/443 0xFEFD? --> add auto_bypass, return  |
|  5. TCP? ------------------> tproxy :10800 (mark 0x1) |
|  6. UDP/443 (QUIC)? -------> tproxy :10800 (mark 0x1) |
|  7. other UDP? ------------> fall through (accept)     |
+-------------------------------------------------------+
  |                              |
  | (non-tproxy'd / bypass)      | (tproxy'd TCP + QUIC)
  v                              v
+-----------------------------+  surflare-proxy (:10800)
| killswitch forward (-10)    |    |
|  bypass_ipv4 (CN)? -> accept|    +-> ALL traffic: VPN tunnel
|  bypass_src? --------> accept|       (no CN/non-CN split)
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
|  mark 0xff? -> accept (tunnel)                |
|  server ports? -> accept                      |
|  loopback? -> accept                          |
|  DNS? -> mark 0x1                             |
|  private? -> accept                           |
|  cn_ipv4? -> accept (kernel CN bypass)        |  <-- global only
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
|  UDP -> reject                                |
|  IPv6 -> reject                               |
|  log ks-drop + DROP                           |
+-----------------------------------------------+
```

### nftables Tables Summary

| Table | Chain | Priority | Role |
|-------|-------|----------|------|
| `inet sw_lan_tproxy` | prerouting | mangle-10 | LAN TCP + QUIC to surflare-proxy (IPv4+IPv6 dual-stack) |
| `ip dns_enforce` | prerouting | mangle-20 | Force LAN DNS through router (silent reject, no log) |
| `inet surflare` | output | mangle | Router traffic + **cn_ipv4 accept** |
| `inet surflare` | prerouting | mangle | tproxy marked packets to :10800 |
| `inet killswitch` | output | filter+20 | Router leak protection (policy drop) |
| `inet killswitch` | forward | filter-10 | LAN leak protection + IP audit log |
| `inet surflare_moat` | prerouting | raw | TCP fingerprint detection |
| `inet fw4` | forward | filter | OpenWrt zone firewall (policy drop) |

### Key difference from rule mode

Global mode adds `ip daddr @cn_ipv4 accept` to the `inet surflare` output
chain, giving the router's own processes a kernel-level CN bypass that does
not go through surflare-proxy.  All LAN TCP/QUIC goes through surflare-proxy
and exits via VPN regardless of destination -- no CN/non-CN split at the
application layer.

`bypass_devices` is populated from `/etc/surflare/bypass-macs.conf` so
specific devices (e.g. admin-PC running Thunder) skip tproxy entirely and
route via ISP for CN traffic.

## VPN Downtime Behavior

- Router's own CN traffic: continues via `bypass_ipv4` (direct ISP route).
- LAN CN traffic: continues via killswitch forward `bypass_ipv4`.
- Non-CN traffic (router + LAN): **REJECT** with `ks-fwd-mon` dmesg log.

## Configuration

Set `MODE="global"` in `surflare_watchdog.sh` (or leave `MODE=""` and set
`PLATFORM` detection to resolve it -- default for router is `rule`, so
global mode requires explicit override):

```bash
# In surflare_watchdog.sh, before PLATFORM detection:
MODE="global"
```

Or via install.sh sed on deployment:

```bash
sudo sed -i 's/^MODE=""/MODE="global"/' /usr/local/sbin/surflare_watchdog.sh
```
