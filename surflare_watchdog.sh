#!/bin/bash
# Surflare VPN watchdog + resume auto-reconnect
#
# Usage:
#   Daemon mode : sudo /path/to/surflare_watchdog.sh
#   Wake hook   : called automatically by systemd-sleep (do not run manually)
#   Install hook: sudo ln -sf /path/to/surflare_watchdog.sh \
#                     /etc/systemd/system-sleep/surflare-resume.sh
# View logs    : sudo dmesg | grep surflare_watchdog

NODE="your_node_tag"                  # Set to your node tag (run: surflare nodes)
CHECK_INTERVAL=60                     # Exit IP check interval in seconds
FAIL_THRESHOLD=2                      # Consecutive failures before reconnect
LOCK_FILE=/run/surflare_watchdog.lock # Mutex lock to prevent concurrent reconnects
PIDFILE=/run/surflare_watchdog.pid    # PID file for reliable daemon shutdown

# Validate NODE is configured (fail fast if placeholder is unchanged)
if [ "$NODE" = "your_node_tag" ]; then
	printf '<3>surflare_watchdog: NODE is not configured. Edit NODE= in the script first.\n' >/dev/kmsg
	echo "NODE is not configured. Edit NODE= in the script first." >&2
	exit 1
fi

# Must run as root (avoids sudo ticket expiry blocking in background)
if [ "$EUID" -ne 0 ]; then
	echo "Must run as root: sudo $0" >&2
	exit 1
fi

# Dependency check
# Package reference (if missing, install the corresponding package):
#   curl          -> curl         (all major distros)
#   killall       -> psmisc       (all major distros)
#   pgrep         -> procps-ng / procps
#   flock         -> util-linux   (all major distros)
#   surflare/surflare-proxy -> from surflare installation
# Note: nm-online is optional (NetworkManager package); falls back to sleep 15s.
for cmd in curl killall pgrep flock surflare surflare-proxy; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		printf '<3>surflare_watchdog: missing dependency: %s, exiting\n' "$cmd" >/dev/kmsg
		exit 1
	fi

done

if ! command -v nm-online >/dev/null 2>&1; then
	printf '<4>surflare_watchdog: nm-online not found, will use fixed sleep on resume\n' >/dev/kmsg
fi

log() {
	printf '<6>surflare_watchdog: %s\n' "$*" >/dev/kmsg
}

wait_for_exit() {
	local name="$1" i=0
	while pgrep -x "$name" >/dev/null 2>&1 && [ "$i" -lt 10 ]; do
		sleep 1
		i=$((i + 1))
	done
	if pgrep -x "$name" >/dev/null 2>&1; then
		log "Process ${name} did not exit after SIGTERM, sending SIGKILL"
		killall -KILL "$name" 2>/dev/null
	fi
}

connect_vpn() {
	# flock prevents concurrent calls from watchdog loop and systemd-sleep post hook
	(
		flock -n 9 || {
			log "connect_vpn already running, skipping"
			exit 0
		}

		log "Disconnecting cleanly, flushing nftables tproxy rules and policy routing..."
		if ! surflare disconnect 2>/dev/null; then
			log "disconnect returned non-zero (may not have been connected), continuing cleanup..."
		fi
		sleep 2

		log "Killing remaining processes..."
		killall surflare surflare-proxy 2>/dev/null
		wait_for_exit surflare
		wait_for_exit surflare-proxy

		log "Connecting to ${NODE} (daemon mode)..."
		if ! surflare connect --node "$NODE" --daemon; then
			log "Connection failed, will retry on next check cycle"
			exit 1
		fi
		sleep 10
		exit 0
	) 9>"$LOCK_FILE"
	return $?
}

# === Wake hook mode (called by systemd-sleep with $1=pre|post) ===
if [ "$1" = "pre" ]; then
	exit 0 # Nothing to do before sleep
fi

if [ "$1" = "post" ]; then
	log "System resumed, waiting for network..."
	if ! command -v nm-online >/dev/null 2>&1; then
		log "nm-online not available, waiting 15s then reconnecting..."
		sleep 15
		if connect_vpn; then
			log "Resume reconnect complete (no nm-online)"
		fi
	elif nm-online -q -t 30 2>/dev/null; then
		log "Network ready, triggering reconnect..."
		if connect_vpn; then
			log "Resume reconnect complete"
		fi
	else
		log "Network not ready within 30s, skipping reconnect (watchdog will retry)"
	fi
	exit 0
fi

# Reject unknown arguments to prevent accidental daemon start
if [ -n "$1" ]; then
	echo "Usage: $0              (daemon mode)" >&2
	echo "       $0 pre|post     (called automatically by systemd-sleep)" >&2
	exit 2
fi

# === Daemon mode (started manually with no arguments) ===

# Prevent duplicate daemon instances
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
	echo "watchdog already running (PID $(cat "$PIDFILE"))" >&2
	exit 1
fi

# Set trap before writing PID to minimise stale-file window on early kill
trap 'log "watchdog stopped"; rm -f "$PIDFILE"; exit 0' INT TERM
echo $$ >"$PIDFILE"

fail_count=0
log "watchdog started: node=${NODE} interval=${CHECK_INTERVAL}s threshold=${FAIL_THRESHOLD}"

while true; do
	country=$(curl -s --max-time 5 ipinfo.io/country 2>/dev/null | tr -d '[:space:]')

	if [ "$country" = "CN" ] || [ -z "$country" ]; then
		fail_count=$((fail_count + 1))
		log "Exit IP anomaly (${country:-timeout}), consecutive count: ${fail_count}"
		if [ "$fail_count" -ge "$FAIL_THRESHOLD" ]; then
			log "Consecutive failures: ${fail_count}, starting reconnect..."
			if connect_vpn; then
				new_country=$(curl -s --max-time 5 ipinfo.io/country 2>/dev/null | tr -d '[:space:]')
				log "Post-reconnect exit IP: ${new_country:-failed}"
				fail_count=0
			fi
		fi
	else
		fail_count=0
	fi

	sleep "$CHECK_INTERVAL"
done
