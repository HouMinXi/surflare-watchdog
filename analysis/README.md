# sing-box Config Analysis — N100 surflare-proxy

Captured: 2026-06-25 17:02 CST
Node: Los Angeles (auto), Transit: auto, Mode: rule
Config: analysis/sing-box-config.json (186KB, valid JSON)
Capture script: scripts/capture_surflare_config.sh

## Config Architecture

```
surflare connect --node auto --transit auto --mode rule
  -> selects one exit city (e.g., Los Angeles)
     -> generates SINGLE urltest outbound: mh_via_auto_to_Los_Angeles
        -> 51 sub-outbounds: 17 transit x 3 exit
           -> mh_option_via_public_<N>_to_public_<M>
```

A DIFFERENT config is generated for each `surflare connect` call.
When connected to Atlanta, the urltest outbound would be `mh_via_auto_to_Atlanta`.
There are NEVER multiple city-level urltest outbounds in a single config --
only the sub-outbounds (transit->exit pairs) are load-balanced.

## Key Parameters

| Parameter | Value | Meaning |
|-----------|-------|---------|
| urltest.interval | **120s** | Full RTT probe cycle -- every 2 min |
| urltest.tolerance | **40** | RTT tolerance (ms) for load-balancing, NOT failover timeout |
| sub-outbounds | 51 | 17 transit nodes x 3 exit nodes |
| DNS remote detour | `mh_via_auto_to_<city>` | DoH hardcoded to the urltest outbound |

## Transit / Exit Mapping

- **17 transit nodes**: public_11, public_16, public_17, public_25, public_35,
  public_39, public_41, public_52, public_75, public_81, public_82, public_109,
  public_113, public_117, public_149, public_152, public_153
- **3 exit nodes**: public_16, public_75, public_82

Each sub-outbound = mh_option_via_<transit>_to_<exit> -- 2-hop routing.
The transit list is dynamic (server-side assignment per connect session).

## DNS Routing

```
dns-direct:  223.5.5.5:53 (UDP) via detour=direct
             -> surflare internal domains, captive portal, default fallback

dns_remote:  https://1.1.1.1/dns-query (DoH) via detour=mh_via_auto_to_Los_Angeles
             -> proxy_rule_set domains from tproxy-in (all foreign DNS)
```

DNS rules priority:
1. surflare domains (murk.surflare.com, agkeb.com, etc.) -> dns-direct
2. Captive portal (msftconnecttest.com, captive.apple.com) -> dns-direct
3. gstatic.com, cp.cloudflare.com from tproxy-in -> dns_remote
4. proxy_rule_set domains from tproxy-in -> dns_remote
5. Everything else from tproxy-in -> dns-direct (default)

## 14:41 DNS Cascade Failure -- Root Cause

### Timeline

```
14:26:51  connect to Atlanta -> urltest: mh_via_auto_to_Atlanta
14:39:50  Atlanta relay dies (urltest read timeout 12m56s)
          urltest detects current sub-outbound failure
          BUT next full probe cycle is 120s later (~14:41:50)
14:39:50  <-- 2-MINUTE BLIND WINDOW BEGINS -->
14:41:00  DNS failures start (cloudflareinsights.com, googleapis.com)
14:41:15  sing-box core DNS fails (cloudflare-dns.com x 10+)
          DoH to 1.1.1.1 goes through urltest -> still dead sub-outbound
14:41:17  Atlanta urltest 503 #1 (re-probe attempt, still failing)
14:41:51  Atlanta urltest 503 #2
14:42:11  User DNS cascade (google.com, linkedin.com)
14:42:23  * 4x loopback (127.0.0.1 -> 127.0.0.1:10800)
14:42:26  Atlanta urltest 503 #3
14:42:59  cloudflare-dns.com still failing
          <-- urltest switches to healthy sub-outbound (sometime after) -->
14:43:36  Atlanta urltest 503 #4 (other sub-outbounds now working,
          but Atlanta-specific one still returning 503)
```

### Mechanism

1. urltest interval = 120s creates a **2-minute blind window** between
   health probe cycles
2. During the blind window, urltest continues routing through the
   previously-selected sub-outbound even if it's dead
3. DNS (DoH) is hardcoded to go through the urltest outbound
   (`detour: mh_via_auto_to_Atlanta`)
4. When ALL sub-outbounds in the urltest pool share a common failing
   transit, DNS fails across the board
5. After ~1 minute of DNS failures, sing-box's internal DNS module
   attempts a fallback path through localhost (127.0.0.1:10800)
6. The tproxy listener detects src=127.0.0.1 -> rejects as loopback

### Why Watchdog Didn't Detect

- Smart Routing: when Atlanta relay dies, urltest auto-switches to
  healthy sub-outbounds for data-plane traffic
- Watchdog's `check_vpn_health()` probes go through surflare-proxy:10800
  -> urltest auto-select -> healthy sub-outbound -> OK
- Watchdog reports "VPN healthy: OK" at 14:48:32 -- correct for data plane
- DNS cascade is invisible to watchdog's TCP/ICMP health probes

## Type 1 Loopback -- Complete Model

```
sing-box DNS module -> DoH (1.1.1.1) -> detour=urltest -> dead relay -> timeout
                                                           |
                                            2-min blind window: continuous failures
                                                           |
                                    DNS fallback -> 127.0.0.1:10800
                                                           |
                                           tproxy detects src=127.0.0.1
                                                           |
                                                  loopback reject
```

### Two Trigger Scenarios

| Scenario | Trigger | Frequency | Fixable |
|----------|---------|-----------|---------|
| A | Reconnect window (sing-box process restart) | ~24/32, <2s window | No -- sing-box internal |
| B | DNS cascade during urltest blind window | ~4/32, 1-2 min window | Partially -- reduce urltest interval |

## Why 5 urltest Cities (No Miami)

The config captured at this session shows `mh_via_auto_to_Los Angeles`.
Across sessions, 5 different cities appeared as the urltest outbound:
Atlanta, Chicago, Dallas, Los Angeles, New York. Miami never appears.

Reasons (unconfirmed, requires surflare server-side insight):
1. Miami is selected as **transit** (not exit) -- transit and exit
   cannot be the same node in sing-box multi-hop
2. Miami temporarily unavailable on surflare's server-side node list
3. Internal selection algorithm limits exit candidates

The `transit=auto` flag lets the surflare binary auto-select which
public_* node acts as transit. With 17 transit candidates and only
3 exit candidates, the binary may have assigned Miami's public node
to the transit pool, excluding it from the exit (urltest) pool.

## File Inventory

| File | Description |
|------|-------------|
| scripts/capture_surflare_config.sh | Capture script (forge-reviewed, cycle 1) |
| analysis/sing-box-config.json | Captured sing-box config (186KB JSON) |
| analysis/README.md | This analysis |
