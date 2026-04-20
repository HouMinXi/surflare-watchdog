# surflare-watchdog

A watchdog daemon for [Surflare VPN](https://www.surflare.com) on Linux laptops.
Solves two problems (with optional headless support):

1. **Silent tunnel failure**: Surflare UI shows "Connected" but traffic leaks through local ISP
2. **Resume after sleep**: VPN is not reconnected after opening the laptop lid
3. *(Optional)* **Headless / lid-closed use**: Closing the lid while the external monitor is
   powered off triggers suspend and interrupts the watchdog — `lid-ignore.conf` prevents this

## How it works

### Health check (two-layer)

Every 30 seconds the watchdog runs a two-layer health check:

**Layer 1 — Local state** (< 5 ms, no network):
Checks three local indicators deterministically:
1. `surflare-proxy` process is running
2. `nftables table inet surflare` exists
3. `fwmark 0x1 → table 100` policy routing rule is present

If any indicator is missing → **LOCAL_FAIL**: VPN is definitively down. Triggers immediate
reconnect without waiting for the `FAIL_THRESHOLD` accumulation cycle.

**Layer 2 — Parallel external probes** (run concurrently, max 8 s each):
- **Primary**: `https://www.google.com` — Google is blocked by GFW, so HTTP 200/301/302 = VPN working
- **Fallback**: `https://ip-api.com/line/?fields=countryCode` — returns exit country code

Result classification:

| Result | Meaning | Action |
|--------|---------|--------|
| `OK` | Google returned 200/30x | Reset all counters (fail/transient/reconnect) |
| `<country>` (non-CN) | ip-api.com confirmed non-China exit | Reset all counters (fail/transient/reconnect) |
| `CN` | Traffic routing through China — VPN broken | `fail_count++` |
| `""` (timeout, local OK) | Transient network spike | `transient_count++` only |
| `LOCAL_FAIL` | Process/nftables/routing lost | Immediate reconnect |

External timeouts with healthy local state are counted separately as *transients* and do
**not** increment `fail_count` — this eliminates false-positive reconnects caused by
WiFi congestion or VPN server latency spikes.

### Reconnect triggers

- **LOCAL_FAIL**: reconnects immediately (single cycle)
- **`fail_count ≥ FAIL_THRESHOLD`** (CN exits): reconnects after N consecutive real failures
- **`transient_count ≥ TRANSIENT_THRESHOLD`**: escalates one `fail_count` after sustained timeouts

### Other behaviours

- On system resume, reconnects immediately — two hooks cover different suspend modes:
  - **S3 (mem) suspend**: `systemd-sleep` hook (`surflare-resume.sh` symlink)
  - **s2idle (S0ix/freeze) suspend**: NetworkManager dispatcher (`99-surflare-resume`),
    triggered when a physical interface comes up after wake — most modern laptops use s2idle
- Before reconnecting, explicitly flushes `table inet surflare` nftables rules and drains
  all `fwmark 0x1 → table 100` ip rules — prevents "Account check failed" deadlock when
  `surflare disconnect` leaves residual routing rules after a partial failure
- Proactively refreshes surflare auth token every 30 minutes while VPN is healthy — prevents
  the chicken-and-egg deadlock where reconnect needs a valid token but the token server is
  blocked by GFW without VPN. Credentials are stored TPM2-encrypted via `systemd-creds`
- Uses `flock` to prevent the watchdog loop and sleep hook from reconnecting simultaneously
- Storm protection: after 5 consecutive reconnects without health confirmation, enters a 10-minute
  cooling period — prevents reconnect storms when the health check endpoint is temporarily down
- Logs to `/dev/kmsg` (visible via `dmesg`), no log files created
- *(Optional)* `lid-ignore.conf` configures systemd-logind to ignore lid-switch events in
  all power states — keeps the machine awake when running headless (lid closed, no external
  monitor), so the watchdog is never interrupted by accidental suspend

## Requirements

| Command | Package |
|---------|---------|
| `curl` | curl |
| `killall` | psmisc |
| `pgrep` | procps-ng / procps |
| `flock` | util-linux |
| `nft` | nftables |
| `surflare` / `surflare-proxy` | from Surflare installation |
| `nm-online` | NetworkManager *(optional — falls back to `sleep 15s` if not found)* |

Supports Fedora, Ubuntu, Debian, Arch, openSUSE and other systemd-based distros.

## Installation

### Quick install (recommended)

```bash
# 1. Clone
git clone https://github.com/HouMinXi/surflare-watchdog.git
cd surflare-watchdog

# 2. Set your node — use "auto" or a specific tag from: surflare nodes
nano surflare_watchdog.sh   # set NODE="auto"

# 3. Encrypt surflare password with TPM2 for proactive auth token refresh
echo -n 'YOUR_PASSWORD' | sudo systemd-creds encrypt \
    --name=surflare-password - /etc/surflare/surflare-password.cred

# 4. Run the installer (installs watchdog, service, hooks, and Wi-Fi tuning)
sudo ./install.sh

# 5. (Optional) Prevent suspend when lid is closed — for headless / lid-closed use
sudo mkdir -p /etc/systemd/logind.conf.d
sudo install -o root -g root -m 0644 lid-ignore.conf \
    /etc/systemd/logind.conf.d/lid-ignore.conf
sudo systemctl kill -s HUP systemd-logind
```

`install.sh` is idempotent — safe to re-run after updates.
Pass `--no-wifi` to skip Wi-Fi power-save tuning (non-Intel cards or headless machines).

### Manual install

<details>
<summary>Expand for step-by-step manual instructions</summary>

```bash
# 1. Clone
git clone https://github.com/HouMinXi/surflare-watchdog.git
cd surflare-watchdog

# 2. Set your node — use "auto" or a specific tag from: surflare nodes
nano surflare_watchdog.sh   # set NODE="auto"

# 3. Check your suspend mode FIRST — this determines which hook to install
cat /sys/power/mem_sleep
# Output examples:
#   s2idle [mem]   → S3 mode  → do step 4a
#   [s2idle] mem   → s2idle   → do step 4b  (most modern laptops)
#   [s2idle]       → s2idle   → do step 4b

# 4. Install watchdog to a stable root-owned path (required by the resume hook security check)
sudo install -o root -g root -m 0755 surflare_watchdog.sh \
    /usr/local/sbin/surflare_watchdog.sh

# 4a. S3 (mem) suspend — only if step 3 showed [mem]
sudo mkdir -p /etc/systemd/system-sleep
sudo ln -sf /usr/local/sbin/surflare_watchdog.sh \
    /etc/systemd/system-sleep/surflare-resume.sh

# 4b. s2idle (S0ix/freeze) suspend — most modern laptops, do this if step 3 showed [s2idle]
sudo install -o root -g root -m 0755 99-surflare-resume \
    /etc/NetworkManager/dispatcher.d/99-surflare-resume

# 5. Encrypt surflare password with TPM2 for proactive auth token refresh
#    (the watchdog refreshes the token every 30 min while VPN is up, so reconnects
#    after VPN failure don't need to reach surflare API — which is blocked by GFW)
echo -n 'YOUR_PASSWORD' | sudo systemd-creds encrypt \
    --name=surflare-password - /etc/surflare/surflare-password.cred

# 6. Install and start the watchdog as a systemd service
sudo cp surflare-watchdog.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now surflare-watchdog

# 7. (Optional) Prevent suspend when lid is closed — for headless / lid-closed use
#    Without this, closing the lid while the external monitor is off will suspend
#    the machine and interrupt the watchdog.
sudo mkdir -p /etc/systemd/logind.conf.d
sudo install -o root -g root -m 0644 lid-ignore.conf \
    /etc/systemd/logind.conf.d/lid-ignore.conf
sudo systemctl kill -s HUP systemd-logind
# Verify:
systemd-analyze cat-config systemd/logind.conf | grep -i HandleLid
```

> **Note**: The resume hook (step 4a/4b) only reconnects after sleep/wake.
> The watchdog daemon (step 6) monitors the tunnel continuously and reconnects
> when it silently fails. **Both are needed.**

> **Security note**: `99-surflare-resume` runs as root and calls `/usr/local/sbin/surflare_watchdog.sh`.
> It verifies the watchdog is `root`-owned and not group/world-writable before executing —
> step 4 above satisfies this requirement.

> **Credential note**: The TPM2-encrypted password in step 5 never appears in plain text on disk.
> `systemd-creds` encrypts it with the machine's TPM2 chip; it is only decrypted at runtime
> into a tmpfs that only the watchdog service can read (`$CREDENTIALS_DIRECTORY`).

</details>

## Migration from older setup

If you installed an earlier version (script in `~/surflare_watchdog.sh`, no systemd
service, or hooks pointing to the home directory), follow these steps.

### What changed

| Component | Old | New |
|-----------|-----|-----|
| Script location | `~/surflare_watchdog.sh` (user-owned) | `/usr/local/sbin/surflare_watchdog.sh` (root-owned) |
| systemd-sleep hook | symlink → home dir | symlink → `/usr/local/sbin/` |
| NetworkManager dispatcher | `WATCHDOG=~/surflare_watchdog.sh` | `WATCHDOG=/usr/local/sbin/surflare_watchdog.sh` |
| Daemon startup | manual `nohup` | systemd service (auto-start on boot) |
| nftables cleanup | relied on `surflare disconnect` only | explicit flush of residual rules after killall |
| Auth token | no refresh, expired token → deadlock | proactive refresh every 30 min via TPM2-encrypted creds |
| Poll interval | 60 s | 30 s |
| NODE default | fixed node tag | `auto` (Surflare picks best node) |
| Health check | single external HTTP (false positives on congestion) | two-layer: local state + parallel external probes |
| Timeout handling | timeout = failure → fake reconnects | timeout with healthy local state = transient, no reconnect |
| Process/routing loss | detected after 4×30s external timeout | detected immediately via local state check (LOCAL_FAIL) |

**Old symptom 1** — resume hook logged and did nothing:
```
surflare_resume: watchdog not root-owned (uid=1000), refusing exec
```
**Cause**: script in home dir is user-owned; the dispatcher refuses to exec it.

**Old symptom 2** — watchdog logged repeatedly during reconnect and required manual login:
```
✘ Account check failed — Could not verify account status. Check network.
```
**Cause 1**: `surflare disconnect` left residual nftables rules; all traffic was routed to
loopback after `killall surflare-proxy`, blocking the next connect attempt.
**Cause 2**: auth token in `auth.dat` expired; surflare API is blocked by GFW without VPN,
so `surflare connect` could not refresh the token — a chicken-and-egg deadlock.

### Migration steps

```bash
# Run from the cloned/updated repo root

# 1. Stop the old watchdog if running
sudo kill "$(cat /run/surflare_watchdog.pid 2>/dev/null)" 2>/dev/null || true

# 2. Set your node — edit NODE= in surflare_watchdog.sh before copying
#    Use NODE="auto" (recommended) or a specific tag from: surflare nodes
nano surflare_watchdog.sh

# 3. Deploy script to /usr/local/sbin/ (root-owned — required by security check)
sudo install -o root -g root -m 0755 surflare_watchdog.sh \
    /usr/local/sbin/surflare_watchdog.sh

# 4. Update the systemd-sleep symlink to point to the new location
sudo ln -sf /usr/local/sbin/surflare_watchdog.sh \
    /etc/systemd/system-sleep/surflare-resume.sh

# 5. Redeploy the NetworkManager dispatcher (now points to /usr/local/sbin/)
sudo install -o root -g root -m 0755 99-surflare-resume \
    /etc/NetworkManager/dispatcher.d/99-surflare-resume

# 6. Encrypt surflare password for proactive token refresh (requires TPM2)
echo -n 'YOUR_PASSWORD' | sudo systemd-creds encrypt \
    --name=surflare-password - /etc/surflare/surflare-password.cred

# 7. Install and enable the systemd service
sudo cp surflare-watchdog.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now surflare-watchdog

# 8. Verify
sudo systemctl status surflare-watchdog
stat -c 'uid=%u mode=%a' /usr/local/sbin/surflare_watchdog.sh  # expect uid=0 mode=755
grep "^WATCHDOG=" /etc/NetworkManager/dispatcher.d/99-surflare-resume
# expect: WATCHDOG=/usr/local/sbin/surflare_watchdog.sh
sudo dmesg | grep "Auth token refreshed" | tail -1
# expect: surflare_watchdog: Auth token refreshed successfully

# 9. Optional: remove the old script from home directory
rm -f ~/surflare_watchdog.sh
```

## Usage

**Requires root.** The script writes to `/dev/kmsg`, calls `surflare`, and manages system processes.

### systemd (recommended)

```bash
sudo systemctl status surflare-watchdog
sudo systemctl stop surflare-watchdog
sudo systemctl restart surflare-watchdog
```

### Manual / fallback

```bash
# Start
nohup sudo /usr/local/sbin/surflare_watchdog.sh &

# Stop
sudo kill "$(cat /run/surflare_watchdog.pid)"
```

### View logs

```bash
sudo dmesg | grep surflare_watchdog
sudo dmesg -w | grep surflare_watchdog   # live
```

> On systems with `dmesg_restrict=1` (e.g. Ubuntu), use `sudo dmesg`.

## Wi-Fi Stability

On Intel Wi-Fi cards, the default driver power-saving scheme causes the firmware to
periodically miss beacon frames from the AP. This triggers the kernel message:

```
iwlwifi: missed beacons exceeds threshold, but receiving data. Stay connected, Expect bugs.
```

followed by AP disconnects and immediate re-associations — even at excellent signal strength.
The symptoms look like VPN instability (health check timeouts) but originate at the Wi-Fi
hardware layer.

`install.sh` applies two fixes automatically:

| Layer | Config file | Effect |
|-------|------------|--------|
| NetworkManager | `conf/nm-wifi-power.conf` | Sets `wifi.powersave = 2` (disabled) |
| Intel driver (`iwlmld` / `iwlmvm`) | `conf/modprobe-iwlmld.conf` or `conf/modprobe-iwlmvm.conf` | Sets `power_scheme=1` (CAM — Continuously Active Mode) |

Both layers must be disabled independently; NM's power_save setting alone does not override
the driver-level power scheme.

If you are not using an Intel Wi-Fi card, or are on a headless/wired-only machine, run:

```bash
sudo ./install.sh --no-wifi
```

## Configuration

Edit variables at the top of `surflare_watchdog.sh` **before deploying**:

```bash
NODE="auto"           # "auto" = Surflare picks best node, or set a specific tag
MODE="rule"           # Connection mode: global, rule, direct (rule = Smart Routing)
TRANSIT="auto"        # Transit server for multi-hop: "auto", or "" to disable
CHECK_INTERVAL=30     # Seconds between exit IP checks
FAIL_THRESHOLD=4      # Consecutive CN-exit failures before reconnect

# Two-layer health check thresholds
TRANSIENT_THRESHOLD=6 # Consecutive external timeouts (local state OK) before one fail_count escalation
HEARTBEAT_INTERVAL=600 # Seconds between "VPN healthy" log entries (0 = off)

# Tunable timeouts (seconds)
DISCONNECT_SETTLE=2   # Wait after surflare disconnect before killing processes
CONNECT_SETTLE=10     # Wait after surflare connect --daemon for VPN to establish
PROCESS_EXIT_TIMEOUT=20  # SIGTERM grace period before escalating to SIGKILL

# Storm protection — prevents reconnect loops when the health check endpoint is down
STORM_MAX=5           # Consecutive unconfirmed reconnects before cooling
STORM_COOLING=600     # Cooling period in seconds (default: 10 minutes)

# Auth token refresh — keeps token valid so reconnects don't need surflare API
TOKEN_REFRESH_INTERVAL=1800  # Seconds between proactive refreshes (30 min)
LOGIN_RETRIES=5              # Max login attempts per refresh (API is intermittent)
LOGIN_RETRY_DELAY=3          # Seconds between login retries
```

**Reconnect conditions:**

| Trigger | Condition |
|---------|-----------|
| Local state lost | Process/nftables/routing gone → immediate reconnect |
| CN exit | `fail_count ≥ FAIL_THRESHOLD` consecutive CN-exit results |
| Persistent timeout | `transient_count ≥ TRANSIENT_THRESHOLD` consecutive timeouts escalate `fail_count` by 1 |

Google reachability (HTTP 200/301/302) is the primary health signal — Google is blocked by
GFW, so a 200 response confirms traffic is exiting via VPN.

After editing, redeploy with:

```bash
sudo install -o root -g root -m 0755 surflare_watchdog.sh \
    /usr/local/sbin/surflare_watchdog.sh
sudo systemctl restart surflare-watchdog
```

## Log output

Normal operation is **silent** — no log entries while VPN is healthy (except the
optional heartbeat every `HEARTBEAT_INTERVAL` seconds).

**Startup:**
```
surflare_watchdog: watchdog started: node=Tokyo interval=30s threshold=4 transient=6
```

**Transient network timeout (local state OK — not a real failure, no reconnect):**
```
surflare_watchdog: Health check transient timeout (local state OK), transient 1/6
surflare_watchdog: Health check transient timeout (local state OK), transient 2/6
```

**CN exit detected (real failure — increments fail_count):**
```
surflare_watchdog: Health check failed (CN exit), consecutive count: 1
surflare_watchdog: Health check failed (CN exit), consecutive count: 4
surflare_watchdog: Consecutive failures: 4, starting reconnect...
```

**Local state lost — immediate reconnect (no accumulation needed):**
```
surflare_watchdog: Local VPN state lost (process/nftables/routing), triggering immediate reconnect
surflare_watchdog: Consecutive failures: 4, starting reconnect...
```

**Full reconnect sequence:**
```
surflare_watchdog: Disconnecting cleanly, flushing nftables tproxy rules and policy routing...
surflare_watchdog: Killing remaining processes...
surflare_watchdog: Flushing residual nftables rules and policy routing...
surflare_watchdog: Removed residual nftables table inet surflare
surflare_watchdog: Removed 1 residual ip rule(s) fwmark 0x1 lookup 100
surflare_watchdog: Auth token refreshed successfully (attempt 1/5)
surflare_watchdog: Connecting to Tokyo mode=global transit=off (daemon mode)...
surflare_watchdog: Post-reconnect health: OK
```

**Periodic heartbeat (if `HEARTBEAT_INTERVAL > 0`):**
```
surflare_watchdog: VPN healthy: exit=JP
```

## Background

Surflare on Linux uses nftables tproxy to redirect all TCP/UDP to `surflare-proxy` on port
10800, plus an iproute2 policy routing rule (`fwmark 0x1 → table 100`). When the tunnel
silently drops, these rules stay but the proxy is dead — all traffic hits a closed port.

Killing `surflare` directly leaves orphaned rules. Even calling `surflare disconnect` does
not always clean up fully — if the VPN was not fully established when disconnect is called,
it returns non-zero and leaves `table inet surflare` and the `fwmark 0x1 → table 100` ip
rules intact. After `killall surflare-proxy`, all traffic is routed via those rules to
loopback, causing `surflare connect` to fail immediately with "Account check failed —
Could not verify account status. Check network."

This watchdog explicitly flushes `table inet surflare`, drains all matching ip rules, and
clears routing table 100 after each `killall` — ensuring the system has clean network state
before the next connection attempt.

## Supported distros

Fedora, Ubuntu, Debian, Arch, openSUSE — any systemd-based Linux distro.
