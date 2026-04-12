# surflare-watchdog

A watchdog daemon for [Surflare VPN](https://www.surflare.com) on Linux laptops.
Solves two problems:

1. **Silent tunnel failure**: Surflare UI shows "Connected" but traffic leaks through local ISP
2. **Resume after sleep**: VPN is not reconnected after opening the laptop lid

## How it works

- Checks exit IP country every 60 seconds via `curl ipinfo.io/country` (with Cloudflare
  CDN trace as fallback — two independent endpoints prevent false reconnects)
- If exit country is `CN` (or both health checks time out) for 2 consecutive cycles, reconnects
- On system resume, reconnects immediately — two hooks cover different suspend modes:
  - **S3 (mem) suspend**: `systemd-sleep` hook (`surflare-resume.sh` symlink)
  - **s2idle (S0ix/freeze) suspend**: NetworkManager dispatcher (`99-surflare-resume`),
    triggered when a physical interface comes up after wake — most modern laptops use s2idle
- Before reconnecting, runs `surflare disconnect` to cleanly remove nftables tproxy rules and
  iproute2 policy routing — preventing the network from being locked to a dead proxy port
- Uses `flock` to prevent the watchdog loop and sleep hook from reconnecting simultaneously
- Storm protection: after 5 consecutive reconnects without health confirmation, enters a 10-minute
  cooling period — prevents reconnect storms when the health check endpoint is temporarily down
- Logs to `/dev/kmsg` (visible via `dmesg`), no log files created

## Requirements

| Command | Package |
|---------|---------|
| `curl` | curl |
| `killall` | psmisc |
| `pgrep` | procps-ng / procps |
| `flock` | util-linux |
| `surflare` / `surflare-proxy` | from Surflare installation |
| `nm-online` | NetworkManager *(optional — falls back to `sleep 15s` if not found)* |

Supports Fedora, Ubuntu, Debian, Arch, openSUSE and other systemd-based distros.

## Installation

```bash
# 1. Clone
git clone https://github.com/HouMinXi/surflare-watchdog.git
cd surflare-watchdog

# 2. Make executable
chmod +x surflare_watchdog.sh 99-surflare-resume

# 3. Set your node tag — run: surflare nodes, then edit NODE= in the script
nano surflare_watchdog.sh   # set NODE="your_node_tag"

# 4. Check your suspend mode FIRST — this determines which hook to install
cat /sys/power/mem_sleep
# Output examples:
#   s2idle [mem]   → S3 mode  → do step 5a
#   [s2idle] mem   → s2idle   → do step 5b  (most modern laptops)
#   [s2idle]       → s2idle   → do step 5b

# 5. Install watchdog to a stable root-owned path
sudo install -o root -g root -m 0755 surflare_watchdog.sh \
    /usr/local/sbin/surflare_watchdog.sh

# 5a. S3 (mem) suspend — only if step 4 showed [mem]
sudo mkdir -p /etc/systemd/system-sleep
sudo ln -sf /usr/local/sbin/surflare_watchdog.sh \
    /etc/systemd/system-sleep/surflare-resume.sh

# 5b. s2idle (S0ix/freeze) suspend — most modern laptops, do this if step 4 showed [s2idle]
sudo cp 99-surflare-resume /etc/NetworkManager/dispatcher.d/
sudo chown root:root /etc/NetworkManager/dispatcher.d/99-surflare-resume
```

> **Security note**: `99-surflare-resume` runs as root and calls `/usr/local/sbin/surflare_watchdog.sh`.
> It verifies the watchdog is `root`-owned and not group/world-writable before executing —
> step 5 above satisfies this requirement.

## Usage

**Requires root.** The script writes to `/dev/kmsg`, calls `surflare`, and manages system processes.

```bash
# Start watchdog (background, survives terminal close)
nohup sudo /usr/local/sbin/surflare_watchdog.sh &

# Stop (recommended)
# Reliable shutdown via PID file
sudo kill "$(cat /run/surflare_watchdog.pid)"

# View logs
sudo dmesg | grep surflare_watchdog
sudo dmesg -w | grep surflare_watchdog   # live
```

> On systems with `dmesg_restrict=1` (e.g. Ubuntu), use `sudo dmesg`.

## Configuration

Edit variables at the top of `surflare_watchdog.sh`:

```bash
NODE="your_node_tag"  # Your node tag from: surflare nodes
CHECK_INTERVAL=60     # Seconds between exit IP checks
FAIL_THRESHOLD=2      # Consecutive failures before reconnect

# Tunable timeouts (seconds)
DISCONNECT_SETTLE=2   # Wait after surflare disconnect before killing processes
CONNECT_SETTLE=10     # Wait after surflare connect --daemon for VPN to establish
PROCESS_EXIT_TIMEOUT=20  # SIGTERM grace period before escalating to SIGKILL

# Storm protection — prevents reconnect loops when the health check endpoint is down
STORM_MAX=5           # Consecutive unconfirmed reconnects before cooling
STORM_COOLING=600     # Cooling period in seconds (default: 10 minutes)
```

A **failure** is: exit country = `CN`, or both health check endpoints (`ipinfo.io` and
Cloudflare CDN trace) return empty (timeout or unreachable).

## Log output

```
surflare_watchdog: watchdog started: node=your_node_tag interval=60s threshold=2
surflare_watchdog: Exit IP anomaly (CN), consecutive count: 2
surflare_watchdog: Disconnecting cleanly, flushing nftables tproxy rules and policy routing...
surflare_watchdog: Connecting to your_node_tag (daemon mode)...
surflare_watchdog: Post-reconnect exit IP: US
```

## Background

Surflare on Linux uses nftables tproxy to redirect all TCP/UDP to `surflare-proxy` on port
10800, plus an iproute2 policy routing rule (`fwmark 0x1 → table 100`). When the tunnel
silently drops, these rules stay but the proxy is dead — all traffic hits a closed port.

Killing `surflare` directly leaves orphaned rules, causing a deadlock where even the
reconnection attempt is blocked. This watchdog calls `surflare disconnect` first so Surflare
can clean up its own rules before any new connection is attempted.

## Supported distros

Fedora, Ubuntu, Debian, Arch, openSUSE — any systemd-based Linux distro.
