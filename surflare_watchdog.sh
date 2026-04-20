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
HEARTBEAT_INTERVAL=600                # seconds between periodic "VPN healthy" log entries (0=off)
TRANSIENT_THRESHOLD=6                 # consecutive external timeouts (local state OK) before escalating to fail_count

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

# check_vpn_local_state: fast local-only check — no network calls.
# Returns 0 if all three local VPN indicators are present, 1 if any is missing.
# Indicators: surflare-proxy process + nftables table + fwmark policy routing rule.
# A LOCAL_FAIL means the VPN is definitively down (not a transient network timeout).
check_vpn_local_state() {
	pgrep -x surflare-proxy >/dev/null 2>&1 || return 1
	nft list table inet surflare >/dev/null 2>&1 || return 1
	ip rule show | grep -q 'fwmark 0x1 lookup 100' || return 1
	return 0
}

# check_vpn_health: two-layer check — local state first, then parallel external probes.
# Returns:
#   "OK"         — Google 200/30x (VPN is working, GFW bypassed)
#   "LOCAL_FAIL" — local VPN state lost (process/nftables/routing gone)
#   <country>    — ip-api.com returned a country code (non-empty)
#   ""           — both external probes timed out (but local state was OK = transient)
# "CN" is a valid country code return (VPN up but routing via China = broken exit).
check_vpn_health() {
	# Layer 1: local state — deterministic, milliseconds, no network dependency
	if ! check_vpn_local_state; then
		echo "LOCAL_FAIL"
		return
	fi

	# Layer 2: parallel external probes — both run concurrently, max wait = one timeout
	local tmp_g tmp_i r_g r_i
	tmp_g=$(mktemp /tmp/surflare_hc.XXXXXX)
	tmp_i=$(mktemp /tmp/surflare_hc.XXXXXX)
	# Ensure temp files are removed even if this function is interrupted mid-wait.
	# Stored in a global so the main EXIT trap can also clean up on unclean exit.
	_hc_tmp="$tmp_g $tmp_i"

	# Google: blocked by GFW → 200/30x means VPN is working
	(
		code=$(curl -s --connect-timeout 3 --max-time 8 \
		       -o /dev/null -w '%{http_code}' https://www.google.com 2>/dev/null)
		case "$code" in 200|301|302) echo "OK" ;; esac
	) >"$tmp_g" 2>/dev/null &
	local pid_g=$!

	# ip-api.com: returns exit country code over HTTPS (avoids plain-HTTP MITM)
	(
		curl -s --connect-timeout 3 --max-time 8 \
		     'https://ip-api.com/line/?fields=countryCode' 2>/dev/null \
		| tr -d '[:space:]'
	) >"$tmp_i" 2>/dev/null &
	local pid_i=$!

	wait "$pid_g" "$pid_i"
	r_g=$(cat "$tmp_g" 2>/dev/null)
	r_i=$(cat "$tmp_i" 2>/dev/null)
	rm -f "$tmp_g" "$tmp_i"
	_hc_tmp=""

	# Google result takes priority (most reliable GFW indicator)
	[ "$r_g" = "OK" ] && echo "OK" && return
	# ip-api.com result (may be a country code, "CN", or empty)
	echo "$r_i"
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
# Security note: password is passed as a CLI argument (-p), visible in /proc/<pid>/cmdline
# for the duration of each attempt (~15s). Risk is limited because the daemon runs as root
# and Linux restricts /proc/<pid>/cmdline cross-process reads to same-UID by default.
# If surflare ever adds --password-stdin or SURFLARE_PASSWORD env-var support, prefer those.
refresh_auth() {
	local email="${SURFLARE_EMAIL:-}"
	local password=""

	# Read password from systemd credentials directory (TPM2-decrypted at runtime)
	if [ -n "$CREDENTIALS_DIRECTORY" ]; then
		if [ -f "$CREDENTIALS_DIRECTORY/surflare-password" ]; then
			password=$(cat "$CREDENTIALS_DIRECTORY/surflare-password")
		else
			log "Auth credential file not found: ${CREDENTIALS_DIRECTORY}/surflare-password — proactive refresh disabled"
			return 2  # no credentials: caller should back off for a full interval
		fi
	fi

	if [ -z "$email" ]; then
		log "Auth refresh skipped: SURFLARE_EMAIL not set"
		return 2  # no credentials: caller should back off for a full interval
	fi
	if [ -z "$password" ]; then
		log "Auth refresh skipped: no credentials configured (set CREDENTIALS_DIRECTORY or SURFLARE_EMAIL)"
		return 2  # no credentials: caller should back off for a full interval
	fi

	local i=0 rc=1
	while [ "$i" -lt "$LOGIN_RETRIES" ]; do
		if timeout 15 surflare login -u "$email" -p "$password" --remember >/dev/null 2>&1; then
			log "Auth token refreshed successfully (attempt $((i + 1))/${LOGIN_RETRIES})"
			rc=0
			break
		fi
		i=$((i + 1))
		[ "$i" -lt "$LOGIN_RETRIES" ] && sleep "$LOGIN_RETRY_DELAY"
	done
	# Clear password from shell memory immediately after use
	unset password
	if [ "$rc" -ne 0 ]; then
		log "Auth token refresh failed after ${LOGIN_RETRIES} attempts"
	fi
	return "$rc"
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
# storm_sleep_pid: background sleep PID during storm cooling — killed on SIGTERM
# _hc_tmp: health-check temp files — cleaned on SIGTERM in case wait is interrupted
storm_sleep_pid=""
_hc_tmp=""
trap 'log "watchdog stopped"; [ -n "$storm_sleep_pid" ] && kill "$storm_sleep_pid" 2>/dev/null; [ -n "$_hc_tmp" ] && rm -f $_hc_tmp; rm -f "$PIDFILE"; exit 0' INT TERM
trap '[ -n "$_hc_tmp" ] && rm -f $_hc_tmp; rm -f "$PIDFILE"' EXIT
echo $$ >"$PIDFILE"

fail_count=0
reconnect_count=0
transient_count=0
last_refresh=$(date +%s)
last_heartbeat=$(date +%s)
log "watchdog started: node=${NODE} interval=${CHECK_INTERVAL}s threshold=${FAIL_THRESHOLD} transient=${TRANSIENT_THRESHOLD}"

while true; do
	health=$(check_vpn_health)

	# ── Classify health result ──────────────────────────────────────────────
	if [ "$health" = "LOCAL_FAIL" ]; then
		# Local VPN state lost (process/nftables/routing gone) — definitive failure,
		# no network uncertainty. Skip accumulation and force reconnect immediately.
		log "Local VPN state lost (process/nftables/routing), triggering immediate reconnect"
		transient_count=0
		fail_count=$FAIL_THRESHOLD

	elif [ "$health" = "OK" ] || \
	     { [ "$health" != "CN" ] && [ "$health" != "LOCAL_FAIL" ] && [ -n "$health" ]; }; then
		# VPN healthy — Google 200/30x (GFW bypassed) OR ip-api.com returned non-CN country
		fail_count=0
		reconnect_count=0
		transient_count=0

		# Proactive token refresh — runs whenever VPN is confirmed healthy so tokens stay
		# fresh for reconnects. Covers both Google-OK and ip-api.com-fallback paths.
		now=$(date +%s)
		if [ $((now - last_refresh)) -ge "$TOKEN_REFRESH_INTERVAL" ]; then
			refresh_auth
			refresh_rc=$?
			if [ "$refresh_rc" -eq 0 ] || [ "$refresh_rc" -eq 2 ]; then
				# rc=0: success; rc=2: no credentials — both back off a full interval.
				# rc=1 (login failure) leaves last_refresh unchanged for prompt retry.
				last_refresh=$(date +%s)
			fi
		fi

		# Periodic heartbeat — confirms watchdog is alive during long healthy stretches
		if [ "${HEARTBEAT_INTERVAL:-0}" -gt 0 ] && [ $((now - last_heartbeat)) -ge "$HEARTBEAT_INTERVAL" ]; then
			log "VPN healthy: exit=${health}"
			last_heartbeat=$now
		fi

	elif [ "$health" = "CN" ]; then
		# External confirmed: traffic is exiting via China — VPN is routing incorrectly
		transient_count=0
		fail_count=$((fail_count + 1))
		log "Health check failed (CN exit), consecutive count: ${fail_count}"

	else
		# health="" — both external probes timed out; local state was OK (check_vpn_health
		# returns LOCAL_FAIL if local state is bad, so here local is confirmed healthy).
		# This is a transient network spike, not a definitive VPN failure.
		transient_count=$((transient_count + 1))
		log "Health check transient timeout (local state OK), transient ${transient_count}/${TRANSIENT_THRESHOLD}"
		if [ "$transient_count" -ge "$TRANSIENT_THRESHOLD" ]; then
			# Too many consecutive transients — escalate in case of silent L3 breakage
			fail_count=$((fail_count + 1))
			transient_count=0
			log "Transient threshold reached, escalating to fail_count: ${fail_count}"
		fi
	fi

	# ── Shared reconnect path ───────────────────────────────────────────────
	# Triggered by: LOCAL_FAIL (immediate), CN failure, or transient escalation
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
			if [ "$new_health" = "OK" ] || \
			   { [ "$new_health" != "CN" ] && [ "$new_health" != "LOCAL_FAIL" ] && [ -n "$new_health" ]; }; then
				fail_count=0
				reconnect_count=0
				transient_count=0
			else
				reconnect_count=$((reconnect_count + 1))
				log "Post-reconnect health check anomalous (reconnect_count=${reconnect_count})"
				if [ "$reconnect_count" -ge "$STORM_MAX" ]; then
					log "Storm protection triggered: cooling for ${STORM_COOLING}s"
					sleep "$STORM_COOLING" &
					storm_sleep_pid=$!
					wait "$storm_sleep_pid"
					storm_sleep_pid=""
					reconnect_count=0
					fail_count=0
					transient_count=0
				fi
			fi
		else
			reconnect_count=$((reconnect_count + 1))
			log "Reconnect attempt failed (reconnect_count=${reconnect_count})"
			if [ "$reconnect_count" -ge "$STORM_MAX" ]; then
				log "Storm protection triggered (connect failure): cooling for ${STORM_COOLING}s"
				sleep "$STORM_COOLING" &
				storm_sleep_pid=$!
				wait "$storm_sleep_pid"
				storm_sleep_pid=""
				reconnect_count=0
				fail_count=0
				transient_count=0
			fi
		fi
	fi

	# "sleep & wait" allows bash to handle SIGTERM immediately instead of
	# blocking until sleep finishes
	sleep "$CHECK_INTERVAL" &
	wait $!
done
