# surflare-watchdog

A watchdog daemon for [Surflare VPN](https://www.surflare.com) on Linux laptops.
Solves two problems:

1. **Silent tunnel failure**: Surflare UI shows "Connected" but traffic leaks through local ISP
2. **Resume after sleep**: VPN is not reconnected after opening the laptop lid

## Features

- Checks exit IP country every 30s; auto-reconnects after consecutive failures
- Reconnects immediately after suspend/hibernate resume (`systemd-sleep` hook)
- Probes transit candidates (Tokyo, Seoul) and picks the lowest-latency one
- Cleans up nftables tproxy rules and policy routing before each reconnect
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
NODE="Los Angeles"                # Server node (run: surflare nodes)
TRANSIT_CANDIDATES="Tokyo Seoul"  # Transit probe list (lowest latency wins)
CHECK_INTERVAL=30                 # Health check interval (seconds)
FAIL_THRESHOLD=4                  # Consecutive failures before reconnect
```

## Log example

```
surflare_watchdog: watchdog started: node=Los Angeles interval=30s threshold=4 transient=4
surflare_watchdog: Probing transit candidate: Tokyo
surflare_watchdog: Probe Tokyo: 1543ms
surflare_watchdog: Best transit: Tokyo (1543ms)
surflare_watchdog: Connecting to Los Angeles mode=global transit=Tokyo (daemon mode)...
surflare_watchdog: Post-reconnect health: OK
```

## Supported distributions

Any systemd-based Linux: Fedora, Ubuntu, Debian, Arch, openSUSE, etc.
