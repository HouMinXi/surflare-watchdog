# Router Deployment (N100 / iStoreOS / OpenWrt / procd)

Scripts and config for N100 mini-PC running iStoreOS or OpenWrt (procd init).

## Files

| File | Purpose |
|------|---------|
| `rule/surflare-lan-tproxy.nft` | `table inet` dual-stack tproxy (rule mode). LAN TCP+QUIC IPv4+IPv6 to surflare-proxy. `cn_direct`/`cn6_direct` sets present but empty (proxy handles CN split). |
| `global/surflare-lan-tproxy.nft` | Same table structure (global mode). `cn_direct`/`cn6_direct` populated by watchdog with CN CIDRs for ISP direct bypass. |
| `rule/bypass-macs.conf` | Mode-specific bypass config: empty in rule mode (proxy handles CN for all devices equally). |
| `global/bypass-macs.conf` | Mode-specific bypass config: devices needing full CN ISP direct (e.g. Thunder). **WARNING: bypassed devices have NO VPN protection.** |
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
| `cn_ipv4_extra.txt` | Multi-source cloud CDN: RIPE IRR+BGP × RADB × APNIC APAC geo-filter | Daily 02:30 cron |

**cn_ipv4_extra.txt** covers major Chinese cloud and CDN providers with APAC nodes
that serve CN users but are not in chnroutes2 (registered outside mainland). Without
this file, apps like MIUI app store and Thunder route through the VPN and experience
high latency (4+ seconds).

The validator uses two groups to maximize coverage:

**Main group** (RIPE IRR+BGP × cloud-ip-ranges cross-check ≥75% × APNIC APAC geo):

| ASN | Provider | cloud-ip-ranges file | Overlap |
|-----|----------|----------------------|---------|
| AS132203 | Tencent Cloud Intl | tencent.txt | ~80% |
| AS139341 | Tencent ACE CDN | tencent.txt | 100% |
| AS45102 | Alibaba Cloud Intl | alibaba.txt | ~80% |
| AS24429 | Alibaba CDN (Taobao) | alibaba.txt | ~80% |
| AS136907 | Huawei Cloud APAC | huawei-cloud.txt | 100% |

**Supplement group** (RIPE IRR+BGP × APNIC APAC geo only — no cloud-ip-ranges file):

| ASN | Provider | Reason for supplement path |
|-----|----------|---------------------------|
| AS37963 | Alibaba Cloud Hangzhou | 1.3% overlap — cloud-ip-ranges doesn't track this entity |
| AS134963 | Alibaba Cloud Singapore | 47% overlap — incomplete coverage |
| AS396986 | ByteDance / TikTok | No cloud-ip-ranges file exists |

Combined output: ~787 collapsed CIDRs (vs 325 before). RIPE downloads run in parallel
(8 simultaneous connections); total update time ~5 min.

Cross-validation methodology:
1. **RIPE AS routing consistency**: keeps only `in_bgp=True AND in_whois=True` — IRR registry AND live BGP confirmed by ≥10 full-table peers
2. **disposable/cloud-ip-ranges** (main group only): ≥75% of RIPE-confirmed must match — corruption detection gate, not accuracy measure
3. **APNIC delegated** (both groups, APAC geo-filter: CN/HK/SG/TW/JP/KR/MO): eliminates US/EU nodes

## N100 Platform Constraints

| Constraint | Reason |
|---|---|
| `CONNECT_SETTLE=20` | N100 chnroute load (3917 prefixes) + pppoe + TCP handshake takes >10s |
| `table inet` with `meta nfproto` | Dual-stack tproxy; `meta nfproto ipv4`/`ipv6` prevents cross-family matching |
| `tproxy ip to 127.0.0.1:10800` | Bare `:10800` silently fails for LAN forwarded packets |
| `pgrep surflare-proxy` (no `-x`) | busybox `pgrep -x` always returns 1 |
| `coreutils-paste` required | busybox has no `paste`; installed via opkg by install.sh |
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
