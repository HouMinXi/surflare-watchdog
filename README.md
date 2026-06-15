# surflare-watchdog

A resilient watchdog system for [Surflare VPN](https://www.surflare.com) on Linux.
Monitors tunnel health, rotates nodes on failure, and uses surflare-proxy's own
internal urltest results for real-time node health — zero VPN disruption required.

---

## System Architecture

```
+-----------------------------+     SIGUSR1      +----------------------------+
|   surflare_early_detector   |----------------->|                            |
|   (TCP degradation sensor)  |  heartbeat file  |   surflare_watchdog.sh     |
|  - ss cwnd/rto/backoff      |<- - - - - - - - -|   (main daemon)            |
|  - fires USR1 when score    |                  |                            |
|    threshold exceeded       |                  |  - health check loop       |
+-----------------------------+                  |  - node rotation           |
                                                 |  - storm protection        |
+-----------------------------+  health JSON     |  - kill switch mgmt        |
|   surflare_log_health.sh    |----------------->|                            |
|   (3-min cron, zero disruption)  /run/...json  |  _node_is_log_healthy()    |
|                              |                 |   skips dead nodes on      |
|  - parses surflare-proxy.log|                 |   rotation                 |
|  - extracts urltest errors  |                 |                            |
|  - errors => unhealthy      |                 +----------------------------+
+-----------------------------+                           |
             ^                                            | surflare connect
             |                                           v
+-----------------------------+                 +----------------------------+
|   surflare-proxy (sing-box) |                 |   surflare-proxy (sing-box)|
|   internal urltest          |                 |   nft tproxy + kill switch |
|                             |                 +----------------------------+
|  - tests ALL node/transit   |
|    combos from CN IP        |
|  - every ~3 min, concurrent |
|  - errors logged to         |
|    /var/log/surflare/       |
|    surflare-proxy.log       |
+-----------------------------+
```

**Key insight:** surflare-proxy already runs sing-box urltest outbounds for every
node and transit combination, using the local CN IP as the probe source. Errors
are logged; successes are silent (DEBUG level). `surflare_log_health.sh` reads
these errors to determine node health — no active probing, no VPN disruption.

---

## How They Work Together

### Normal operation

```
[every 3 min — cron]
surflare_log_health.sh
      |-- tail last 2MB of /var/log/surflare/surflare-proxy.log
      |-- count urltest errors per node/transit combo in last 10 min
      |-- errors > 10  => mark unhealthy
      '-- write /run/surflare_node_health.json (atomic, 0600)

[every 30s]
surflare_early_detector.sh samples ss metrics
      |-- cwnd <= 1  (+2 pts per connection)
      |-- rto > 8000 (+2 pts per connection)
      |-- backoff >= 3 (+2 pts per connection)
      '-- if total score >= 16: SIGUSR1 -> watchdog wakes immediately

[every 30s, or on SIGUSR1]
surflare_watchdog.sh health check
      |-- curl probes (2 targets, parallel, --max-time 8)
      |-- PASS: log "VPN healthy"
      '-- FAIL: _rotate_node()
                |-- reads /run/surflare_node_health.json
                |-- skips candidates with > 10 urltest errors
                '-- connect to next healthy candidate
```

### Tunnel failure and fast recovery

```
Tunnel degrades silently
      |
early_detector sees cwnd/rto/backoff worsen  (within 30s)
      |
SIGUSR1 sent to watchdog PID
      |
watchdog interrupts sleep, runs health check immediately
      |
health check fails -> _rotate_node()
      |
reads pre-computed node health, skips confirmed-dead nodes on first try
      |
connects to next healthy candidate

Before:  detect 120s + try each node serially (8s each)
After:   detect <30s + skip dead nodes immediately
```

---

## Components

### `surflare_watchdog.sh` -- Main daemon

| Feature | Detail |
|---|---|
| Health check | Two parallel curl probes; any success = healthy |
| Log-based skip | `_node_is_log_healthy()` skips nodes with recent urltest errors |
| Cascade fast-rotate | `reconnect_count >= 2` triggers rapid try of all candidates |
| Storm protection | `STORM_COOLDOWN=600s` after all candidates exhausted |
| Kill switch | nftables drops non-tunnel traffic while VPN is down |
| Fail-open | After 5 global auth failures, removes kill switch; retries with backoff |
| Early warn | USR1 trap wakes watchdog for immediate health check |

### `surflare_early_detector.sh` -- TCP degradation sensor

Polls `ss -tnp state established` every `MONITOR_INTERVAL=30s`. Scores each
surflare connection on three TCP metrics:

| Metric | Condition | Score |
|---|---|---|
| Congestion window | cwnd <= 1 | +2 pts |
| Retransmit timeout | rto > 8000 ms | +2 pts |
| Exponential backoff | backoff >= 3 | +2 pts |

When combined score reaches `DEGRADATION_THRESHOLD` (default 16), sends `SIGUSR1`
to the watchdog PID.

### `surflare_log_health.sh` -- Real-time node health monitor

Runs every 3 minutes via cron. Reads the last 2MB of
`/var/log/surflare/surflare-proxy.log` and extracts urltest error counts
for each node/transit combination.

**Why this works:** surflare-proxy (sing-box) runs urltest outbounds for all
node combinations using the local CN IP as the source. Failed probes are logged
at ERROR level; successful probes are silent. Error presence = unhealthy.
No VPN connection or disruption required.

Output: `/run/surflare_node_health.json` (mode 0600, tmpfs)

| Field | Meaning |
|---|---|
| `error_count` | urltest errors in the last 10 minutes |
| `urltest_healthy` | `error_count <= 10` |
| `last_error` | most recent error message (truncated to 120 chars) |

Watchdog uses `_node_is_log_healthy(node, transit)` to skip candidates
with `error_count > 10` during rotation. Stale file (> 20 min old) is
treated as healthy — cascade handles actual failures.

### `surflare_node_probe.sh` -- Manual diagnostic tool

**Not scheduled.** Run on demand to get a point-in-time assessment of all
configured nodes. Requires briefly disconnecting the current VPN session per
candidate (~26s per exit node, ~30s per transit node).

Records L4 TCP RTT, L7 TTFB, exit country, path-quality signals (SYN ratio,
RST injection, SACK rate), server IPs, and current urltest health status.
Results written to `/run/surflare_probe_results.json`.

---

## Dependencies

| Command | Package | Required by |
|---|---|---|
| `curl` | curl | watchdog, node_probe |
| `ss` | iproute2 | watchdog, early_detector |
| `nft` | nftables | watchdog |
| `flock` | util-linux | watchdog, node_probe |
| `pgrep` / `pkill` | procps | all |
| `python3` | python3 | log_health, node_probe |
| `surflare` / `surflare-proxy` | Surflare package | all |
| `/var/log/surflare/surflare-proxy.log` | written by surflare-proxy | log_health |

---

## Install

```bash
git clone git@github.com:HouMinXi/surflare-watchdog.git
cd surflare-watchdog
sudo bash install.sh
```

`install.sh` detects the init system (systemd / OpenRC / procd / runit), copies
scripts to `/usr/local/sbin/`, installs and enables services, and adds the
log_health cron entry.

```bash
# Auth setup (optional — TPM2-backed password storage)
sudo bash ./setup_auth.sh

# Start
sudo systemctl start surflare-watchdog
sudo systemctl start surflare-early-detector
```

---

## Configuration

**`surflare_watchdog.sh`**

```bash
NODE="Los Angeles"
NODE_CANDIDATES=("Los Angeles" "Dallas" "Atlanta" "Seoul" "Chicago" "Miami" "New York")
MODE="global"
TRANSIT_CANDIDATES=("Los Angeles" "Taipei" "Seoul" "Hong Kong")
CHECK_INTERVAL=30       # seconds between health checks
FAIL_THRESHOLD=4        # consecutive failures before reconnect
STORM_COOLDOWN=600      # seconds after all candidates exhausted
```

**`surflare_early_detector.sh`**

```bash
MONITOR_INTERVAL=30       # seconds between ss samples
DEGRADATION_THRESHOLD=16  # combined score to fire SIGUSR1
COOLDOWN=300              # minimum seconds between signals
```

**`surflare_log_health.sh`**

```bash
DEFAULT_WINDOW=10   # minutes of log to scan for errors
# Called with: surflare_log_health.sh [--window-minutes N] [--out FILE]
```

---

## Usage

```bash
# Start services
sudo systemctl start surflare-watchdog
sudo systemctl start surflare-early-detector

# Live log
sudo dmesg -w | grep surflare

# Current node health (updated every 3 min by cron)
sudo python3 -m json.tool /run/surflare_node_health.json

# Manual diagnostic probe (disconnects VPN briefly)
sudo /usr/local/sbin/surflare_node_probe.sh
sudo python3 -m json.tool /run/surflare_probe_results.json
```

---

## Key Log Messages

| Message | Meaning |
|---|---|
| `VPN healthy: exit=US` | Periodic heartbeat |
| `EARLY_WARN_TRIGGERED` | Detector fired USR1; immediate health check started |
| `Node rotation: X -> Y (N/M)` | Switching to next candidate |
| `LOG_HEALTH: skipping X via Y (N errors)` | Node skipped due to recent urltest errors |
| `Storm protection triggered` | All candidates exhausted; cooling down |
| `Local VPN state lost` | Proxy process or routing rules missing |
| `early_detector_stale` | Detector heartbeat overdue |

---

## Supported Distributions

| Init system | Distros |
|---|---|
| systemd | Fedora, Ubuntu, Debian, Arch, RHEL, openSUSE |
| OpenRC | Alpine, Gentoo |
| procd | OpenWrt, iStoreOS (N100 router) |
| runit | Void Linux |

---

## N100 Router Deployment (iStoreOS / OpenWrt)

When deployed on an iStoreOS/OpenWrt router (procd init), `install.sh`
additionally installs a transparent proxy rule that routes **all LAN
devices** through the VPN without any per-device configuration.

### How it works

```
LAN device (any IP on br-lan)
  --> PREROUTING priority mangle-10
      --> tproxy ip to 127.0.0.1:10800  (surflare-proxy)
          --> VPN tunnel    (non-CN traffic)
          --> direct WAN    (CN traffic, per chnroute list)
```

All TCP traffic from `br-lan` that is NOT destined for private addresses
(`10/8`, `172.16/12`, `192.168/16`) is intercepted and transparently
proxied through `surflare-proxy` on port 10800. surflare-proxy applies
CN bypass and node routing before forwarding.

### Extra dependency

```bash
opkg install kmod-nft-tproxy
```

Required for the `tproxy` nft action on OpenWrt kernel modules.
Not needed on standard Linux (compiled in by default).

### What install.sh does on procd

In addition to the standard binary/service installation, `install.sh`
copies `surflare-lan-tproxy.nft` to `/etc/surflare-lan-tproxy.nft`.
The watchdog loads this file via `_install_lan_tproxy()` after every VPN
connect, so the rule is automatically re-applied on reconnect or restart.

### Known iStoreOS / busybox constraints

| Constraint | Reason |
|---|---|
| `table ip` not `table inet` | `inet` + `ip saddr` in tproxy causes "conflicting protocols" error |
| `tproxy ip to 127.0.0.1:10800` | Bare `tproxy to :10800` silently fails for LAN forwarded packets |
| `pgrep surflare-proxy` (no `-x`) | busybox `pgrep -x` always returns 1 (known busybox bug) |
| `pgrep -f "/usr/bin/surflare"` in `wait_for_exit` | Plain `pgrep surflare` also matches watchdog bash (comm=`surflare_watchd`) |
| `tr '\n' ','` not `paste -sd, -` | `paste` not installed on iStoreOS |
| NTP skuid detected at runtime | iStoreOS uses user `ntp`; Fedora/RHEL use `chrony` |
