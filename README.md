# surflare-watchdog

A resilient watchdog system for [Surflare VPN](https://www.surflare.com) on Linux.
Monitors tunnel health, rotates nodes on failure, and pre-assesses candidates
before a rotation is needed.

---

## System Architecture

```
+-----------------------------+     SIGUSR1      +----------------------------+
|   surflare_early_detector   |----------------->|                            |
|   (TCP health monitor)      |                  |   surflare_watchdog.sh     |
|                             |  heartbeat file  |   (main daemon)            |
|  - ss cwnd/rto/backoff      |<- - - - - - - - -|                            |
|  - fires USR1 when 2+       |                  |  - health check loop       |
|    connections degrade      |                  |  - node rotation           |
+-----------------------------+                  |  - storm protection        |
                                                 |  - kill switch mgmt        |
+-----------------------------+  probe results   |                            |
|   surflare_node_probe.sh    |----------------->|                            |
|   (node pre-assessment)     | /run/..probe.json|  _probe_skip_node()        |
|                             |                  |   reads JSON before rotate |
|  Phase 1: exit nodes        |  active marker   |                            |
|  - connect + L4 TCP RTT     |<================>|  defers cycle while probe  |
|  - L7 TTFB + country        |  coordination    |  holds the session         |
|                             |                  |                            |
|  Phase 2: transit nodes     |                  +----------------------------+
|  - connect + pcap capture   |                           |
|  - SYN ratio / RST / SACK   |                           | surflare connect
+-----------------------------+                           v
                                                 +----------------------------+
                                                 |   surflare-proxy (sing-box)|
                                                 |   nft tproxy + kill switch |
                                                 +----------------------------+
```

---

## How They Work Together

### Normal operation

```
[15-min timer]
      |
      v
surflare_node_probe.sh starts
      |-- flock: wait for any in-flight connect_vpn
      |-- writes /run/surflare_probe.active  (watchdog defers its cycle)
      |-- Phase 1: probe 7 exit nodes sequentially
      |-- Phase 2: probe 4 transit nodes + pcap capture
      |-- restores original session
      |-- writes /run/surflare_probe_results.json  (scored, sorted)
      '-- exits  (EXIT trap removes marker; watchdog resumes)

[every 30s]
surflare_early_detector.sh samples ss metrics
      |-- cwnd <= 1  (+2 pts per connection)
      |-- rto > 4000 (+2 pts per connection)
      |-- backoff >= 3 (+2 pts per connection)
      '-- if total score >= 8: SIGUSR1 -> watchdog wakes immediately

[every 30s, or on SIGUSR1]
surflare_watchdog.sh health check
      |-- if probe active marker fresh: defer entire cycle, sleep
      |-- curl probes (2 targets, parallel, --max-time 8)
      |-- PASS: log "VPN healthy"
      '-- FAIL: rotate_node()
                |-- read /run/surflare_probe_results.json
                |-- skip candidates with score < 30
                '-- connect to highest-scored candidate
```

### Tunnel failure and fast recovery

```
Tunnel degrades silently
      |
      v
early_detector sees cwnd/rto/backoff worsen  (within 30s)
      |
      v
SIGUSR1 sent to watchdog PID
      |
      v
watchdog interrupts storm sleep, runs health check immediately
      |
      v
health check fails -> rotate_node()
      |
      v
reads pre-assessed JSON, skips confirmed-dead nodes
      |
      v
connects to highest-scored candidate

Before (no tooling): detect 120s + try each node ~8s + storm 600s
After  (with tools):  detect <30s + skip dead nodes + connect once
```

---

## Components

### `surflare_watchdog.sh` -- Main daemon

| Feature | Detail |
|---|---|
| Health check | Two parallel curl probes; any success = healthy |
| Failure detection | `FAIL_THRESHOLD` consecutive failures trigger reconnect |
| Local state check | Verifies proxy process, nft table, fwmark rule each cycle |
| Node rotation | Cycles `NODE_CANDIDATES` on repeated failure |
| Cascade fast-rotate | `reconnect_count >= 2` triggers rapid try of all candidates |
| Storm protection | `STORM_COOLDOWN=600s` after all candidates exhausted |
| Kill switch | nftables drops non-tunnel traffic while VPN is down |
| Fail-open | After 5 global auth failures, removes kill switch; retries with backoff |
| Early warn | USR1 trap + defer guard for node-probe coordination |

### `surflare_early_detector.sh` -- TCP degradation sensor

Polls `ss -tnp state established` every `MONITOR_INTERVAL=30s`. Scores each
surflare connection on three TCP metrics:

| Metric | Condition | Score |
|---|---|---|
| Congestion window | cwnd <= 1 | +2 pts |
| Retransmit timeout | rto > 4000 ms | +2 pts |
| Exponential backoff | backoff >= 3 | +2 pts |

When **two or more connections** reach a combined score of `>= DEGRADATION_THRESHOLD`
(default 8), sends `SIGUSR1` to the watchdog PID, cutting the detection window
from up to 120s down to under 30s.

### `surflare_node_probe.sh` -- Node pre-assessment

Runs every 15 minutes while the current session is healthy. Writes
`/run/surflare_probe_results.json` (mode 0600, tmpfs).

**Phase 1 -- Exit nodes** (`NODE_CANDIDATES`):

| Measurement | Method | Score impact |
|---|---|---|
| L4 TCP RTT | `SO_MARK=0xff` direct connect to server:443 | Penalty if > 300ms |
| L7 TTFB | `curl https://www.google.com` | Primary dimension |
| Exit country | `curl https://1.0.0.1/cdn-cgi/trace` | Penalty if not US |
| Score 0-100 | N6 scoring table | Watchdog skip threshold: < 30 |

**Phase 2 -- Transit nodes** (`TRANSIT_CANDIDATES`):

| Signal | Source | Verdict |
|---|---|---|
| SYN delivery ratio < 50% | tcpdump on physical NIC | `TARGETED_SYN_BLOCK` |
| RST packets injected | tcpdump | `SERVER_REFUSED_RST` |
| SACK rate > 20% | tcpdump | `TRANSIT_DEGRADATION` |
| Upstream unreachable | out > 0, in = 0 | `UPSTREAM_UNREACHABLE` |
| Pcap not possible | no server IPs or no local IP | `CAPTURE_FAIL` (score 50) |

**Session coordination with watchdog:**

```
probe start
  |-- flock -w 30 on /run/surflare_watchdog.lock (wait for in-flight connect)
  |-- write /run/surflare_probe.active  (watchdog defers its cycle)
  |-- release lock immediately
  |
  ... Phase 1 + Phase 2 ...
  |
  |-- restore original session + verify routing
  '-- EXIT trap: rm /run/surflare_probe.active  (watchdog resumes)

Watchdog side:
  each cycle: if _probe_active() -> sleep CHECK_INTERVAL -> continue
  stale marker (> 75s): pkill probe, reclaim session
  hard cap   (> 360s):  pkill probe, force reclaim
```

---

## Dependencies

| Command | Package | Required by |
|---|---|---|
| `curl` | curl | watchdog, node_probe |
| `ss` | iproute2 | watchdog, early_detector |
| `nft` | nftables | watchdog |
| `flock` | util-linux | watchdog, node_probe |
| `pgrep` / `pkill` | procps | all |
| `tcpdump` | tcpdump | node_probe Phase 2 |
| `python3` | python3 | node_probe (JSON write, L4 probe) |
| `surflare` / `surflare-proxy` | Surflare package | all |

---

## Install

```bash
git clone git@github.com:HouMinXi/surflare-watchdog.git
cd surflare-watchdog

# Core watchdog
sudo cp surflare_watchdog.sh /usr/local/sbin/
sudo chmod 755 /usr/local/sbin/surflare_watchdog.sh

# Early detector (run alongside watchdog)
sudo cp surflare_early_detector.sh /usr/local/sbin/
sudo chmod 755 /usr/local/sbin/surflare_early_detector.sh

# Node pre-assessment (run every 15 min via cron)
sudo cp surflare_node_probe.sh /usr/local/sbin/
sudo chmod 755 /usr/local/sbin/surflare_node_probe.sh

# Cron entry (root crontab):
# */15 * * * * /usr/local/sbin/surflare_node_probe.sh >> /var/log/surflare_probe.log 2>&1

# Auth setup (optional, TPM2-backed password storage)
sudo bash ./setup_auth.sh
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
MONITOR_INTERVAL=30      # seconds between ss samples
DEGRADATION_THRESHOLD=8  # combined score to fire SIGUSR1
COOLDOWN=120             # minimum seconds between signals
```

**`surflare_node_probe.sh`**

```bash
NODE_CANDIDATES=(...)    # must match watchdog list
TRANSIT_CANDIDATES=(..   # must match watchdog list
PROBE_CONNECT_TIMEOUT=8  # surflare connect timeout per candidate
PROBE_CURL_TIMEOUT=5     # L7 TTFB measurement timeout
PROBE_PCAP_DURATION=4    # pcap capture seconds for transit analysis
```

---

## Usage

```bash
sudo systemctl start surflare-watchdog
sudo systemctl stop  surflare-watchdog

# Early detector (start alongside watchdog)
sudo /usr/local/sbin/surflare_early_detector.sh &

# Manual node pre-assessment
sudo /usr/local/sbin/surflare_node_probe.sh

# View logs
sudo dmesg | grep surflare_watchdog
sudo dmesg -w | grep surflare        # live tail

# View probe results
python3 -m json.tool /run/surflare_probe_results.json
```

---

## Key Log Messages

| Message | Meaning |
|---|---|
| `VPN healthy: exit=US` | Periodic heartbeat |
| `EARLY_WARN_TRIGGERED` | Detector fired USR1; immediate health check started |
| `EARLY_WARN: running immediate health check` | USR1 acted on |
| `node_probe active; deferring ...` | Watchdog yielding cycle to probe |
| `node_probe marker stale; reclaiming session` | Probe died or hung; watchdog reclaiming |
| `Health check TCP block` | All probes stall at TCP layer; reconnect triggered |
| `Node rotation: X -> Y (N/M)` | Switching to next candidate |
| `Storm protection triggered` | All candidates exhausted; cooling down |
| `Local VPN state lost` | Proxy process or routing rules missing |
| `early_detector_stale` | Detector heartbeat overdue; coverage degraded |

---

## Supported Distributions

Any systemd-based Linux: Fedora, Ubuntu, Debian, Arch, openSUSE.
