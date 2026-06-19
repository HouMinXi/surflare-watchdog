# Router / Rule Mode (Smart Routing)

surflare-proxy splits traffic at the application layer: CN destinations
route directly via ISP, non-CN destinations route through the VPN tunnel.
This is the default mode for router deployments.

## When to Use

- LAN devices need CN apps (bilibili, xiaohongshu, Taobao, etc.) to
  detect a domestic IP address.
- Only non-CN traffic needs VPN protection.

## nftables Behavior

| Table | Role | Populated? |
|-------|------|-----------|
| `inet killswitch` output | Router's own leak protection (policy drop) | Yes -- server_ips, bypass_ipv4 (chnroute), LAN ranges |
| `inet killswitch` forward | LAN leak protection during tproxy-down | Yes -- bypass_ipv4 allows CN, rejects non-CN with `ks-fwd-mon` log |
| `ip sw_lan_tproxy` | Redirect all br-lan TCP to surflare-proxy | Yes |
| `inet surflare` output | CN bypass for router's own processes | **No** -- surflare-proxy handles CN/non-CN split at app layer |
| `ip dns_enforce` | Force LAN DNS through dnsmasq/SmartDNS | Yes |

### Key difference from global mode

In global mode, `_setup_chnroute()` loads CN CIDRs into both the killswitch
`bypass_ipv4` set AND the `inet surflare` output chain (`cn_ipv4` accept
rule).  In rule mode, CN CIDRs are loaded into `bypass_ipv4` only -- the
output chain accept rule is skipped because surflare-proxy handles CN/non-CN
routing at the application layer.

The `bypass_ipv4` population in rule mode serves two purposes:
1. **VPN downtime resilience:** router's own CN traffic (opkg, SSH) and
   LAN CN traffic continue working when VPN is down.
2. **LAN CN UDP direct routing:** tproxy handles TCP only; CN UDP (gaming,
   video, QUIC) passes through the killswitch forward chain via
   `bypass_ipv4` and routes directly via ISP.

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
