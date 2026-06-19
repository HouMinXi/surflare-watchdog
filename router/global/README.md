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

## nftables Behavior

| Table | Role | Populated? |
|-------|------|-----------|
| `inet killswitch` output | Router's own leak protection (policy drop) | Yes -- server_ips, bypass_ipv4 (chnroute), LAN ranges |
| `inet killswitch` forward | LAN leak protection during tproxy-down | Yes -- bypass_ipv4 allows CN, rejects non-CN with `ks-fwd-mon` log |
| `ip sw_lan_tproxy` | Redirect all br-lan TCP to surflare-proxy | Yes |
| `inet surflare` output | CN bypass for router's own processes | Yes -- `cn_ipv4`/`cn_ipv6` accept rules |
| `ip dns_enforce` | Force LAN DNS through dnsmasq/SmartDNS | Yes |

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
