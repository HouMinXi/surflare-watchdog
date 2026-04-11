# surflare-watchdog

A watchdog daemon for [Surflare VPN](https://www.surflare.com) on Linux laptops.
Solves two problems:

1. **Silent tunnel failure**: Surflare UI shows "Connected" but traffic leaks through local ISP
2. **Resume after sleep**: VPN is not reconnected after opening the laptop lid

## How it works

- Checks exit IP country every 60 seconds via `curl ipinfo.io/country`
- If exit country is `CN` (or check times out) for 2 consecutive cycles, reconnects automatically
- On system resume, reconnects immediately via a `systemd-sleep` hook
- Before reconnecting, runs `surflare disconnect` to cleanly remove nftables tproxy rules and
  iproute2 policy routing — preventing the network from being locked to a dead proxy port
- Uses `flock` to prevent the watchdog loop and sleep hook from reconnecting simultaneously
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
git clone git@github.com:HouMinXi/surflare-watchdog.git
cd surflare-watchdog

# 2. Make executable
chmod +x surflare_watchdog.sh

# 3. Set your node tag — run: surflare nodes, then edit NODE= in the script

# 4. Install the wake hook (one-time)
sudo ln -sf "$(pwd)/surflare_watchdog.sh" \
    /etc/systemd/system-sleep/surflare-resume.sh
```

## Usage

**Requires root.** The script writes to `/dev/kmsg`, calls `surflare`, and manages system processes.

```bash
# Start watchdog (background, survives terminal close)
nohup sudo /path/to/surflare_watchdog.sh &

# Stop (recommended)
# Reliable shutdown via PID file
sudo kill "$(cat /run/surflare_watchdog.pid)"

# View logs
sudo dmesg | grep surflare_watchdog
sudo dmesg -w | grep surflare_watchdog   # live
```

> On systems with `dmesg_restrict=1` (e.g. Ubuntu), use `sudo dmesg`.

## Configuration

Edit the three variables at the top of `surflare_watchdog.sh`:

```bash
NODE="your_node_tag"  # Your node tag from: surflare nodes
CHECK_INTERVAL=60     # Seconds between exit IP checks
FAIL_THRESHOLD=2      # Consecutive failures before reconnect
```

A **failure** is: exit country = `CN`, or the `ipinfo.io` request times out.

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
