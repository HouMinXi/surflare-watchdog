# surflare-watchdog

A watchdog daemon for [Surflare VPN](https://www.surflare.com) on Linux laptops.
Solves two problems:

1. **Silent tunnel failure**: Surflare UI shows "Connected" but traffic leaks through local ISP
2. **Resume after sleep**: VPN is not reconnected after opening the laptop lid

## Features

- Checks exit IP country every 30s; auto-reconnects after consecutive failures
- **TCP_BLOCK detection**: when all probes stall at TCP layer (DPI blocking), bypasses transient counter for immediate reconnect
- **Node rotation**: cycles through configured nodes on TCP_BLOCK, with persistent state across restarts (`/var/tmp/surflare_rotation`)
- Reconnects immediately after suspend/hibernate resume (`systemd-sleep` hook)
- Probes transit candidates (Tokyo, Seoul) and picks the lowest-latency one
- Cleans up nftables tproxy rules and policy routing before each reconnect
- Flushes stale nftables on LOCAL_FAIL to prevent DNS blockage during reconnect
- `flock` mutex prevents concurrent reconnects from watchdog loop and resume hook
- Logs to `/dev/kmsg` (view with `dmesg`); no log files
- CPU affinity isolation for surflare-proxy and iwlwifi IRQs
- Firmware crash detection with cascade protection and rate-limited cooldown

## Dependencies

| Command | Package |
|---------|---------|
| `curl` | curl |
| `killall` | psmisc |
| `pgrep` | procps-ng / procps |
| `flock` | util-linux |
| `nm-online` | NetworkManager (optional; falls back to fixed sleep) |
| `surflare` / `surflare-proxy` | Surflare installation |

## Install

```bash
git clone git@github.com:HouMinXi/surflare-watchdog.git
cd surflare-watchdog
sudo cp surflare_watchdog.sh /usr/local/sbin/
sudo chown root:root /usr/local/sbin/surflare_watchdog.sh
sudo chmod 755 /usr/local/sbin/surflare_watchdog.sh

# Resume hook
sudo ln -sf /usr/local/sbin/surflare_watchdog.sh \
    /etc/systemd/system-sleep/surflare-resume.sh

# NetworkManager dispatcher hook
sudo cp 99-surflare-resume /etc/NetworkManager/dispatcher.d/
sudo chown root:root /etc/NetworkManager/dispatcher.d/99-surflare-resume
sudo chmod 755 /etc/NetworkManager/dispatcher.d/99-surflare-resume
```

## Usage

```bash
sudo systemctl start surflare-watchdog    # start
sudo systemctl stop surflare-watchdog     # stop
sudo dmesg | grep surflare_watchdog       # view logs
sudo dmesg -w | grep surflare_watchdog    # live tail
```

## Configuration

Edit the variables at the top of `surflare_watchdog.sh`:

```bash
NODE="Los Angeles"                # Default server node (run: surflare nodes)
NODE_CANDIDATES=("Los Angeles" "Dallas" "Atlanta" "Seoul" "Chicago" "Miami" "New York")
MODE="global"                     # Connection mode: global, rule, direct
TRANSIT_CANDIDATES="Tokyo Seoul"  # Transit probe list (lowest latency wins)
CHECK_INTERVAL=30                 # Health check interval (seconds)
FAIL_THRESHOLD=4                  # Consecutive failures before reconnect
```

## Reading the logs

### Health status

The watchdog logs health check results as `exit=<status>`:

| Status | Meaning | Action |
|--------|---------|--------|
| `US` / `JP` / country code | IP geolocation confirms traffic exits from that country | Normal |
| `OK` | Google probe returned 200/30x (tunnel working) | Normal |
| `TUNNEL_OK` | IP probe got a valid response but country could not be determined | Normal |
| `CN` | Traffic exiting through China -- VPN routing is broken | Reconnect triggered |
| (empty) | All probes timed out, local VPN state is OK | Transient, accumulates toward threshold |

### Key log messages

| Log message | What happened |
|-------------|---------------|
| `VPN healthy: exit=US` | Periodic heartbeat, VPN is working |
| `Post-reconnect health: US` | Just reconnected, VPN confirmed working |
| `Health check TCP block` | DPI blocking detected, immediate reconnect |
| `Node rotation: X -> Y (N/M)` | Switching to next node due to TCP_BLOCK |
| `Restored rotation state: X` | Resumed from saved node after restart |
| `Local VPN state lost` | surflare-proxy crashed or was killed |
| `Flushed stale nftables/routing` | Cleaned up orphaned rules from dead proxy |
| `Storm protection triggered` | Too many consecutive reconnect failures, cooling down |
| `iwlwifi crash detected` | WiFi firmware crash, waiting for stabilization |

## Log example

```
surflare_watchdog: watchdog started: node=Los Angeles candidates=7 interval=30s threshold=4 transient=6
surflare_watchdog: Connecting to Los Angeles mode=global transit=Tokyo (daemon mode)...
surflare_watchdog: Post-reconnect health: US
surflare_watchdog: VPN healthy: exit=US
surflare_watchdog: probe timeout google: dns=0.025 tcp=0.000 tls=0.000 ttfb=0.000 stuck=TCP
surflare_watchdog: Node rotation: Los Angeles -> Dallas (2/7)
surflare_watchdog: Health check TCP block (all probes stuck at TCP layer), triggering immediate reconnect
surflare_watchdog: Connecting to Dallas mode=global transit=Tokyo (daemon mode)...
surflare_watchdog: Post-reconnect health: US
```

## Supported distributions

Any systemd-based Linux: Fedora, Ubuntu, Debian, Arch, openSUSE, etc.
