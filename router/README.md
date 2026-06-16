# Router Deployment (N100 / iStoreOS / OpenWrt / procd)

Scripts and config for N100 mini-PC running iStoreOS or OpenWrt (procd init).

## Files

| File | Purpose |
|------|---------|
| `surflare-lan-tproxy.nft` | nftables LAN transparent proxy -- all br-lan TCP routed through surflare-proxy. Includes `auto_bypass` dynamic set: DTLS 1.2 detection on UDP/443 (`@th,72,16 0xfefd`) automatically bypasses corporate VPN clients with 5-min timeout. |
| `bypass-macs.conf.example` | Template for `/etc/surflare/bypass-macs.conf`: one MAC per line; IPs resolved via dhcp.leases at each VPN connect. Use for devices that always need direct CN ISP (e.g. Thunder). **Not needed for AnyConnect -- DTLS auto-detection handles that automatically.** |
| `update-cn-domains.sh` | Weekly cron: downloads dnsmasq-china-list, converts to SmartDNS nameserver format, validates, restarts SmartDNS. |
| `smartdns/custom.conf.example` | SmartDNS config template: domestic group (CN DoT/DoH), foreign group (1.1.1.1 via VPN), Bing fix, bootstrap isolation. |
| `smartdns/force-foreign.conf.example` | Per-domain VPN-path overrides for CN-IP duality domains (e.g. bing.com). |
| `smartdns/smartdns-custom.init` | procd init script for custom SmartDNS instance on port 6053. |
| `services/procd/` | procd init scripts for surflare-watchdog (no early-detector: nm-online unavailable). |

## Prerequisites

```bash
opkg update
opkg install kmod-nft-tproxy ss coreutils-timeout conntrack
```

## Quick Start

```bash
sudo bash install.sh   # auto-detects procd
```

Then configure SmartDNS:
```bash
cp router/smartdns/custom.conf.example /etc/smartdns/custom.conf
cp router/smartdns/force-foreign.conf.example /etc/smartdns/force-foreign.conf
# Edit /etc/smartdns/custom.conf: add wechat sendkey to /etc/surflare/wechat.conf
/etc/init.d/smartdns-custom start && /etc/init.d/smartdns-custom enable
```

## CN Route Lists

`surflare_route_updater.sh` maintains two route files in `/etc/surflare/`:

| File | Source | Update |
|------|--------|--------|
| `cn_ipv4.txt` | chnroutes2 BGP × APNIC delegated (95% overlap gate) | Daily 02:30 cron |
| `cn_ipv4_extra.txt` | Three-source cloud CDN: RIPE IRR+BGP × RADB × APNIC APAC geo-filter | Daily 02:30 cron |

**cn_ipv4_extra.txt** covers Tencent Cloud International + Alibaba Cloud International
nodes in HK/SG/TW/JP/KR/MO that serve CN users but are not in chnroutes2 (registered
outside mainland). Without this file, apps like MIUI app store and Thunder route
through the VPN and experience high latency (4+ seconds).

Cross-validation methodology:
1. **RIPE AS routing consistency** (AS132203/AS45102/AS24429): keeps only `in_bgp=True AND in_whois=True` — IRR registry AND live BGP confirmed by ≥10 full-table peers
2. **disposable/cloud-ip-ranges** (RADB AS-SET, daily): ≥75% of RIPE-confirmed must match — guards against RIPE API data corruption
3. **APNIC delegated** (APAC geo-filter: CN/HK/SG/TW/JP/KR/MO): eliminates US/EU nodes

## N100 Platform Constraints

| Constraint | Reason |
|---|---|
| `CONNECT_SETTLE=20` | N100 chnroute load (3917 prefixes) + pppoe + TCP handshake takes >10s |
| `table ip` not `table inet` | inet + ip saddr in tproxy = "conflicting protocols" error |
| `tproxy ip to 127.0.0.1:10800` | Bare `:10800` silently fails for LAN forwarded packets |
| `pgrep surflare-proxy` (no `-x`) | busybox `pgrep -x` always returns 1 |
| `tr '\n' ','` not `paste -sd, -` | paste not installed on iStoreOS |
| No `expect` needed | auth.dat covers daemon reconnects; expect only for fresh setup |

## SmartDNS Split DNS Architecture

```
LAN device -> dnsmasq(:53) -> SmartDNS(:6053)
                                  +-- CN domains -> domestic group (DoT: 223.5.5.5/223.6.6.6/120.53.53.53)
                                  `-- Foreign domains -> default group (1.1.1.1/8.8.8.8 via VPN)
```

**Pitfalls:**
- `bootstrap-dns` servers need `-exclude-default-group` or they pollute foreign DNS
- `address /domain/ip` is overridden by `speed-check-mode` -- use `domain-rules ... -speed-check-mode none`
- After SmartDNS config change, run `killall -HUP dnsmasq` to flush dnsmasq cache
- `/tmp/cache/smartdns/smartdns.cache` persists across restarts -- delete before restart

## WeChat Alerts

Store SendKey in `/etc/surflare/wechat.conf` (chmod 600, not in git):
```bash
echo 'WECHAT_SENDKEY="SCT..."' > /etc/surflare/wechat.conf
chmod 600 /etc/surflare/wechat.conf
```

## Service Management

```bash
/etc/init.d/surflare-watchdog start|stop|restart|enable|disable
```
