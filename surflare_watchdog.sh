#!/bin/bash
# Surflare VPN watchdog + resume auto-reconnect
#
# Usage:
#   Daemon mode : sudo /usr/local/sbin/surflare_watchdog.sh
#   Wake hook   : called automatically by systemd-sleep (do not run manually)
#   Deploy      : # Run from repo root; set NODE below before copying (e.g. NODE="auto")
#                 sudo cp surflare_watchdog.sh /usr/local/sbin/
#                 sudo chown root:root /usr/local/sbin/surflare_watchdog.sh
#                 sudo chmod 755 /usr/local/sbin/surflare_watchdog.sh
#                 sudo ln -sf /usr/local/sbin/surflare_watchdog.sh \
#                     /etc/systemd/system-sleep/surflare-resume.sh
#                 sudo cp 99-surflare-resume /etc/NetworkManager/dispatcher.d/
#                 sudo chown root:root /etc/NetworkManager/dispatcher.d/99-surflare-resume
#                 sudo chmod 755 /etc/NetworkManager/dispatcher.d/99-surflare-resume
# View logs    : sudo dmesg | grep surflare_watchdog

NODE="Tokyo"                          # Set to your node tag (run: surflare nodes)
MODE="global"                         # Connection mode: global, rule, direct
TRANSIT=""                            # Transit server for multi-hop: auto, or "" to disable
CHECK_INTERVAL=30                     # Exit IP check interval in seconds
FAIL_THRESHOLD=4                      # Consecutive failures before reconnect
LOCK_FILE=/run/surflare_watchdog.lock # Mutex lock to prevent concurrent reconnects
PIDFILE=/run/surflare_watchdog.pid    # PID file for reliable daemon shutdown
DISCONNECT_SETTLE=2                   # seconds after surflare disconnect before killing processes
CONNECT_SETTLE=10                     # seconds after surflare connect --daemon for VPN to establish
NETWORK_WAIT_FALLBACK=15              # seconds to wait for network when nm-online is unavailable
NETWORK_WAIT_TIMEOUT=30               # nm-online timeout in seconds
PROCESS_EXIT_TIMEOUT=20               # seconds to wait for SIGTERM before escalating to SIGKILL
STORM_MAX=5                           # consecutive unconfirmed reconnects before cooling
STORM_COOLING=600                     # seconds to cool down after storm protection triggers
TOKEN_REFRESH_INTERVAL=1800           # seconds between proactive auth token refreshes (30 min)
LOGIN_RETRIES=5                       # max login attempts per refresh cycle
LOGIN_RETRY_DELAY=3                   # seconds between login retries

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
# Primary: Google reachability — Google is blocked by GFW, so HTTP 200 = VPN is working.
# Fallback: ip-api.com country code (plain HTTP, no TLS — faster than ipinfo.io).
# This replaces the ipinfo.io/cloudflare approach which caused frequent false-positive
# timeouts through VPN exit nodes, triggering unnecessary reconnects.
check_vpn_health() {
	# Primary: Google reachability (0.9s avg, most reliable from behind GFW)
	local http_code
	http_code=$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' https://www.google.com 2>/dev/null)
	if [ "$http_code" = "200" ] || [ "$http_code" = "301" ] || [ "$http_code" = "302" ]; then
		echo "OK"
		return
	fi
	# Fallback: ip-api.com returns country code directly (plain HTTP, no TLS)
	local result
	result=$(curl -s --max-time 3 'http://ip-api.com/line/?fields=countryCode' 2>/dev/null | tr -d '[:space:]')
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

# refresh_auth: refresh surflare auth token using stored credentials (TPM2-encrypted via systemd-creds).
# Retries LOGIN_RETRIES times with LOGIN_RETRY_DELAY between attempts — surflare API is
# sometimes unreachable even with VPN up. Returns 0 if any attempt succeeds.
refresh_auth() {
	local email="${SURFLARE_EMAIL:-}"
	local password=""

	# Read password from systemd credentials directory (TPM2-decrypted at runtime)
	if [ -n "$CREDENTIALS_DIRECTORY" ] && [ -f "$CREDENTIALS_DIRECTORY/surflare-password" ]; then
		password=$(cat "$CREDENTIALS_DIRECTORY/surflare-password")
	fi

	if [ -z "$email" ] || [ -z "$password" ]; then
		return 1 # no credentials available — skip silently
	fi

	local i=0
	while [ "$i" -lt "$LOGIN_RETRIES" ]; do
		if timeout 15 surflare login -u "$email" -p "$password" --remember >/dev/null 2>&1; then
			log "Auth token refreshed successfully (attempt $((i + 1))/${LOGIN_RETRIES})"
			return 0
		fi
		i=$((i + 1))
		[ "$i" -lt "$LOGIN_RETRIES" ] && sleep "$LOGIN_RETRY_DELAY"
	done
	log "Auth token refresh failed after ${LOGIN_RETRIES} attempts"
	return 1
}

connect_vpn() {
	# flock prevents concurrent calls from watchdog loop and systemd-sleep post hook
	(
		flock -n 9 || {
			log "connect_vpn already running, skipping"
			exit 2
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

		# Flush residual nftables/routing rules that surflare disconnect may have missed.
		# Without this, all TCP/UDP traffic stays fwmark'd → routed to table 100 → loopback
		# → ECONNREFUSED, causing "Account check failed" on the next connect attempt.
		log "Flushing residual nftables rules and policy routing..."
		if nft list table inet surflare >/dev/null 2>&1; then
			nft flush table inet surflare 2>/dev/null || true
			nft delete table inet surflare 2>/dev/null &&
				log "Removed residual nftables table inet surflare" || true
		fi
		# Loop: ip rule del only removes one entry at a time; drain all matching rules
		local rule_count=0
		while ip rule del fwmark 0x1 lookup 100 2>/dev/null; do
			rule_count=$((rule_count + 1))
		done
		[ "$rule_count" -gt 0 ] && log "Removed ${rule_count} residual ip rule(s) fwmark 0x1 lookup 100"
		ip route flush table 100 2>/dev/null || true

		# Attempt auth refresh before connecting — surflare API may still be
		# reachable briefly after nftables flush restores direct network access
		refresh_auth || true

		log "Connecting to ${NODE} mode=${MODE:-global} transit=${TRANSIT:-off} (daemon mode)..."
		if ! surflare connect --node "$NODE" \
			${MODE:+--mode "$MODE"} \
			${TRANSIT:+--transit "$TRANSIT"} \
			--daemon 9>&-; then
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
last_refresh=$(date +%s)
log "watchdog started: node=${NODE} interval=${CHECK_INTERVAL}s threshold=${FAIL_THRESHOLD}"

while true; do
	health=$(check_vpn_health)

	if [ "$health" = "OK" ]; then
		# VPN is healthy (Google reachable = not behind GFW)
		fail_count=0
		reconnect_count=0
	elif [ "$health" = "CN" ] || [ -z "$health" ]; then
		# VPN is down: exit country is CN, or both health checks failed/timed out
		fail_count=$((fail_count + 1))
		log "Health check failed (${health:-timeout}), consecutive count: ${fail_count}"
		if [ "$fail_count" -ge "$FAIL_THRESHOLD" ]; then
			log "Consecutive failures: ${fail_count}, starting reconnect..."
			connect_vpn
			rc=$?
			if [ "$rc" -eq 2 ]; then
				# connect_vpn was skipped (another instance holds flock).
				# Reset fail_count to FAIL_THRESHOLD-1 so we retry once next cycle
				# instead of re-triggering every 30s and spamming the log.
				log "Reconnect skipped (flock held), will retry next cycle"
				fail_count=$((FAIL_THRESHOLD - 1))
			elif [ "$rc" -eq 0 ]; then
				new_health=$(check_vpn_health)
				log "Post-reconnect health: ${new_health:-failed}"
				if [ "$new_health" = "OK" ] || { [ "$new_health" != "CN" ] && [ -n "$new_health" ]; }; then
					fail_count=0
					reconnect_count=0
				else
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
		# Non-CN country returned by fallback — VPN is working
		fail_count=0
		reconnect_count=0
		# Proactive token refresh while VPN is healthy — keeps auth.dat fresh so
		# reconnects after VPN failure don't need to reach surflare API (blocked by GFW)
		now=$(date +%s)
		if [ $((now - last_refresh)) -ge "$TOKEN_REFRESH_INTERVAL" ]; then
			refresh_auth && last_refresh=$(date +%s)
		fi
	fi

	# "sleep & wait" allows bash to handle SIGTERM immediately instead of
	# blocking until sleep finishes (up to 60s or 600s during storm cooling)
	sleep "$CHECK_INTERVAL" &
	wait $!
done
