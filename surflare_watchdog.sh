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
DISCONNECT_SETTLE=2                   # seconds after surflare disconnect before killing processes
CONNECT_SETTLE=10                     # seconds after surflare connect --daemon for VPN to establish
NETWORK_WAIT_FALLBACK=15              # seconds to wait for network when nm-online is unavailable
NETWORK_WAIT_TIMEOUT=30               # nm-online timeout in seconds
PROCESS_EXIT_TIMEOUT=20               # seconds to wait for SIGTERM before escalating to SIGKILL
STORM_MAX=5                           # consecutive unconfirmed reconnects before cooling
STORM_COOLING=600                     # seconds to cool down after storm protection triggers

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

umask 0177
# Restrict new file permissions to 600 (root-only) — prevents non-root users from
# opening the lock file for reading and holding flock to block reconnects

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

# check_vpn_health: returns exit country code, or empty string on any failure.
# Tries ipinfo.io first; falls back to Cloudflare CDN trace on failure.
# Two independent endpoints prevent false reconnects when one endpoint is down.
check_vpn_health() {
	local result
	result=$(curl -s --max-time 5 --max-filesize 16 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]')
	if [ -n "$result" ]; then
		echo "$result"
		return
	fi
	# Fallback: Cloudflare CDN trace (different CDN — independent failure domain)
	result=$(curl -s --max-time 5 --max-filesize 256 https://cloudflare.com/cdn-cgi/trace 2>/dev/null |
		grep '^loc=' | cut -d= -f2 | tr -d '[:space:]')
	echo "$result"
}

wait_for_exit() {
	local name="$1" i=0
	while pgrep -x "$name" >/dev/null 2>&1 && [ "$i" -lt "$PROCESS_EXIT_TIMEOUT" ]; do
		sleep 1
		i=$((i + 1))
	done
	if pgrep -x "$name" >/dev/null 2>&1; then
		log "Process ${name} did not exit after SIGTERM, sending SIGKILL (nftables rules may be orphaned if this is surflare)"
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
		sleep "$DISCONNECT_SETTLE"

		log "Killing remaining processes..."
		killall surflare surflare-proxy 2>/dev/null
		wait_for_exit surflare
		wait_for_exit surflare-proxy

		log "Connecting to ${NODE} (daemon mode)..."
		if ! surflare connect --node "$NODE" --daemon; then
			log "Connection failed, will retry on next check cycle"
			exit 1
		fi
		sleep "$CONNECT_SETTLE"
		# Process-level sanity check: verify surflare-proxy is running
		if ! pgrep -x surflare-proxy >/dev/null 2>&1; then
			log "VPN establishment timed out: surflare-proxy not running after ${CONNECT_SETTLE}s"
			exit 1
		fi
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
		log "nm-online not available, waiting ${NETWORK_WAIT_FALLBACK}s then reconnecting..."
		sleep "$NETWORK_WAIT_FALLBACK"
		if connect_vpn; then
			log "Resume reconnect complete (no nm-online)"
		else
			log "Resume reconnect failed (no nm-online), watchdog will retry"
		fi
	elif nm-online -q -t "$NETWORK_WAIT_TIMEOUT" 2>/dev/null; then
		log "Network ready, triggering reconnect..."
		if connect_vpn; then
			log "Resume reconnect complete"
		else
			log "Resume reconnect failed, watchdog will retry"
		fi
	else
		log "Network not ready within ${NETWORK_WAIT_TIMEOUT}s, skipping reconnect (watchdog will retry)"
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
trap 'rm -f "$PIDFILE"' EXIT
echo $$ >"$PIDFILE"

fail_count=0
reconnect_count=0
log "watchdog started: node=${NODE} interval=${CHECK_INTERVAL}s threshold=${FAIL_THRESHOLD}"

while true; do
	country=$(check_vpn_health)

	if [ "$country" = "CN" ] || [ -z "$country" ]; then
		fail_count=$((fail_count + 1))
		log "Exit IP anomaly (${country:-timeout}), consecutive count: ${fail_count}"
		if [ "$fail_count" -ge "$FAIL_THRESHOLD" ]; then
			log "Consecutive failures: ${fail_count}, starting reconnect..."
			if connect_vpn; then
				new_country=$(check_vpn_health)
				log "Post-reconnect exit IP: ${new_country:-failed}"
				if [ "$new_country" != "CN" ] && [ -n "$new_country" ]; then
					# Health check confirmed — reset all counters
					fail_count=0
					reconnect_count=0
				else
					# Reconnect succeeded but health endpoint still anomalous
					# (endpoint may be temporarily down — avoid reconnect storm)
					reconnect_count=$((reconnect_count + 1))
					log "Post-reconnect health check anomalous (reconnect_count=${reconnect_count})"
					if [ "$reconnect_count" -ge "$STORM_MAX" ]; then
						log "Storm protection triggered: cooling for ${STORM_COOLING}s"
						sleep "$STORM_COOLING" &
						wait $!
						reconnect_count=0
						fail_count=0
					fi
				fi
			else
				# Connection attempt failed — also count toward storm protection
				reconnect_count=$((reconnect_count + 1))
				log "Reconnect attempt failed (reconnect_count=${reconnect_count})"
				if [ "$reconnect_count" -ge "$STORM_MAX" ]; then
					log "Storm protection triggered (connect failure): cooling for ${STORM_COOLING}s"
					sleep "$STORM_COOLING" &
					wait $!
					reconnect_count=0
					fail_count=0
				fi
			fi
		fi
	else
		fail_count=0
		reconnect_count=0
	fi

	# "sleep & wait" allows bash to handle SIGTERM immediately instead of
	# blocking until sleep finishes (up to 60s or 600s during storm cooling)
	sleep "$CHECK_INTERVAL" &
	wait $!
done
