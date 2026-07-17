#!/bin/bash
# --source-only: define functions but do not enter main loop.
# Used by test harnesses to source this file without triggering
# root checks, dependency checks, or the main loop.
if [ "${1:-}" = "--source-only" ]; then
	_SOURCE_ONLY=1
fi

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
# View logs    : sudo dmesg | grep surflare_watchdog

NODE="Dallas"                          # Exit node (NA); transit/relay is auto
NODE_CANDIDATES=("Chicago" "Miami" "Atlanta" "San Juan" "Los Angeles" "Dallas" "New York")
# Connection mode: loaded from /etc/surflare/mode.conf if present,
# otherwise resolved from PLATFORM (router->rule, laptop->global).
# Deploying surflare_watchdog.sh no longer resets the mode setting.
#   router "rule": surflare-proxy Smart Routing (CN direct, non-CN VPN).
#   router "global": all LAN TCP via VPN (QUIC rejected at nft); cn_direct for CN bypass.
#   laptop "global": all traffic through VPN; cn_ipv4 kernel-level CN bypass.
MODE=""
if [ -f /etc/surflare/mode.conf ]; then
	# Safe parse: only accept MODE= assignments, reject arbitrary shell code.
	_conf_mode=$(grep -E "^[[:space:]]*MODE=" /etc/surflare/mode.conf 2>/dev/null | tail -1 | cut -d= -f2- | tr -d "\"'")
	[ -n "$_conf_mode" ] && MODE="$_conf_mode"
fi
TRANSIT="auto"                            # Transit server: "" = use TRANSIT_CANDIDATES (logged), "auto" = surflare picks (opaque)
TRANSIT_CANDIDATES=("Dallas" "Chicago" "Atlanta" "Miami" "New York")  # US-only; KR/HK/TW exits trigger Bing cn redirect
TRANSIT_CONNECT_TIMEOUT=12             # max seconds for surflare connect per candidate
TRANSIT_ROUTE_READY_TIMEOUT=15        # max seconds to poll for routing readiness after connect
TRANSIT_PROBE_SETTLE=20              # seconds of quiet time for tunnel handshake after routing ready
CHECK_INTERVAL=30                     # Exit IP check interval in seconds
DEGRADED_INTERVAL=10                  # Shortened interval when degraded (transient/fail > 0)
FAILBACK_THRESHOLD=3                  # Consecutive OK checks before leaving DEGRADED
FAIL_THRESHOLD=4                      # Consecutive failures before reconnect
FAIL_THRESHOLD_BASE=4                 # Base value for backoff reset
FAIL_THRESHOLD_MAX=16                 # Upper bound for adaptive backoff
LOCK_FILE=/run/surflare_watchdog.lock # Mutex lock to prevent concurrent reconnects
PIDFILE=/run/surflare_watchdog.pid    # PID file for reliable daemon shutdown
RESTART_MARKER=/run/surflare_watchdog.restart  # set by main loop before reconnect; cleanup checks it
ROTATION_STATE=/var/tmp/surflare_rotation  # Persists active node across restarts
DIAG_SACK_THRESHOLD=20                # % of packets with SACK blocks to flag transit degradation
DISCONNECT_SETTLE=1                   # seconds after surflare disconnect before killing processes
CONNECT_SETTLE=20                     # seconds after surflare connect --daemon for VPN to establish
DATAPLANE_SETTLE=60                       # max seconds to wait for data-plane ping after local state ready
LAST_REFRESH_FILE="/run/surflare_last_refresh"  # timestamp of last watchdog-initiated auth refresh (debug only)
NETWORK_WAIT_FALLBACK=15              # seconds to wait for network when nm-online is unavailable
NETWORK_WAIT_TIMEOUT=30               # nm-online timeout in seconds
PROCESS_EXIT_TIMEOUT=20               # seconds to wait for SIGTERM before escalating to SIGKILL
STORM_MAX=5                           # consecutive unconfirmed reconnects before cooling
STORM_COOLING=600                     # seconds to cool down after storm protection triggers
RECONNECT_RATE_WINDOW=600             # sliding window for rate limiter (seconds)
RECONNECT_RATE_MAX=3                  # max reconnects in window before cooldown
POST_RECONNECT_DNS_FLUSH=0           # 1=restart SmartDNS after reconnect to clear poisoned cache
                                      # Auth is reactive: binary manages JWT renewal (detour_refresh.go).
                                      # Watchdog calls refresh_auth only when surflare status
                                      # reports "not logged in" or "session expired".
LOGIN_RETRIES=5                       # max login attempts per refresh cycle
LOGIN_RETRY_DELAY=3                   # seconds between login retries
HEARTBEAT_INTERVAL=600                # seconds between periodic "VPN healthy" log entries (0=off)
DIAG_GRACE_PERIOD=180                 # seconds: medium-severity diagnosis alerts wait this long before firing (0=off)
SERVERCHAN_DAILY_CAP=3               # max Server Chan messages per day when bridge is down (0=unlimited)
STORM_503_STATE="/run/surflare_503_state"  # 503 monitor -> health check evidence channel
STORM_503_OVERRIDE_COUNT=10           # cumulative 503s to override Probe 7
STORM_503_OVERRIDE_WINDOW=300         # seconds; all 10 503s must be within this window
TPROXY_503_ROTATE_THRESHOLD=5         # tproxy 503 count in health window to trigger rotation
TPROXY_503_COOLDOWN=660                 # 600s health window + 60s margin for 2 cron refreshes (cron runs every 3 min)
TPROXY_NFT_STAMP="/run/surflare_tproxy_nft.stamp"  # md5 of /etc/surflare-lan-tproxy.nft at last _restore_tproxy
NODE_HEALTH_FILE="/var/run/surflare_node_health.json"
OBS_HEARTBEAT_EVERY=20                # log heartbeat every N observability probe runs (~10 min)
TRANSIENT_THRESHOLD=6                 # consecutive external timeouts (local state OK) before escalating to fail_count
AUTH_FAIL_THRESHOLD=3                 # consecutive auth refresh failures before forcing reconnect
BYPASS_LAN_DEVICES=""                 # space-separated LAN IPs that skip tproxy (e.g. "192.168.100.147 192.168.100.148")
# One MAC per line; current IP resolved from /tmp/dhcp.leases at connect time
BYPASS_LAN_MACS_FILE="/etc/surflare/bypass-macs.conf"
_DNS_RESTART_MAX=3                    # max SmartDNS restarts per window
_DNS_RESTART_WINDOW=600               # rate limiter window (seconds)
MIN_RELAY_CONNS=2                     # minimum connections to classify an IP as relay (vs DNS/proxied noise)
_diag_server_ips=""                   # space-separated VPN relay IPs (filtered by MIN_RELAY_CONNS)
_diag_connect_time=0                  # epoch seconds of last successful connect
_reconnect_window_start=0             # epoch when current rate window opened
_reconnect_window_count=0             # reconnects in current window
_sess_node=""                         # exit node of current VPN session
_sess_transit=""                      # transit node of current session
_sess_exit=""                         # exit country code of current session
_exit_country_blocked=0               # set by _record_connect when exit not in allowed set
_sess_connect_s=0                     # epoch of current session start
_sess_prev_node=""                    # previous session's exit node
_sess_prev_s=0                        # previous session's lifetime in seconds
_export_diag_pending=0                 # SIGUSR1 flag for deferred diag state export
_ADVISORY_DIAGNOSIS_RUNNING=0          # re-entrancy guard for _run_advisory_diagnosis
_diag_conclusion=""                   # set by _diagnose_tunnel_failure for _record_disconnect
_diag_out=0                           # physical capture outbound packet count
_obs_run_count=0                      # observability probe invocation counter (heartbeat)
_diag_in=0                            # physical capture inbound packet count
_diag_syn_out=0                       # SYN packets sent (new connection attempts)
_diag_syn_ack=0                       # SYN-ACK received (successful handshakes)
_diag_sack_pct=0                      # % of packets with SACK blocks
_diag_rst_in=0                        # RST packets received from server
_transit_grace_ts=0                   # epoch when SERVER_APP_FAILURE granted transit reprobe grace
TRANSIT_GRACE_TTL=300                 # seconds to honor transit grace before expiry (5 min)
EVENT_LOG="/var/log/surflare_events.jsonl"
# Auto-detect WiFi interface; fallback to wlp9s0f0 if iw is unavailable
WIFI_INTERFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
[ -z "$WIFI_INTERFACE" ] && WIFI_INTERFACE=""
CRASH_COOLDOWN=60                     # seconds to wait after detecting firmware crash before reconnect
CRASH_MAX_PER_WINDOW=3                # max crashes in CRASH_WINDOW before extended cooldown
CRASH_WINDOW=600                      # seconds window for crash rate limiting
CRASH_EXTENDED_COOLDOWN=300           # seconds extended cooldown after cascade detected
CRASH_DEDUP_INTERVAL=121              # minimum seconds between counting two crashes as distinct (must exceed detection window)

# ISP IP baseline for CN exit detection
# In smart routing mode, CN exit can mean two things:
# 1. Tunnel broken: traffic leaked direct -> exit IP == ISP IP -> real failure
# 2. Tunnel working but exit in CN: exit IP != ISP IP -> not a failure
ISP_IP=""                             # cached ISP public IP (set at startup)
ISP_IP_CACHE="/etc/surflare/isp_ip"   # persistent cache file
ISP_IP_MAX_AGE=86400                  # refresh ISP IP every 24 hours

# Platform detection: router (procd/OpenWrt) vs laptop (systemd)
if [ -f /etc/openwrt_release ]; then
	PLATFORM="router"
else
	PLATFORM="laptop"
fi

# Resolve MODE from PLATFORM (can be overridden by setting MODE above)
if [ -z "$MODE" ]; then
	case "$PLATFORM" in
		router) MODE="rule" ;;
		*)      MODE="global" ;;
	esac
fi

# Validate NODE is configured (fail fast if placeholder is unchanged)
if [ "$NODE" = "your_node_tag" ]; then
	echo '<3>surflare_watchdog: NODE is not configured. Edit NODE= in the script first.' >/dev/kmsg
	echo "NODE is not configured. Edit NODE= in the script first." >&2
	exit 1
fi

# Must run as root (avoids sudo ticket expiry blocking in background)
if [ "${_SOURCE_ONLY:-0}" -ne 1 ] && [ "$EUID" -ne 0 ]; then
	echo "Must run as root: sudo $0" >&2
	exit 1
fi

umask 0177
# Restrict new file permissions to 600 (root-only) -- prevents non-root users from
# opening the lock file for reading and holding flock to block reconnects

# Skip dependency checks and system initialization when sourcing for tests.
if [ "${_SOURCE_ONLY:-0}" -eq 1 ]; then
	# Define minimal log() for test context (no /dev/kmsg)
	log() { echo "surflare_watchdog: $*" >&2; }
else

# Dependency check
# Package reference (if missing, install the corresponding package):
#   curl          -> curl         (all major distros)
#   killall       -> psmisc       (all major distros)
#   pgrep         -> procps-ng / procps
#   flock         -> util-linux   (all major distros)
#   surflare/surflare-proxy -> from surflare installation
# Note: nm-online is optional (NetworkManager package); falls back to sleep 15s.
for cmd in curl killall pgrep flock surflare surflare-proxy python3 ss; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "<3>surflare_watchdog: missing dependency: ${cmd}, exiting" >/dev/kmsg
		exit 1
	fi
done

# Singleton enforcement: prevent multiple watchdog instances.
# Each instance independently sends alerts and modifies nftables,
# so duplicates cause alert amplification and state conflicts.
# Placed immediately after dependency check (flock verified) and
# before any other init code, so duplicate instances exit before
# producing log noise (nm-online warning, etc.).
exec 9>/run/surflare_watchdog.singleton.lock
if ! flock -n 9; then
	echo "<3>surflare_watchdog: another instance is running, exiting" >/dev/kmsg 2>/dev/null
	exit 1
fi

# expect is only needed for interactive password auth (CREDENTIALS_DIRECTORY path).
# Router deployments use token-based auth and rarely have expect installed.
# refresh_auth() guards its own expect usage with command -v at call time.

if ! command -v nm-online >/dev/null 2>&1; then
	echo '<4>surflare_watchdog: nm-online not found, will use fixed sleep on resume' >/dev/kmsg
fi

log() {
	# Use echo, not printf: bash 5.2.37 printf builtin writes char-by-char
	# to /dev/kmsg under procd (OpenWrt), causing printk ratelimit floods.
	# echo builtin does a single write() and works correctly.
	echo "<6>surflare_watchdog: $*" >/dev/kmsg
}

fi  # end of _SOURCE_ONLY guard (skip dependency checks and system init)

# _proc_alive: returns 0 if any process has /proc/<pid>/comm == _name.
# Replaces pgrep -f / pgrep -x which are unreliable on busybox (known
# -x bug) and pattern-based matching which false-positives on log files
# and monitoring scripts (e.g. "tail -f /var/log/surflare/surflare-proxy.log").
# /proc/<pid>/comm is the kernel's authoritative executable name
# (truncated to 15 chars), set by the kernel at exec time, and cannot
# be spoofed by argv manipulation. Both busybox and GNU ps honor it.
# Avoid procps-ng-pgrep because it overwrites busybox
# pgrep and may break native OpenWrt init scripts.
_proc_alive() {
	local _name="${1:0:15}"  # /proc/pid/comm truncates to 15 chars
	local _pid _comm
	for _pid in /proc/[0-9]*; do
		[ -r "$_pid/comm" ] || continue
		_comm=$(cat "$_pid/comm" 2>/dev/null) || continue
		# Prefix match: /proc/pid/comm truncates to 15 chars.
		# "surflare-proxy.real" -> comm="surflare-proxy."
		# "surflare-proxy"       -> comm="surflare-proxy"
		# The dot-suffix pattern catches truncated variants (.real,
		# .orig, .bak) without matching unrelated programs
		# (surflare-proxy2 or surflare-proxy-debug).
		case "$_comm" in
			"$_name"|"$_name."*) return 0 ;;
		esac
	done
	return 1
}

# _pid_by_comm: returns PIDs of all processes with comm == _name,
# one per line. Used where the caller needs a specific PID (e.g. signal
# routing, /proc/<pid>/inspection). Same comm-based identity as
# _proc_alive so behavior is consistent.
_pids_by_comm() {
	local _name="${1:0:15}"  # /proc/pid/comm truncates to 15 chars
	local _pid _comm
	# Guard: if no numeric entries, glob is literal
	[ -d /proc/1 ] || return 0
	for _pid in /proc/[0-9]*; do
		[ -r "$_pid/comm" ] || continue
		_comm=$(cat "$_pid/comm" 2>/dev/null) || continue
		case "$_comm" in
			"$_name"|"$_name."*) echo "${_pid##*/}" ;;
		esac
	done
}

# check_vpn_local_state: fast local-only check -- no network calls.
# Returns 0 if all local VPN indicators are present, 1 if any is missing.
# Indicators: surflare-proxy process + listening socket on 10800 + nftables
# table (inet surflare -- created by surflare binary, not watchdog's inet
# killswitch; absent when VPN is down, appears after connect --daemon)
# + fwmark policy routing rule.  A LOCAL_FAIL means the VPN is
# definitively down (not a transient network timeout).
# Listening socket check: with process + table + rule present but the
# proxy not listening on :10800, LAN tproxy TCP black-holes for up to
# CHECK_INTERVAL before LOCAL_FAIL fires.
check_vpn_local_state() {
	_proc_alive surflare-proxy >/dev/null 2>&1 || return 1
	ss -ltn 2>/dev/null | grep -qE ':10800(\s|$)' || return 1
	nft list table inet surflare >/dev/null 2>&1 || return 1
	ip rule show | grep -q 'fwmark 0x1 lookup 100' || return 1
	return 0
}

# Alert bridge globals: X500 bridge (LAN, fast) is primary; Server Chan (WAN) is fallback.
_ALERT_BRIDGE_URL="http://192.168.100.10:8377/alert"
_ALERT_BRIDGE_TIMEOUT=5
_ALERT_BRIDGE_TOKEN_FILE="/root/.surflare-bridge-token"

# _deliver_alert: send notification via X500 bridge first, Server Chan fallback.
# No rate limiting, no backgrounding -- caller decides both.
# Called by _send_alert (rate-limited, backgrounded) and _send_diagnosis_alert
# follow-up (no rate limit, already in background subshell).
_deliver_alert() {
	local _title="${1:-surflare alert}"
	local _body="${2:-}"
	local _conf="/etc/surflare/wechat.conf"
	local _sendkey

	local _j_title _j_body _bridge_rc _bridge_token
	_j_title=$(printf '%s' "$_title" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\t\n' ' ')
	_j_body=$(printf '%s' "$_body" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\t\n' ' ')

	_bridge_token=""
	[ -f "$_ALERT_BRIDGE_TOKEN_FILE" ] && \
		_bridge_token=$(cat "$_ALERT_BRIDGE_TOKEN_FILE" | tr -d '\r\n')

	_bridge_rc=0
	if [ -n "$_bridge_token" ]; then
		curl -sf --max-time "$_ALERT_BRIDGE_TIMEOUT" \
			-X POST "$_ALERT_BRIDGE_URL" \
			-H 'Content-Type: application/json' \
			-H "X-Bridge-Token: ${_bridge_token}" \
			-d "{\"title\":\"${_j_title}\",\"body\":\"${_j_body}\"}" \
			>/dev/null 2>&1 || _bridge_rc=$?
	else
		log "WARN: bridge token missing, skipping bridge"
		_bridge_rc=1
	fi

	if [ "$_bridge_rc" -eq 0 ]; then
		log "Alert sent via bridge: ${_title}"
		return 0
	fi

	# Server Chan fallback (WAN, CN direct) with daily cap.
	# Prevents quota exhaustion when bridge is down for extended periods.
	[ -f "$_conf" ] || { log "WARN: alert skipped, bridge failed + $_conf not found"; return 1; }
	_sendkey=$(grep -m1 '^SENDKEY=' "$_conf" | cut -d= -f2- | tr -d '"\r ')
	[ -n "$_sendkey" ] || { log "WARN: alert skipped, bridge failed + SENDKEY empty"; return 1; }

	local _sc_cap="${SERVERCHAN_DAILY_CAP:-3}"
	local _sc_file="/run/surflare_serverchan_count"
	local _sc_count=0 _sc_date="" _sc_today
	_sc_today=$(date +%Y-%m-%d)
	if [ -f "$_sc_file" ]; then
		read -r _sc_count _sc_date < "$_sc_file" 2>/dev/null || { _sc_count=0; _sc_date=""; }
	fi
	[ "$_sc_date" != "$_sc_today" ] && _sc_count=0
	if [ "${_sc_cap:-0}" -gt 0 ] 2>/dev/null && [ "$_sc_count" -ge "$_sc_cap" ]; then
		log "WARN: Server Chan daily cap reached (${_sc_count}/${_sc_cap}), skipping: ${_title}"
		return 1
	fi

	if curl -sSf --noproxy '*' \
		--max-time 10 \
		--data-urlencode "title=${_title}" \
		--data-urlencode "desp=${_body}" \
		"https://sctapi.ftqq.com/${_sendkey}.send" \
		>/dev/null 2>&1; then
		_sc_count=$((_sc_count + 1))
		echo "$_sc_count $_sc_today" > "$_sc_file" 2>/dev/null
		log "Alert sent via Server Chan (bridge fallback, ${_sc_count}/${_sc_cap} today): ${_title}"
		return 0
	else
		log "WARN: alert delivery failed (bridge + Server Chan): ${_title}"
		return 1
	fi
}

# _send_alert: rate-limited wrapper around _deliver_alert.
# Rate limit: max 1 alert per 10 minutes (600s). Backgrounded to avoid
# blocking the reconnect path. VPN-down safe: bridge is LAN (no VPN
# needed); sctapi.ftqq.com is CN domestic.
_send_alert() {
	local _title="${1:-surflare alert}"
	local _body="${2:-}"

	local _now _last
	_now=$(date +%s)
	_last=${_alert_last_ts:-0}
	local _diff=$((_now - _last))
	if [ "$_diff" -ge 0 ] && [ "$_diff" -lt 600 ]; then
		log "Alert rate-limited (${_diff}s since last, need 600s): ${_title}"
		return 0
	fi
	_alert_last_ts=$_now

	( _deliver_alert "$_title" "$_body" ) 9>&- 200>&- &
}

# Ecosystem health probes: DNS, tmpfs, crond, memory/OOM, BPF.
# Called once per main loop iteration after health classify.
# All variables local EXCEPT _DNS_RESTART_TIMES (global, persists
# across calls for rate limiting).
_run_observability_probes() {
	local _obs_start=$SECONDS
	local _dns_restarted=0
	local _new_times _t _count _now_dns
	local _tmpfs_pct
	local _mem _pid
	local _bp_count
	local _fd_count _fd_limit _fd_pct _ct_count _ct_max _ct_pct

	# Probe 1 -- DNS liveness (router-only)
	if [ "$PLATFORM" = "router" ]; then
		# Step A -- SmartDNS
		if ! _proc_alive smartdns && ! pgrep -f '/usr/local/lib/smartdns/smartdns' >/dev/null 2>&1; then
			_now_dns=$(date +%s)
			_new_times=""
			for _t in $_DNS_RESTART_TIMES; do
				[ $((_now_dns - _t)) -lt "$_DNS_RESTART_WINDOW" ] && \
					_new_times="$_new_times $_t"
			done
			_DNS_RESTART_TIMES="$_new_times"
			_count=$(echo "$_DNS_RESTART_TIMES" | wc -w)
			if [ "$_count" -lt "$_DNS_RESTART_MAX" ]; then
				/etc/init.d/smartdns restart
				_dns_restarted=1
				log "SmartDNS was dead, restarted"
			else
				log "SmartDNS dead but restart rate-limited ($_count/$_DNS_RESTART_MAX in ${_DNS_RESTART_WINDOW}s)"
			fi
		fi
		# Step B -- dnsmasq (independent of SmartDNS)
		if ! _proc_alive dnsmasq; then
			/etc/init.d/dnsmasq restart
			log "dnsmasq was dead, restart attempted"
		elif [ "$_dns_restarted" = 1 ]; then
			killall -HUP dnsmasq 2>/dev/null
		fi
		# Step C -- verify (only after SmartDNS restart)
		if [ "$_dns_restarted" = 1 ]; then
			if timeout 10 nslookup baidu.com 127.0.0.1 >/dev/null 2>&1; then
				_DNS_RESTART_TIMES="$_DNS_RESTART_TIMES $(date +%s)"
				log "DNS restart verified (nslookup OK)"
			else
				log "DNS restart failed verification (nslookup failed)"
			fi
		fi
	fi

	# Probe 2 -- tmpfs usage
	_tmpfs_pct=$(df -P /tmp | awk 'NR==2 {print $5}' | tr -d '%')
	if [ "${_tmpfs_pct:-0}" -ge 70 ]; then
		log "CRITICAL: tmpfs usage at ${_tmpfs_pct}%"
	elif [ "${_tmpfs_pct:-0}" -ge 50 ]; then
		log "WARN: tmpfs usage at ${_tmpfs_pct}%"
	fi

	# Probe 3 -- crond
	_proc_alive crond || log "WARN: crond not running"

	# Probe 4 -- memory + OOM protection (every cycle, idempotent)
	_mem=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
	[ "${_mem:-0}" -lt 500000 ] && log "WARN: low memory: ${_mem}kB available"
	_pid=$(_pids_by_comm "surflare-proxy" | tail -1)
	[ -n "$_pid" ] && echo -1000 > "/proc/$_pid/oom_score_adj" 2>/dev/null

	# Probe 5 -- BPF keepalive (router-only)
	if [ "$PLATFORM" = "router" ]; then
		_bp_count=$(timeout 3 bpftool prog show 2>/dev/null | grep -c "loaded_at" || echo 0)
		if [ "${_bp_count:-0}" -eq 0 ] && [ "$SECONDS" -gt 60 ]; then
			log "WARN: BPF: no programs loaded"
		fi
	fi

	# Probe 6 -- proxy fd count (fd leak early warning)
	if [ -n "$_pid" ]; then
		# shellcheck disable=SC2012  # ls is correct for counting /proc/PID/fd entries
		_fd_count=$(ls "/proc/$_pid/fd" 2>/dev/null | wc -l)
		_fd_limit=$(awk '/Max open files/{print $4}' "/proc/$_pid/limits" 2>/dev/null)
		_fd_limit=${_fd_limit:-65535}
		if [ "$_fd_limit" -gt 0 ] 2>/dev/null; then
			_fd_pct=$((_fd_count * 100 / _fd_limit))
			if [ "$_fd_pct" -ge 80 ]; then
				log "CRITICAL: proxy fd usage ${_fd_pct}% (${_fd_count}/${_fd_limit})"
			elif [ "$_fd_pct" -ge 50 ]; then
				log "WARN: proxy fd usage ${_fd_pct}% (${_fd_count}/${_fd_limit})"
			fi
		fi
	fi

	# Probe 7 -- nftables table existence + conntrack (router-only)
	if [ "$PLATFORM" = "router" ]; then
		nft list table inet sw_lan_tproxy >/dev/null 2>&1 || \
			log "WARN: sw_lan_tproxy table missing (LAN clients lose VPN)"
		nft list table inet killswitch >/dev/null 2>&1 || \
			log "WARN: killswitch table missing"
		nft list table inet surflare_moat >/dev/null 2>&1 || \
			log "WARN: surflare_moat table missing"
		_ct_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
		_ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
		if [ "${_ct_max:-0}" -gt 0 ] 2>/dev/null && [ -n "$_ct_count" ]; then
			_ct_pct=$((_ct_count * 100 / _ct_max))
			if [ "$_ct_pct" -ge 80 ]; then
				log "CRITICAL: conntrack usage ${_ct_pct}% (${_ct_count}/${_ct_max})"
			elif [ "$_ct_pct" -ge 50 ]; then
				log "WARN: conntrack usage ${_ct_pct}% (${_ct_count}/${_ct_max})"
			fi
		fi
	fi

	# Timing guard (logging-only)
	if [ $(( SECONDS - _obs_start )) -gt 5 ]; then
		log "WARN: observability probes took $(( SECONDS - _obs_start ))s (>5s budget)"
	fi

	# Heartbeat: confirm probes are running (silent probes are indistinguishable
	# from dead probes).  Log every OBS_HEARTBEAT_EVERY invocations.
	_obs_run_count=$((_obs_run_count + 1))
	if [ $((_obs_run_count % OBS_HEARTBEAT_EVERY)) -eq 0 ]; then
		log "OBS probes OK (${_obs_run_count} runs)"
	fi
}

# --- Proxy log monitor: forward critical errors to dmesg/kmsg ---
# surflare-proxy writes errors to PROXY_LOG but they don't appear in
# dmesg.  This monitor tails the log and forwards ERROR lines to
# logger (which writes to kmsg), rate-limited to PROXY_LOG_RATE_SEC.
_proxy_log_pid=""
PROXY_LOG="/var/log/surflare/surflare-proxy.log"
PROXY_LOG_RATE_SEC=60
PROXY_ERR_STATE="/run/surflare_proxy_err_count"
PROXY_ERR_THRESHOLD=10  # higher than 503's 5: general errors are noisier

_start_proxy_log_monitor() {
	_stop_proxy_log_monitor
	[ -f "$PROXY_LOG" ] || return 0
	# Background: tail new lines, forward ERRORs to logger.
	# Rate-limited: after forwarding one ERROR, sleep before the next.
	# urltest: sing-box subscription auto-rotation (picks best node); NOT watchdog deploy count
	# urltest 503: accumulate count + timestamps into STORM_503_STATE
	# (ADR-0001 evidence channel).  USR1 fires at every 5th 503 to
	# wake the main loop.  Count does NOT reset -- accumulates until
	# monitor restart (reconnect) clears the state file.
	# $$ in a subshell = parent script PID (bash).
	(   _503_count=0
	    _503_first=0
	    _err_count=0
	    tail -n 0 -F "$PROXY_LOG" 2>/dev/null | while IFS= read -r _line; do
			echo "$_line" | grep -q 'ERROR' || continue
			if echo "$_line" | grep -q 'urltest.*503'; then
				_503_count=$((_503_count + 1))
				_now=$(date +%s)
				[ "$_503_first" -eq 0 ] && _503_first=$_now
				echo "$_503_count $_503_first $_now" \
					> "${STORM_503_STATE}.tmp" && \
					mv "${STORM_503_STATE}.tmp" "$STORM_503_STATE" 2>/dev/null
				if [ $((_503_count % 5)) -eq 0 ]; then
					logger -t surflare-proxy \
						"503 storm: ${_503_count} urltest 503 since ${_503_first}, requesting health check"
					kill -USR1 $$ 2>/dev/null || true
				fi
				continue
			elif echo "$_line" | grep -qi "authentication required"; then
				if [ ! -f /run/surflare_auth_expired ]; then
					touch /run/surflare_auth_expired
					kill -USR1 $$ 2>/dev/null || true
				fi
				continue
			fi
			# Count all remaining ERROR lines (not 503/auth)
			_err_count=$((_err_count + 1))
			echo "$_err_count $(date +%s)" > "${PROXY_ERR_STATE}.tmp" && \
				mv "${PROXY_ERR_STATE}.tmp" "$PROXY_ERR_STATE" 2>/dev/null
			if [ $((_err_count % PROXY_ERR_THRESHOLD)) -eq 0 ]; then
				kill -USR1 $$ 2>/dev/null || true
			fi
			logger -t surflare-proxy "$_line"
			sleep "$PROXY_LOG_RATE_SEC"
		done
	) 9>&- 200>&- &
	_proxy_log_pid=$!
}

_stop_proxy_log_monitor() {
	if [ -n "${_proxy_log_pid:-}" ]; then
		kill "$_proxy_log_pid" 2>/dev/null
		wait "$_proxy_log_pid" 2>/dev/null
		_proxy_log_pid=""
	fi
	pkill -f "tail -n 0 -F ${PROXY_LOG//./\\.}" 2>/dev/null || true
	rm -f "$STORM_503_STATE" "${STORM_503_STATE}.tmp"
	rm -f "$PROXY_ERR_STATE" "${PROXY_ERR_STATE}.tmp"
}

PROXY_CPU_SET=""
DESKTOP_CPU_SET=""

_dns_fallback_active=0
_dns_fallback_gw=""
DNS_STUCK_FILE="/run/surflare_dns_stuck"

_cleanup_dns_fallback_rules() {
	local gw="${1:-}"
	[ -z "$gw" ] && return 0
	# Validate IP format (defense-in-depth: callers already validate)
	if ! [[ "$gw" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		return 0
	fi
	local h removed=0
	for h in $(nft -a list chain inet surflare output 2>/dev/null \
		| grep -E "ip daddr ${gw//./\\.} (tcp|udp) dport 53 accept" | awk '/handle /{print $NF}'); do
		if ! nft delete rule inet surflare output handle "$h" 2>/dev/null; then
			log "DNS fallback: WARN: failed to delete handle ${h}"
		fi
		removed=$((removed + 1))
	done
	return 0
}

_insert_dns_fallback() {
	local gw handle
	gw=$(ip route show default | awk '/default/{print $3; exit}')
	[ -z "$gw" ] && return 0
	if [[ "$gw" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
		[ "${BASH_REMATCH[1]}" -le 255 ] && [ "${BASH_REMATCH[2]}" -le 255 ] && 		[ "${BASH_REMATCH[3]}" -le 255 ] && [ "${BASH_REMATCH[4]}" -le 255 ] || return 0
	else
		return 0
	fi
	if [ "$_dns_fallback_active" -eq 1 ]; then
		if nft -a list chain inet surflare output 2>/dev/null \
			| grep -qE "ip daddr ${gw//./\\.} (tcp|udp) dport 53 accept"; then
			return 0
		fi
		_dns_fallback_active=0
	fi
	_cleanup_dns_fallback_rules "$gw"
	handle=$(nft -a list chain inet surflare output 2>/dev/null \
		| grep 'dport 53 meta mark set' | head -1 | awk '/handle /{print $NF}')
	if [ -z "$handle" ]; then
		log "DNS fallback: WARN: no dport 53 mark rule found in inet surflare"
		return 0
	fi
	if nft insert rule inet surflare output position "$handle" ip daddr "$gw" udp dport 53 accept 2>/dev/null &&
	   nft insert rule inet surflare output position "$handle" ip daddr "$gw" tcp dport 53 accept 2>/dev/null; then
		_dns_fallback_active=1
		_dns_fallback_gw="$gw"
		log "DNS fallback: exempted gateway ${gw}:53 from tproxy"
	else
		_cleanup_dns_fallback_rules "$gw"
		log "DNS fallback: WARN: nft insert failed, cleaned partial rules"
	fi
}

_remove_dns_fallback() {
	[ "$_dns_fallback_active" -eq 0 ] && return 0
	local gw="${_dns_fallback_gw:-}"
	[ -z "$gw" ] && gw=$(ip route show default | awk '/default/{print $3; exit}')
	[ -z "$gw" ] && return 0
	_cleanup_dns_fallback_rules "$gw"
	_dns_fallback_active=0
	_dns_fallback_gw=""
	log "DNS fallback: restored tunnel DNS"
}

_startup_cleanup_dns_fallback() {
	local gw
	gw=$(ip route show default | awk '/default/{print $3; exit}')
	[ -z "$gw" ] && return 0
	_cleanup_dns_fallback_rules "$gw"
	_dns_fallback_active=0
	_dns_fallback_gw=""
	rm -f "$DNS_STUCK_FILE"
}

# surflare drops all ICMP/ICMPv6 in output to prevent tunnel leaks.
# That kills LAN RA/DHCPv6/PMTUD -- insert LAN bypass before the drop.
# Must re-run after every connect since surflare recreates its table.
_patch_surflare_icmp_lan() {
	nft list table inet surflare >/dev/null 2>&1 || return 0
	# already patched
	if nft -a list chain inet surflare output 2>/dev/null \
		| grep -q 'oifname "br-lan" ip6 nexthdr ipv6-icmp accept'; then
		return 0
	fi
	local handle
	handle=$(nft -a list chain inet surflare output 2>/dev/null \
		| grep 'ip protocol icmp drop' | awk '/handle /{print $NF}' | head -1)
	[ -z "$handle" ] && { log "WARN: ICMP LAN bypass: icmp drop rule not found in inet surflare output"; return 0; }
	# inserts stack in reverse at same position: final order is
	# br-lan-icmpv6, br-lan-icmp, ff00/8, fe80/10, then the drop
	nft insert rule inet surflare output position "$handle" \
		ip6 daddr fe80::/10 accept 2>/dev/null || true
	nft insert rule inet surflare output position "$handle" \
		ip6 daddr ff00::/8 accept 2>/dev/null || true
	nft insert rule inet surflare output position "$handle" \
		oifname "br-lan" ip protocol icmp accept 2>/dev/null || true
	nft insert rule inet surflare output position "$handle" \
		oifname "br-lan" ip6 nexthdr ipv6-icmp accept 2>/dev/null || true
	log "Surflare ICMP LAN bypass: inserted before drop (handle ${handle})"
}

_cleanup_surflare_icmp_lan() {
	nft list table inet surflare >/dev/null 2>&1 || return 0
	local h
	local pat
	for pat in 'oifname "br-lan" ip6 nexthdr ipv6-icmp accept' \
		'oifname "br-lan" ip protocol icmp accept' \
		'ip6 daddr ff00::/8 accept' \
		'ip6 daddr fe80::/10 accept'; do
		h=$(nft -a list chain inet surflare output 2>/dev/null \
			| grep -F "$pat" | awk '/handle /{print $NF}' | head -1)
		[ -n "$h" ] && nft delete rule inet surflare output handle "$h" 2>/dev/null
	done
}

_setup_kernel_moat() {
	if ! command -v nft >/dev/null 2>&1; then
		return 0
	fi
	# Upstream filter injects spoofed TCP FIN+ACK and RST packets to tear
	# down tunnelled connections. Priority -300 drops them before conntrack.
	#
	# F9: hard-drop of injected packets is gated on
	# /run/surflare_watchdog.moat_strict.  Absent = counter + log only.
	# This lets us measure observed injection rates over 48h before
	# deciding whether to enforce the drop in production.
	nft add table inet surflare_moat 2>/dev/null || true
	nft flush table inet surflare_moat 2>/dev/null || true
	# Clean up removed output chain (was 0xff DNS redirect, caused tproxy loop).
	nft delete chain inet surflare_moat output 2>/dev/null || true
	if ! nft add chain inet surflare_moat prerouting '{ type filter hook prerouting priority -300; policy accept; }' 2>/dev/null; then
		log "WARN: Kernel moat chain creation failed"
		return 1
	fi
	local moat_set_ok=1
	local moat_rules_ok=1
	local _moat_action='counter log prefix "moat: "'
	# moat_strict presence switches from counter-only to hard drop.
	if [ -f /run/surflare_watchdog.moat_strict ]; then
		_moat_action='drop'
	fi
	# Narrow window signature set: upstream filter has been observed
	# using 32, 64, 78, 128.  A range (1-128) is rejected by some
	# nftables versions and over-matches legitimate small-window
	# connections (interactive SSH, some games).
	if ! nft add set inet surflare_moat win_sizes \
		'{ type inet_service; flags interval; elements = { 32, 64, 78, 128 } }' 2>/dev/null; then
		# Older nft may not support nested set in element syntax; fall
		# back to explicit per-window rules.  This is wider than the
		# set-based version but still bounded to observed signatures.
		# Set failure is NOT a hard failure -- the per-window fallback
		# rules below still cover the observed signature set.
		moat_set_ok=0
	fi
	# "flags & fin == fin" matches both pure FIN [F] and FIN+ACK [F.] --
	# upstream filter sends [F.].  iifname != "br-lan" restricts to
	# WAN-originated packets so LAN devices' normal connection closures
	# (which also have window=78 on iOS/macOS) are not false-positived.
	# shellcheck disable=SC2086
	nft add rule inet surflare_moat prerouting \
		iifname != "br-lan" tcp flags \& fin == fin tcp window @win_sizes ${_moat_action} 2>/dev/null || \
		nft add rule inet surflare_moat prerouting \
			iifname != "br-lan" tcp flags \& fin == fin tcp window 78 ${_moat_action} 2>/dev/null || \
		nft add rule inet surflare_moat prerouting \
			iifname != "br-lan" tcp flags \& fin == fin ${_moat_action} 2>/dev/null || moat_rules_ok=0
	# RST injection
	# shellcheck disable=SC2086
	nft add rule inet surflare_moat prerouting \
		iifname != "br-lan" tcp flags \& rst == rst tcp window @win_sizes ${_moat_action} 2>/dev/null || \
		nft add rule inet surflare_moat prerouting \
			iifname != "br-lan" tcp flags \& rst == rst tcp window 78 ${_moat_action} 2>/dev/null || \
		nft add rule inet surflare_moat prerouting \
			iifname != "br-lan" tcp flags \& rst == rst ${_moat_action} 2>/dev/null || moat_rules_ok=0
	# F9: explicitly allow ICMPv6 packet-too-big so PMTUD continues to
	# work even when other ICMPv6 unreachables are being filtered.
	# Without this, IPv6 connections that need to discover a smaller
	# MTU hang indefinitely.
	nft add rule inet surflare_moat prerouting \
		ip6 nexthdr icmpv6 icmpv6 type packet-too-big accept 2>/dev/null || moat_rules_ok=0
	# GFW RST injection defense: drop ALL incoming RST on WAN.
	# GFW spoofs VPN server IPs and sends duplicate RSTs (2-3 copies,
	# identical seq, microseconds apart) to kill VPN tunnels. Legitimate
	# servers close via FIN; RST is abnormal and safely dropped on WAN.
	# sing-box detects dead connections via its own 5s timeout, so
	# dropping RST only delays failure detection by at most 5s.
	# Placed in prerouting (priority -300, before conntrack) so RSTs
	# are dropped before the TCP stack honors them.
	nft add rule inet surflare_moat prerouting \
		iifname != "br-lan" tcp flags \& rst == rst drop 2>/dev/null || moat_rules_ok=0
	# NOTE: moat output chain (0xff DNS -> 0x1) REMOVED.
	# surflare-proxy uses SO_MARK=0xff for ALL outbound including its
	# own DNS (DoT to 223.5.5.5/120.53.53.53:853, DoH to 223.6.6.6:443).
	# Redirecting 0xff+{53,853} -> 0x1 routes those queries through
	# tproxy (ip rule fwmark 0x1 -> lo) back to surflare-proxy's own
	# :10800 listener, where sing-box detects self-loop and rejects.
	# surflare-proxy's direct DNS is intentional -- it needs to resolve
	# relay nodes.  DNS leak protection belongs at the resolver layer
	# (SmartDNS routes domestic direct, foreign via VPN), not at the
	# nftables mark level for the proxy's own traffic.
	if [ "$moat_rules_ok" -eq 1 ]; then
		local _mode_desc
		if [ -f /run/surflare_watchdog.moat_strict ]; then
			_mode_desc="dropping injected FIN/RST (strict mode)"
		else
			_mode_desc="counter+log only (touch /run/surflare_watchdog.moat_strict to enable drop)"
		fi
		if [ "$moat_set_ok" -eq 1 ]; then
			log "Kernel moat deployed: interval-set rules (windows 32/64/78/128) -- ${_mode_desc}"
		else
			log "Kernel moat deployed: hardcoded fallback rules (window 78 only, set creation failed) -- ${_mode_desc}"
		fi
	else
		log "WARN: moat rules failed to load; moat is INACTIVE"
	fi
}

_setup_chnroute() {
	# Populates CN bypass CIDRs into killswitch bypass_ipv4/bypass_ipv6
	# (both modes) and surflare output chain cn_ipv4/cn_ipv6 accept rules
	# (global mode only -- rule mode delegates CN split to surflare-proxy).
	local cn_v4_file="/etc/surflare/cn_ipv4.txt"
	local cn_v6_file="/etc/surflare/cn_ipv6.txt"
	mkdir -p /etc/surflare 2>/dev/null || true
	local baseline_dir="/usr/local/share/surflare/routes"
	if [ ! -f "$cn_v4_file" ] && [ -f "$baseline_dir/cn_ipv4.txt" ]; then
		log "WARN: /etc/surflare/cn_ipv4.txt missing, loading built-in baseline"
		cp "$baseline_dir/cn_ipv4.txt" "$cn_v4_file" 2>/dev/null || true
	fi
	if [ ! -f "$cn_v6_file" ] && [ -f "$baseline_dir/cn_ipv6.txt" ]; then
		log "WARN: /etc/surflare/cn_ipv6.txt missing, loading built-in baseline"
		cp "$baseline_dir/cn_ipv6.txt" "$cn_v6_file" 2>/dev/null || true
	fi

	# Global mode needs inet surflare table for the output chain cn_ipv4 rule.
	# Rule mode skips the surflare output chain (app-layer handles CN split),
	# but still needs killswitch bypass_ipv4 populated.
	local _surflare_table_ready=0
	if nft list table inet surflare >/dev/null 2>&1; then
		_surflare_table_ready=1
	fi
	if [ "$MODE" = "global" ] && [ "$_surflare_table_ready" -eq 0 ]; then
		log "WARN: inet surflare table not ready, skipping output-chain CN bypass"
		# Do NOT return: killswitch bypass_ipv4 can still be populated
		# even when surflare table is absent.  Fall through.
	fi
	# Either mode: killswitch table is required for bypass_ipv4 population.
	if ! nft list table inet killswitch >/dev/null 2>&1; then
		log "WARN: killswitch table not ready, skipping CN bypass"
		return 1
	fi

	local bypass_applied=0
	local cn_v4_extra_file="/etc/surflare/cn_ipv4_extra.txt"

	# --- surflare output chain (global mode only) ---
	# Kernel-level CN bypass for the router's own processes.  Each protocol
	# has its own retry loop because the surflare table may still be loading.
	if [ "$MODE" = "global" ] && [ "$_surflare_table_ready" -eq 1 ]; then
		if [ -f "$cn_v4_file" ]; then
			local cn_count cn_date
			cn_count=$(grep -vc '^#' "$cn_v4_file" 2>/dev/null || echo 0)
			cn_date=$(stat -c '%y' "$cn_v4_file" 2>/dev/null | cut -d' ' -f1)
			log "Applying Chnroute v4 to surflare output: ${cn_count} prefixes (${cn_date})"

			nft add set inet surflare cn_ipv4 '{ type ipv4_addr; flags interval; }' 2>/dev/null || true
			nft flush set inet surflare cn_ipv4 2>/dev/null || true

			local tmp_nft
tmp_nft=$(mktemp /tmp/cn_ipv4.XXXXXX)
			local _v4_data
			_v4_data=$(grep -v '^#' "$cn_v4_file" | grep -v '^[[:space:]]*$' | paste -sd, -)
			if [ -z "$_v4_data" ]; then
				log "WARN: ${cn_v4_file} has no valid CIDRs, skipping surflare cn_ipv4"
			else
			printf 'add element inet surflare cn_ipv4 { %s }\n' "$_v4_data" > "$tmp_nft"
			local _v4_ok=0 _v4_try=0
			while [ "$_v4_try" -lt 3 ] && [ "$_v4_ok" -eq 0 ]; do
				if nft -f "$tmp_nft" 2>/dev/null; then _v4_ok=1
				else _v4_try=$((_v4_try+1)); [ "$_v4_try" -lt 3 ] && sleep 2; fi
			done
			if [ "$_v4_ok" -eq 1 ]; then
				if ! nft list chain inet surflare output 2>/dev/null \
					| grep -q 'ip daddr @cn_ipv4 accept'; then
					nft insert rule inet surflare output ip daddr @cn_ipv4 accept 2>/dev/null || true
				fi
				log "Chnroute v4 applied: CN prefixes bypass proxy via output chain"
				bypass_applied=$((bypass_applied + 1))
			else
				log "WARN: Failed to load Chnroute v4 into surflare output after 3 attempts"
			fi
			fi
			rm -f "$tmp_nft"
		fi

		if [ -f "$cn_v6_file" ]; then
			local cn_count_v6 cn_date_v6
			cn_count_v6=$(grep -vc '^#' "$cn_v6_file" 2>/dev/null || echo 0)
			cn_date_v6=$(stat -c '%y' "$cn_v6_file" 2>/dev/null | cut -d' ' -f1)
			log "Applying Chnroute v6 to surflare output: ${cn_count_v6} prefixes (${cn_date_v6})"

			nft add set inet surflare cn_ipv6 '{ type ipv6_addr; flags interval; }' 2>/dev/null || true
			nft flush set inet surflare cn_ipv6 2>/dev/null || true

			local tmp_nft_v6
tmp_nft_v6=$(mktemp /tmp/cn_ipv6.XXXXXX)
			local _v6_data
			_v6_data=$(grep -v '^#' "$cn_v6_file" | grep -v '^[[:space:]]*$' | paste -sd, -)
			if [ -z "$_v6_data" ]; then
				log "WARN: ${cn_v6_file} has no valid CIDRs, skipping surflare cn_ipv6"
			else
			printf 'add element inet surflare cn_ipv6 { %s }\n' "$_v6_data" > "$tmp_nft_v6"
			local _v6_ok=0 _v6_try=0
			while [ "$_v6_try" -lt 3 ] && [ "$_v6_ok" -eq 0 ]; do
				if nft -f "$tmp_nft_v6" 2>/dev/null; then _v6_ok=1
				else _v6_try=$((_v6_try+1)); [ "$_v6_try" -lt 3 ] && sleep 2; fi
			done
			if [ "$_v6_ok" -eq 1 ]; then
				if ! nft list chain inet surflare output 2>/dev/null \
					| grep -q 'ip6 daddr @cn_ipv6 accept'; then
					nft insert rule inet surflare output ip6 daddr @cn_ipv6 accept 2>/dev/null || true
				fi
				log "Chnroute v6 applied: CN v6 prefixes bypass proxy via output chain"
				bypass_applied=$((bypass_applied + 1))
			else
				log "WARN: Failed to load Chnroute v6 into surflare output after 3 attempts"
			fi
			fi
			rm -f "$tmp_nft_v6"
		fi

		# Cloud CDN extra bypass additive to surflare cn_ipv4 (Tencent/Alibaba APAC).
		if [ -f "$cn_v4_extra_file" ]; then
			local extra_count extra_date
			extra_count=$(grep -vc '^#' "$cn_v4_extra_file" 2>/dev/null || echo 0)
			extra_date=$(stat -c '%y' "$cn_v4_extra_file" 2>/dev/null | cut -d' ' -f1)
			log "Cloud CDN extra: ${extra_count} CIDRs (${extra_date}) -> surflare cn_ipv4"
			local tmp_extra="/tmp/cn_v4_extra_$$.nft"
			local _extra_data
			_extra_data=$(grep -v '^#' "$cn_v4_extra_file" | \
				grep -v '^[[:space:]]*$' | paste -sd, -)
			if [ -z "$_extra_data" ]; then
				log "WARN: ${cn_v4_extra_file} has no valid CIDRs"
			else
			printf 'add element inet surflare cn_ipv4 { %s }\n' "$_extra_data" > "$tmp_extra"
			if nft -f "$tmp_extra" 2>/dev/null; then
				log "Cloud CDN extra bypass applied to surflare cn_ipv4"
			else
				log "WARN: cloud CDN extra bypass load failed (nft error)"
			fi
			fi
			rm -f "$tmp_extra"
		fi
	fi

	# --- killswitch bypass sets (both modes, one atomic batch) ---
	# Build a single nft batch file containing flush+add for all sources
	# (v4 + cloud CDN extra + v6).  One nft -f call = one netlink transaction.
	# No race window between cn_ipv4.txt and cn_ipv4_extra.txt loading.
	local _ks_batch
_ks_batch=$(mktemp /tmp/ks_bypass_all.XXXXXX)
	local _ks_sources=0
	: > "$_ks_batch"

	if [ -f "$cn_v4_file" ]; then
		local _cn_count _cn_date _ks_v4
		_cn_count=$(grep -vc '^#' "$cn_v4_file" 2>/dev/null || echo 0)
		_cn_date=$(stat -c '%y' "$cn_v4_file" 2>/dev/null | cut -d' ' -f1)
		_ks_v4=$(grep -v '^#' "$cn_v4_file" | grep -v '^[[:space:]]*$' | paste -sd, -)
		if [ -n "$_ks_v4" ]; then
			{
				printf 'flush set inet killswitch bypass_ipv4\n'
				printf 'add element inet killswitch bypass_ipv4 { %s }\n' "$_ks_v4"
			} >> "$_ks_batch"
			_ks_sources=$((_ks_sources + 1))
		else
			log "WARN: ${cn_v4_file} has no valid CIDRs, bypass_ipv4 not updated"
		fi
	fi
	# Cloud CDN extra: additive to bypass_ipv4 (same batch, no separate flush).
	if [ -f "$cn_v4_extra_file" ]; then
		local _ks_extra
		_ks_extra=$(grep -v '^#' "$cn_v4_extra_file" | \
			grep -v '^[[:space:]]*$' | paste -sd, -)
		[ -n "$_ks_extra" ] && \
			printf 'add element inet killswitch bypass_ipv4 { %s }\n' "$_ks_extra" >> "$_ks_batch"
	fi
	if [ -f "$cn_v6_file" ]; then
		local _ks_v6
		_ks_v6=$(grep -v '^#' "$cn_v6_file" | grep -v '^[[:space:]]*$' | paste -sd, -)
		if [ -n "$_ks_v6" ]; then
			{
				printf 'flush set inet killswitch bypass_ipv6\n'
				printf 'add element inet killswitch bypass_ipv6 { %s }\n' "$_ks_v6"
			} >> "$_ks_batch"
			_ks_sources=$((_ks_sources + 1))
		else
			log "WARN: ${cn_v6_file} has no valid CIDRs, bypass_ipv6 not updated"
		fi
	fi

	if [ "$_ks_sources" -gt 0 ]; then
		if nft -f "$_ks_batch" 2>/dev/null; then
			bypass_applied=$((bypass_applied + _ks_sources))
			log "Killswitch bypass synced: v4+extra+v6 atomic, mode=${MODE}"
		else
			log "WARN: killswitch bypass atomic sync failed"
		fi
	fi
	rm -f "$_ks_batch"

	if [ "$bypass_applied" -eq 0 ]; then
		log "WARN: no chnroute files; CN bypass disabled"
	fi
	# cn_direct is NOT populated here: _restore_tproxy (called later in the
	# connect flow) does destroy+reload which empties all sets.  The connect
	# flow calls _load_tproxy_cn_direct after _restore_tproxy instead.
}

# Load CN CIDRs into sw_lan_tproxy cn_direct/cn6_direct sets so that
# CN-destined LAN traffic bypasses tproxy and exits via ISP direct.
# This fixes CDN acceleration and CN app geo-detection in global mode.
# In rule mode: no-op (surflare-proxy handles CN split at app layer).
# Called after _restore_tproxy (which empties all sets via destroy+reload)
# and at the end of _setup_chnroute (initial connect).
_load_tproxy_cn_direct() {
	# Belt-and-suspenders CN bypass at nftables layer.  In rule mode
	# sing-box also does CN split, but its geoip misses cloud CDN APAC
	# ranges (149.104.x etc.) that cn_ipv4_extra.txt covers.  Loading
	# cn_direct is strictly additive: hits go direct, misses still
	# reach sing-box for app-layer split.
	nft list table inet sw_lan_tproxy >/dev/null 2>&1 || return 0

	local cn_v4_file="/etc/surflare/cn_ipv4.txt"
	local cn_v4_extra_file="/etc/surflare/cn_ipv4_extra.txt"
	local cn_v6_file="/etc/surflare/cn_ipv6.txt"
	local _batch="/tmp/tproxy_cn_direct_$$.nft"
	local _loaded=0

	: > "$_batch"
	# IPv4: cn_ipv4.txt + cn_ipv4_extra.txt
	[ ! -f "$cn_v4_file" ] && \
		log "WARN: ${cn_v4_file} missing, cn_direct will be empty"
	if [ -f "$cn_v4_file" ]; then
		local _v4_cidrs
		_v4_cidrs=$(grep -v '^#' "$cn_v4_file" | grep -v '^[[:space:]]*$' | paste -sd, -)
		if [ -n "$_v4_cidrs" ]; then
			{
				printf 'flush set inet sw_lan_tproxy cn_direct\n'
				printf 'add element inet sw_lan_tproxy cn_direct { %s }\n' "$_v4_cidrs"
			} >> "$_batch"
			_loaded=$((_loaded + 1))
		else
			log "WARN: ${cn_v4_file} has no valid CIDRs"
		fi
	fi
	if [ -f "$cn_v4_extra_file" ]; then
		local _extra_cidrs
		_extra_cidrs=$(grep -v '^#' "$cn_v4_extra_file" | \
			grep -v '^[[:space:]]*$' | paste -sd, -)
		[ -n "$_extra_cidrs" ] && \
			printf 'add element inet sw_lan_tproxy cn_direct { %s }\n' "$_extra_cidrs" >> "$_batch"
	fi
	# IPv6: cn_ipv6.txt
	[ ! -f "$cn_v6_file" ] && \
		log "WARN: ${cn_v6_file} missing, cn6_direct will be empty"
	if [ -f "$cn_v6_file" ]; then
		local _v6_cidrs
		_v6_cidrs=$(grep -v '^#' "$cn_v6_file" | grep -v '^[[:space:]]*$' | paste -sd, -)
		if [ -n "$_v6_cidrs" ]; then
			{
				printf 'flush set inet sw_lan_tproxy cn6_direct\n'
				printf 'add element inet sw_lan_tproxy cn6_direct { %s }\n' "$_v6_cidrs"
			} >> "$_batch"
			_loaded=$((_loaded + 1))
		else
			log "WARN: ${cn_v6_file} has no valid CIDRs"
		fi
	fi

	if [ "$_loaded" -gt 0 ]; then
		local _nft_err
		if _nft_err=$(nft -f "$_batch" 2>&1); then
			local _v4c _v6c
			_v4c=$(nft list set inet sw_lan_tproxy cn_direct 2>/dev/null | grep -c '/')
			_v6c=$(nft list set inet sw_lan_tproxy cn6_direct 2>/dev/null | grep -c '/')
			log "Tproxy cn_direct loaded: ${_v4c} v4 + ${_v6c} v6 CIDRs (global mode LAN CN bypass)"
		else
			log "WARN: tproxy cn_direct load failed: ${_nft_err}"
		fi
	fi
	rm -f "$_batch"
}

# _ensure_smartdns_loader_fix: the nightly SmartDNS package bundles a
# musl dynamic loader but ships with a broken symlink (ld-musl-x86_64.so.1
# missing from the bundled lib dir).  The wrapper script also needs to
# invoke the loader explicitly because the binary's PT_INTERP is a
# relative path that the kernel cannot resolve.  opkg reinstall overwrites
# both files, so verify and repair on every startup.
_ensure_smartdns_loader_fix() {
	[ -x /usr/local/lib/smartdns/smartdns ] || return 0
	local _lib_dir=/usr/local/lib/smartdns/lib
	local _wrapper=/usr/local/lib/smartdns/run-smartdns
	if [ ! -e "$_lib_dir/ld-linux.so" ] || \
		[ "$(readlink "$_lib_dir/ld-linux.so" 2>/dev/null)" != "/lib/ld-musl-x86_64.so.1" ]; then
		mkdir -p "$_lib_dir" 2>/dev/null
		if ln -sf /lib/ld-musl-x86_64.so.1 "$_lib_dir/ld-linux.so" 2>/dev/null; then
			log "SmartDNS loader fix: repaired ld-linux.so symlink"
		else
			log "WARN: SmartDNS loader fix: failed to repair ld-linux.so"
		fi
	fi
	# shellcheck disable=SC2016  # literal ${SMARTDNS_BIN} match in wrapper file
	if grep -q 'exec "${SMARTDNS_BIN}" $@' "$_wrapper" 2>/dev/null; then
		# shellcheck disable=SC2016  # literal pattern/replacement in wrapper file
		if sed -i 's|SMARTDNS_WORKDIR="$CWD" exec "${SMARTDNS_BIN}" $@|SMARTDNS_WORKDIR="$CWD" exec "${INTERPRETER}" "${SMARTDNS_BIN}" $@|' "$_wrapper" 2>/dev/null; then
			log "SmartDNS loader fix: repaired wrapper exec line"
		else
			log "WARN: SmartDNS loader fix: failed to repair wrapper"
		fi
	fi
}

# _cleanup_on_startup: called once at the top of the main loop.
# Unconditionally kill any inherited surflare-proxy and nuke stale
# watchdog-managed nftables state.  This prevents ghost rules from a
# crashed/killed watchdog, and stops orphan proxies from holding
# port 10800 and blocking a fresh connection cycle.
_cleanup_on_startup() {
	# /tmp writability gate: nft batch files, probe temp files, and
	# conntrack operations all depend on /tmp.  If /tmp is full or
	# read-only, every downstream operation silently fails.
	if ! touch /tmp/.surflare_probe 2>/dev/null; then
		log "CRITICAL: /tmp not writable -- killswitch/tproxy/health check will fail"
		log "Attempting to free /tmp by removing stale surflare files"
		rm -f /tmp/surflare_* /tmp/ks_swap_* /tmp/tproxy_* /tmp/ct_* /tmp/cn_ipv4.* /tmp/cn_ipv6.* /tmp/cn_v4_extra.* /tmp/ks_bypass_all.* 2>/dev/null
		if ! touch /tmp/.surflare_probe 2>/dev/null; then
			log "CRITICAL: /tmp still not writable after cleanup -- exiting"
			exit 1
		fi
	fi
	rm -f /tmp/.surflare_probe 2>/dev/null

	# Crash-safe marker cleanup: if SIGKILL/OOM killed the old watchdog
	# after init.d created the marker but before cleanup() ran, a stale
	# marker would cause a future stop to skip proxy teardown.
	rm -f "$RESTART_MARKER"

	# Zero-kill adopt decision: check whether a healthy proxy is running
	# BEFORE any kill site.  If all conditions pass, set the adopt flag
	# so downstream kill sites are skipped.
	local _adopt_proxy=0
	if _proc_alive surflare-proxy >/dev/null 2>&1 \
	   && ss -ltn 2>/dev/null | grep -qE ':10800(\s|$)' \
	   && nft list table inet surflare >/dev/null 2>&1 \
	   && timeout 8 surflare ping google.com -p 443 >/dev/null 2>&1; then
		_adopt_proxy=1
	fi

	# Kill inherited proxy only when NOT adopting.
	if _proc_alive surflare-proxy >/dev/null 2>&1 && [ "$_adopt_proxy" -eq 0 ]; then
		log "Startup: killing inherited surflare-proxy"
		killall surflare-proxy 2>/dev/null
		_stop_proxy_log_monitor
		sleep 2
	fi
	# Kill orphan watchdog from previous instance.
	# The PID file always points to the main watchdog process (not
	# bash subshells from pipelines).  Kill it by PID, not pgrep.
	if [ -f "$PIDFILE" ]; then
		local _old_pid
		_old_pid=$(cat "$PIDFILE" 2>/dev/null)
		if [ -n "$_old_pid" ] && [ "$_old_pid" != "$$" ] && 		   kill -0 "$_old_pid" 2>/dev/null; then
			# Verify it's actually a watchdog, not a recycled PID
			if grep -q "surflare_watchdog" "/proc/$_old_pid/cmdline" 2>/dev/null; then
				log "Startup: killing orphan watchdog PID $_old_pid"
				kill -TERM "$_old_pid" 2>/dev/null
			fi
			sleep 1
			kill -0 "$_old_pid" 2>/dev/null && kill -9 "$_old_pid" 2>/dev/null
		fi
	# Kill any OTHER orphan watchdogs (PPid=1).
	# procd reparents exiting services to init, so orphaned watchdog
	# mains have PPid=1. We do NOT filter on stdin: procd starts services
	# with stdin=/dev/null (not a pipe), so a stdin=pipe filter misses
	# every real orphan and lets duplicates accumulate during respawn
	# storms. Legitimate children of this process have PPid=$$, never 1,
	# so the PPid=1 check alone is enough to avoid hitting connect_vpn
	# subshells or other children of $$.
	local _opid
	for _opid in $(pgrep -f surflare_watchdog.sh 2>/dev/null); do
		[ "$_opid" = "$$" ] && continue
		local _oppid
		_oppid=$(awk '/^PPid/{print $2}' /proc/"$_opid"/status 2>/dev/null)
		[ "$_oppid" != "1" ] && continue
		log "Startup: killing orphan watchdog PID $_opid"
		kill -9 "$_opid" 2>/dev/null
	done
	fi
	# Port-based cleanup: ensure 10800 is free (skip when adopting)
	if [ "$_adopt_proxy" -eq 0 ] && ss -ltn 2>/dev/null | grep -qE ':10800(\s|$)'; then
		if command -v fuser >/dev/null 2>&1; then
			fuser -k -9 10800/tcp 2>/dev/null || true
		else
			# ss fallback when fuser unavailable
			local _pid
			_pid=$(ss -lptn 2>/dev/null | grep ':10800' | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1)
			[ -n "$_pid" ] && kill -9 "$_pid" 2>/dev/null || true
		fi
		sleep 1
	fi

	# --- Crash-safe recovery: clean up stale state from a previous crash ---
	# A hard crash (SIGKILL, OOM) leaves stale PID/lock files, zombie
	# processes, and tombstoned tproxy rules.  Normal startup cannot
	# proceed until these are cleaned.

	# 1. Stale PID file: if the recorded PID is dead, remove it.
	if [ -f "$PIDFILE" ]; then
		local _old_pid
		_old_pid=$(cat "$PIDFILE" 2>/dev/null)
		if [ -n "$_old_pid" ] && ! kill -0 "$_old_pid" 2>/dev/null; then
			rm -f "$PIDFILE"
			log "Crash recovery: cleaned stale PID file (was PID ${_old_pid})"
		fi
	fi

	# 2. Stale lock file: always remove on startup.  The lock only matters
	#    while the watchdog is running; a fresh start must not be blocked.
	if [ -f "$LOCK_FILE" ]; then
		rm -f "$LOCK_FILE"
		log "Crash recovery: removed stale lock file"
	fi

	# 3. Zombie surflare processes: a hard crash during reconnect leaves
	#    defunct [surflare] processes that procd does not reap.  Their
	#    parent is sexpect (the PTY tool used by refresh_auth), which
	#    survives the watchdog crash in sleeping state.  Kill surflare
	#    first (parent sexpect reaps dying children normally), then
	#    sexpect.  Previous order (kill sexpect first -> reparent to
	#    init) caused zombies to accumulate because BusyBox init does
	#    not reliably reap orphaned processes.
	killall surflare 2>/dev/null || true
	sleep 0.5
	killall -9 surflare 2>/dev/null || true
	sleep 0.5
	killall sexpect 2>/dev/null || true
	# Wait for zombie reaping; BusyBox init is slow to reap orphans.
	# The surflare CLI hangs when API endpoints are unreachable
	# (no internal connect timeout); each hung login leaves one
	# zombie when the watchdog restarts.  Without this wait loop,
	# zombies accumulate across restart cycles (12+ observed).
	local _zombie_count _w
	_w=0
	while [ "$_w" -lt 5 ]; do
		_zombie_count=$(find /proc -maxdepth 2 -name comm -path '/proc/[0-9]*/comm' 2>/dev/null | while read -r _f; do
			[ "$(cat "$_f" 2>/dev/null)" = "surflare" ] && echo x
		done | wc -l)
		[ "$_zombie_count" -eq 0 ] && break
		sleep 1
		_w=$((_w + 1))
	done
	if [ "$_zombie_count" -gt 0 ]; then
		log "Crash recovery: ${_zombie_count} surflare zombie(s) survived cleanup (kernel will reap)"
	else
		log "Crash recovery: zombie surflare processes cleaned"
	fi

	# 4. Tombstoned tproxy: the previous watchdog tombstoned the tproxy
	#    rules (replaced tproxy with REJECT) before crashing.  LAN TCP
	#    gets TCP reset instead of being proxied.  Don't restore live
	#    tproxy here: surflare-proxy is not running yet (:10800 has no
	#    listener -> ECONNREFUSED).  Just load cn_direct so CN traffic
	#    bypasses the REJECT rules via ISP direct routing during the
	#    startup window.  connect_vpn will restore live tproxy after
	#    surflare-proxy is ready.  SKIPPED when adopting -- adopt path
	#    handles restore (proxy is alive, table rebuild is safe).
	if [ "$_adopt_proxy" -eq 0 ] && \
	   nft list table inet sw_lan_tproxy >/dev/null 2>&1; then
		if ! nft list chain inet sw_lan_tproxy prerouting 2>/dev/null | \
		   grep -q 'tproxy.*10800'; then
			_load_tproxy_cn_direct force
			# _block_unreachable_doh not called here: inet surflare does
			# not exist yet (deleted in modular teardown, recreated by
			# surflare connect --daemon later).  DoH reject is inserted
			# after connect_vpn returns in the main loop.
			log "Crash recovery: cn_direct loaded, tproxy stays tombstoned (proxy not running)"
		fi
	fi

	# 5. Orphaned watchdog_trace table: survives a crash because no one
	#    deletes it.  Harmless but noisy; clean it up.
	nft delete table inet watchdog_trace 2>/dev/null || true

	# 6. Stale IPC files in /run/: survive a crash between write and read.
	#    Without cleanup, a stale signal file causes false reconnect on
	#    the next instance (parent reads old auth result as current).
	rm -f /run/surflare_auth_fail_signal 2>/dev/null || true
	rm -f /run/surflare_stale_warn 2>/dev/null || true
	rm -f /run/surflare_urltest_all_unhealthy 2>/dev/null || true

	# 6. Stale pcap and log artifacts: packet trace pcaps, diagnostic
	#    phys pcaps, tcpdump error files, and old proxy log rotations
	#    accumulate across restarts on tmpfs (/tmp) and persist on disk.
	#    Globbing rm (not find -mmin) because busybox -mmin is unreliable
	#    on tmpfs with NTP-stepped clocks.
	rm -f /tmp/surflare_phys_*.pcap 2>/dev/null || true
	rm -f /tmp/surflare_watchdog_*.pcap 2>/dev/null || true
	rm -f /tmp/surflare_watchdog_*.pcap.err 2>/dev/null || true
	# Clean pre-timestamp-rotation .old artifact (23MB observed)
	rm -f /var/log/surflare/surflare-proxy.log.old 2>/dev/null || true

	# Adopt completion: proxy is alive, healthy, and all zombie/orphan
	# cleanup is done.  Start log monitor and skip nft/fwmark teardown.
	if [ "$_adopt_proxy" -eq 1 ]; then
		local _proxy_pid
		_proxy_pid=$(_pids_by_comm surflare-proxy | head -1)
		log "Startup: adopting running proxy (PID=${_proxy_pid:-unknown})"
		_start_proxy_log_monitor
		# Skip nft delete and ip rule del -- proxy needs them intact.
		# Killswitch is already armed from the previous instance;
		# refresh server_ips in case relay IPs changed between restarts.
		if nft list table inet killswitch >/dev/null 2>&1; then
			_killswitch_armed=1
			_update_killswitch_server_ips
		fi
		_ensure_dns_enforce
		# Unified tproxy restore guard (Problem A + Problem B):
		#   B: table exists but no live tproxy rules (tombstoned) -- restore
		#      so LAN traffic is not silently rejected while watchdog
		#      reports "healthy" (livelock).
		#   A: nft file changed since last restore (stale rules) -- restore
		#      so rate-limit and other rule updates take effect without
		#      killing the proxy (zero-kill invariant).
		# Stamp absent (first restart post-deploy) = treat as changed.
		# Proxy is verified healthy (alive + port + ping at L958-961);
		# table rebuild via _restore_tproxy is safe (atomic nft -f).
		local _tproxy_needs_restore=0
		if nft list table inet sw_lan_tproxy >/dev/null 2>&1; then
			if ! nft list chain inet sw_lan_tproxy prerouting 2>/dev/null | \
			   grep -q 'tproxy.*10800'; then
				_tproxy_needs_restore=1
				log "Startup: tproxy tombstoned, will restore (proxy healthy)"
			elif command -v md5sum >/dev/null 2>&1; then
				local _cur_md5 _saved_md5
				_cur_md5=$(md5sum /etc/surflare-lan-tproxy.nft 2>/dev/null | awk '{print $1}')
				_saved_md5=$(cat "$TPROXY_NFT_STAMP" 2>/dev/null | awk '{print $1}')
				if [ -n "$_cur_md5" ] && [ "$_cur_md5" != "$_saved_md5" ]; then
					_tproxy_needs_restore=1
					log "Startup: nft file changed (md5 mismatch), will restore"
				fi
			fi
		fi
		if [ "$_tproxy_needs_restore" -eq 1 ]; then
			_restore_tproxy
			_update_bypass_devices
		fi
		return 0
	fi

	log "Startup cleanup: surflare-proxy not running, flushing stale watchdog state"
	nft delete table inet surflare 2>/dev/null || true
	# Keep sw_lan_tproxy if it exists (tombstoned or live from a prior
	# instance): bypass_devices/auto_bypass sets persist, and the connect
	# flow will restore the tproxy rule via nft replace.
	# Old killswitch stays active until _install_killswitch() atomically
	# replaces it (destroy + create in one nft -f batch, no gap).
	# Always rebuild so rule changes from the updated script take effect.
	if nft list table inet killswitch >/dev/null 2>&1; then
		log "Existing killswitch active (will be rebuilt on connect)"
	fi
	# dns_enforce lives outside the killswitch table; ensure it exists.
	_ensure_dns_enforce
	ip rule del fwmark 0x1 lookup 100 2>/dev/null || true
	ip -6 rule del fwmark 0x1 lookup 100 2>/dev/null || true
	# F13: respect an in-progress storm cool across a restart.  If the
	# persisted cool-until timestamp is in the future, sleep the
	# remaining window before re-entering the main loop.  This prevents
	# a watchdog crash mid-storm from resetting the cool state and
	# immediately re-triggering storm protection.
	local _cool_file="/run/surflare_watchdog.storm_cool_until"
	if [ -f "$_cool_file" ]; then
		local _cool_target _now _remaining
		_cool_target=$(cat "$_cool_file" 2>/dev/null)
		_now=$(date +%s)
		if [ -n "$_cool_target" ] && [ "$_cool_target" -gt "$_now" ] 2>/dev/null; then
			_remaining=$((_cool_target - _now))
			log "Storm cool in progress; sleeping ${_remaining}s before main loop"
			sleep "$_remaining" &
			storm_sleep_pid=$!; wait "$storm_sleep_pid" || true
			storm_sleep_pid=""
		fi
		rm -f "$_cool_file"
	fi
	# Rotate proxy log if > 10MB to prevent unbounded growth.
	# Timestamp suffix avoids overwriting the only backup on crash loops.
	if [ -f "$PROXY_LOG" ]; then
		local _log_size
		_log_size=$(stat -c %s "$PROXY_LOG" 2>/dev/null || echo 0)
		if [ "$_log_size" -gt 10485760 ]; then
			mv "$PROXY_LOG" "${PROXY_LOG}.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
			log "Proxy log rotated (was $((_log_size / 1048576))MB)"
		fi
	fi
}

# Ensure dns_enforce table exists.  Idempotent: skips if already present.
# Extracted from _install_killswitch so it runs even when the killswitch
# survives a restart (the reuse path skips _install_killswitch entirely).
_ensure_dns_enforce() {
	[ "$PLATFORM" = "router" ] || return 0
	nft list table ip dns_enforce >/dev/null 2>&1 && return 0
	# fib daddr type local covers all dnsmasq listen addresses without
	# hardcoding IPs.  Router-originated DNS is unaffected (no iifname
	# "br-lan" match on locally generated packets).  Silent reject only;
	# dns-bypass logging removed (it was DNS hygiene noise, not IP leak).
	if nft -f - <<'DNS_EOF'
table ip dns_enforce {
	set vpn_bypass { type ipv4_addr; }
	chain prerouting {
		type filter hook prerouting priority mangle - 20; policy accept;
		iifname "br-lan" meta l4proto { tcp, udp } th dport 53 ip saddr @vpn_bypass accept
		iifname "br-lan" meta l4proto { tcp, udp } th dport 53 fib daddr type local accept
		iifname "br-lan" meta l4proto { tcp, udp } th dport 53 reject with icmp port-unreachable
	}
}
DNS_EOF
	then
		log "DNS enforcement armed: LAN bypass DNS rejected"
	else
		log "WARN: DNS enforcement table load failed"
	fi
}

# NOTE: _seal_killswitch_ff() removed (was called after server_ips populated).
# surflare-proxy uses SO_MARK=0xff for outbound relay connections permanently,
# not just during bootstrap.  Removing the 0xff accept rule caused ks-drop of
# new connections -> tunnel degradation.  0xff is now permanent (like 0x1) in
# the _install_killswitch() heredoc.

# Remove only the output chain from killswitch table, leaving forward chain
# and all sets intact.  Used by connect_vpn() to escape self-lock without
# destroying the forward chain's LAN protection.
_unarm_killswitch_output() {
	# Guard: table must exist
	nft list table inet killswitch >/dev/null 2>&1 || return 0
	# Guard: output chain must exist (handles double-call)
	nft list chain inet killswitch output >/dev/null 2>&1 || return 0

	nft flush chain inet killswitch output 2>/dev/null || true
	nft delete chain inet killswitch output 2>/dev/null || true

	# Flush stale conntrack entries that used the old output chain rules.
	# Scoped flush first (mark 1 = tproxy-marked flows only); unscoped
	# fallback for older conntrack that lacks -m.
	if conntrack -D -m mark 1 >/dev/null 2>&1; then
		: # scoped flush ok
	elif conntrack -F >/dev/null 2>&1; then
		log "WARN: conntrack scoped flush unavailable; ran unscoped -F"
	else
		log "WARN: conntrack flush failed"
	fi

	log "killswitch output chain removed, forward chain intact"
}

# Recreate only the output chain inside the existing killswitch table.
# Sets and forward chain already exist and are not touched.  Used by
# connect_vpn() after surflare connect succeeds/fails/times out.
# Falls back to full _install_killswitch() if the table or forward
# chain is missing (covers concurrent teardown or corruption).
# MAINTENANCE: output chain rules below must stay in sync with
# the output chain section inside _install_killswitch().
_reinstall_killswitch_output() {
	# Guard: if table or forward chain missing, do full install
	if ! nft list chain inet killswitch forward >/dev/null 2>&1; then
		_install_killswitch
		return
	fi

	# Safety: if output chain exists (double-call), flush+delete first
	if nft list chain inet killswitch output >/dev/null 2>&1; then
		nft flush chain inet killswitch output 2>/dev/null || true
		nft delete chain inet killswitch output 2>/dev/null || true
	fi

	local _ks_tmp="/tmp/ks_output_$$.nft"
	cat > "$_ks_tmp" << 'NFTEOF'
add chain inet killswitch output { type filter hook output priority filter + 20 ; policy drop ; }
add rule inet killswitch output ct state invalid drop
add rule inet killswitch output oif "lo" accept
add rule inet killswitch output ip daddr @server_ips accept
add rule inet killswitch output ip6 daddr @server_ips6 accept
add rule inet killswitch output meta mark == 0x1 accept
add rule inet killswitch output meta mark == 0xff accept
add rule inet killswitch output ip daddr @bypass_ipv4 accept
add rule inet killswitch output ip6 daddr @bypass_ipv6 accept
add rule inet killswitch output ip daddr @lan_ranges accept
add rule inet killswitch output ip6 daddr @lan6_ranges accept
add rule inet killswitch output ip daddr 255.255.255.255 accept
add rule inet killswitch output ip daddr 224.0.0.0/4 accept
add rule inet killswitch output ip6 daddr ff00::/8 accept
add rule inet killswitch output udp sport 68 udp dport 67 accept
add rule inet killswitch output udp sport 546 udp dport 547 accept
add rule inet killswitch output meta skuid "root" udp dport 123 accept
add rule inet killswitch output meta l4proto udp reject with icmp port-unreachable
add rule inet killswitch output meta nfproto ipv6 reject with icmpv6 addr-unreachable
add rule inet killswitch output tcp flags syn / fin,syn,rst,ack limit rate 5/second burst 10 packets log prefix "ks-drop: "
add rule inet killswitch output counter drop
NFTEOF

	# Adjust NTP skuid: chrony on systemd distros, root on OpenWrt
	local _ntp_user
	_ntp_user=$(id -u chrony >/dev/null 2>&1 && echo chrony || echo root)
	sed -i "s/meta skuid \"root\"/meta skuid \"$_ntp_user\"/" "$_ks_tmp"

	if ! nft -f "$_ks_tmp"; then
		log "ERROR: output chain reinstall failed, falling back to full install"
		rm -f "$_ks_tmp"
		_install_killswitch
		return
	fi

	# Verify output chain exists after load
	if ! nft list chain inet killswitch output >/dev/null 2>&1; then
		log "ERROR: output chain missing after nft -f, falling back to full install"
		rm -f "$_ks_tmp"
		_install_killswitch
		return
	fi

	rm -f "$_ks_tmp"

	# Remove boot-time lockdown if still present
	if nft list table inet surflare_boot_lock >/dev/null 2>&1; then
		nft destroy table inet surflare_boot_lock 2>/dev/null || true
		log "Boot lock removed: killswitch output reinstalled"
	fi
}

_install_killswitch() {
	local _ks_tmp="/tmp/ks_install_$$.nft"
	# Atomic table replacement: destroy + create in a single nft -f transaction.
	# nft processes the batch file as one netlink message, so the kernel swaps
	# the old table for the new one with no gap where traffic is unprotected.
	cat > "$_ks_tmp" << 'NFTEOF'
destroy table inet killswitch
table inet killswitch {
	set server_ips  { type ipv4_addr; }
	set server_ips6 { type ipv6_addr; }
	set bypass_ipv4 { type ipv4_addr; flags interval; }
	set bypass_ipv6 { type ipv6_addr; flags interval; }
	# bypass_src/bypass_src6: LAN device source IPs that skip tproxy.
	# Their non-CN traffic is forwarded directly; no log noise needed.
	set bypass_src  { type ipv4_addr; }
	set bypass_src6 { type ipv6_addr; }
	# CN domain nftset: SmartDNS adds resolved IPs when a CN domain
	# resolves to a non-CN CDN IP (Cloudflare/Akamai/etc).  Allows
	# LAN devices to reach CN content on foreign CDN directly without
	# routing through the VPN proxy.  Entries expire after 1h;
	# SmartDNS re-adds on next DNS query.
	set cn_domain_ips  { type ipv4_addr; flags interval, timeout; timeout 1h; }
	set cn6_domain_ips { type ipv6_addr; flags interval, timeout; timeout 1h; }
	set lan_ranges {
		type ipv4_addr
		flags interval
		elements = {
			10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16,
			172.16.0.0/12, 192.168.0.0/16
		}
	}
	set lan6_ranges {
		type ipv6_addr
		flags interval
		elements = { ::1/128, fe80::/10, fc00::/7 }
	}
	chain output {
		type filter hook output priority filter + 20; policy drop;
		ct state invalid drop
		oif "lo" accept
		ip daddr @server_ips accept
		ip6 daddr @server_ips6 accept
		meta mark == 0x1 accept
		meta mark == 0xff accept
		ip daddr @bypass_ipv4 accept
		ip6 daddr @bypass_ipv6 accept
		ip daddr @lan_ranges accept
		ip6 daddr @lan6_ranges accept
		ip daddr 255.255.255.255 accept
		ip daddr 224.0.0.0/4 accept
		ip6 daddr ff00::/8 accept
		udp sport 68 udp dport 67 accept
		udp sport 546 udp dport 547 accept
		meta skuid chrony udp dport 123 accept
		# REJECT non-whitelisted UDP (QUIC clients fall back to TCP <1ms)
		meta l4proto udp reject with icmp port-unreachable
		# REJECT non-whitelisted IPv6 (Happy Eyeballs falls back to IPv4 <250ms)
		meta nfproto ipv6 reject with icmpv6 addr-unreachable
		# Only log new outbound connection attempts (SYN).  RST, ACK, FIN
		# reaching here are kernel auto-responses to inbound probes or
		# orphaned post-reconnect cleanup -- not bypass attempts.
		tcp flags syn / fin,syn,rst,ack limit rate 5/second burst 10 packets log prefix "ks-drop: "
		counter drop
	}

	# chain forward: block non-CN IPv6 from LAN devices.
	# surflare is IPv4-only tproxy; without this chain, LAN devices with IPv6
	# (e.g. systemd-resolved bypassing dnsmasq force-AAAA-SOA) reach non-CN
	# IPv6 destinations via CN ISP IPv6, bypassing the VPN entirely.
	# Reject unmatched LAN-originated traffic.  During normal operation,
	# non-CN TCP from LAN goes through sw_lan_tproxy and never reaches this
	# chain.  This reject is the safety net for the tproxy-down window
	# (reconnect, restart, crash): without it, non-CN LAN TCP falls through
	# to the accept policy and is forwarded directly, leaking the real IP.
	# bypass_devices traffic (Thunder CN bypass) is accepted above.
	chain forward {
		type filter hook forward priority filter - 10; policy accept;
		ct state established,related accept
		ct state invalid drop
		iifname "br-lan" oifname "br-lan" accept
		# Modem management: LAN devices (e.g. mesh APs) reach the modem
		# via eth0 (physical WAN port).  This traffic never traverses the
		# VPN tunnel; accept before the reject rules below.
		iifname "br-lan" oifname "eth0" ip daddr 192.168.1.0/24 accept
		iifname "br-lan" ip daddr @server_ips accept
		# server_ips6 always empty: surflare is IPv4-only; _update_server_endpoint
		# only extracts IPv4 addrs.  Kept as no-op for future IPv6 VPN support.
		iifname "br-lan" ip6 daddr @server_ips6 accept
		iifname "br-lan" ip daddr @bypass_ipv4 accept
		iifname "br-lan" ip6 daddr @bypass_ipv6 accept
		iifname "br-lan" ip daddr @cn_domain_ips accept
		iifname "br-lan" ip6 daddr @cn6_domain_ips accept
		iifname "br-lan" ip saddr @bypass_src accept
		iifname "br-lan" ip6 saddr @bypass_src6 accept
		# Private destinations from LAN (carrier IPs, app-internal VPNs)
		# are not external leaks; accept like the output chain does.
		iifname "br-lan" ip daddr @lan_ranges accept
		iifname "br-lan" ip6 daddr @lan6_ranges accept
		# NTP: basic utility, no privacy data, devices need accurate time
		# for TLS certificate validation.
		iifname "br-lan" udp dport 123 accept
		# Only log non-UDP.  Non-CN UDP is correctly blocked here (tproxy
		# is TCP-only); logging it flooded the 601-line dmesg ring buffer.
		# TCP here means it escaped tproxy -- worth investigating.
		iifname "br-lan" meta l4proto != udp limit rate 5/second burst 10 packets log prefix "ks-fwd-mon: "
		iifname "br-lan" meta nfproto ipv6 reject with icmpv6 addr-unreachable
		iifname "br-lan" reject with icmp host-unreachable
	}
}
NFTEOF
	# Adjust NTP skuid: chrony on systemd distros, root on OpenWrt (ntpd runs as root)
	local _ntp_user
	_ntp_user=$(id -u chrony >/dev/null 2>&1 && echo chrony || echo root)
	sed -i "s/skuid chrony/skuid $_ntp_user/" "$_ks_tmp"

	if nft -f "$_ks_tmp"; then
		log "Kill switch installed (inet killswitch, policy drop, ntp-user=$_ntp_user)"
	else
		nft -f "$_ks_tmp" >&2  # log actual nft error to stderr/dmesg
		log "ERROR: kill switch install failed"
		rm -f "$_ks_tmp"
		return 1
	fi

	# Pre-populate bypass_src to close the startup race window.
	# Without this, bypass device traffic is rejected during the brief
	# gap between killswitch install and _update_bypass_devices call.
	if [ -n "$BYPASS_LAN_DEVICES" ]; then
		nft add element inet killswitch bypass_src "{ $BYPASS_LAN_DEVICES }" 2>/dev/null || true
	fi

	# Flush stale conntrack entries that predate the new killswitch rules.
	# Done AFTER the atomic nft -f load so the new rules are already
	# governing new connections while old entries are being flushed.
	# Prefer scoped flush (-D -m mark N) to only kill tproxy-marked flows,
	# leaving unrelated connections (LAN, monitoring) untouched.
	# Fall back to unscoped -F on older conntrack (<1.4.4) that lacks -m.
	# stdout MUST be captured (not inherited): conntrack -D/-F print
	# every deleted entry to stdout, which procd would forward to syslog,
	# flooding the log with thousands of conntrack lines on a busy router.
	if conntrack -D -m mark 1 >/dev/null 2>&1; then
		: # scoped flush ok
	elif conntrack -F >/dev/null 2>&1; then
		log "WARN: conntrack scoped flush unavailable; ran unscoped -F (drops ALL tracked connections)"
	else
		log "WARN: conntrack flush failed; pre-existing connections may persist"
	fi
	# Post-install verification: a silent nft -f failure would leave the
	# watchdog believing killswitch is up while the kernel has no such
	# table.  List the table back; if missing, treat as install failure.
	if ! nft list table inet killswitch >/dev/null 2>&1; then
		log "ERROR: kill switch post-install verification failed; table missing"
		rm -f "$_ks_tmp"
		return 1
	fi
	rm -f "$_ks_tmp"

	# Remove boot-time lockdown now that killswitch is armed.
	# surflare-bootlock (S18) blocks LAN overseas traffic during the boot
	# window before this watchdog starts; no longer needed once the real
	# killswitch is in place.
	if nft list table inet surflare_boot_lock >/dev/null 2>&1; then
		nft destroy table inet surflare_boot_lock 2>/dev/null || true
		log "Boot lock removed: killswitch now armed"
	fi

	# Enforce LAN DNS through the router's dnsmasq/SmartDNS.
	# Reject any br-lan DNS (port 53) not destined for the router itself.
	_ensure_dns_enforce

	# F8: repopulate server_ips from disk if available.  A watchdog restart
	# (e.g. crash + procd respawn) loses the in-memory _diag_server_ips set,
	# so the killswitch would be installed with an empty server_ips and
	# drop ALL VPN server traffic until the next diagnostic run.  Reading
	# from /etc/surflare/server_ips (last persisted by
	# _update_killswitch_server_ips) bridges that gap.
	# FIX #5: previously `tr -d '[:space:]'` stripped all whitespace, concatenating
	# multi-IP payloads (e.g. "72.244.37.221 8.8.8.8" became "72.244.37.2218.8.8.8"
	# which nft cannot parse as a set element). Collapse runs of whitespace to a
	# single space, then convert to comma for nft.
	local _persist_v4="/etc/surflare/server_ips"
	if [ -z "$_diag_server_ips" ] && [ -f "$_persist_v4" ]; then
		_diag_server_ips=$(tr -s '[:space:]' ' ' < "$_persist_v4" 2>/dev/null | sed 's/^ //; s/ $//')
		if [ -n "$_diag_server_ips" ]; then
			local _persist_csv
			_persist_csv=$(echo "$_diag_server_ips" | tr ' ' ',')
			nft add element inet killswitch server_ips "{ ${_persist_csv} }" 2>/dev/null || \
				log "WARN: failed to repopulate server_ips from $_persist_v4"
			log "Kill switch: server_ips restored from disk (${_diag_server_ips})"
		fi
	fi

	local cn_v4_file="/etc/surflare/cn_ipv4.txt"
	local cn_v6_file="/etc/surflare/cn_ipv6.txt"
	# 3.4: on first boot before route_updater ran, cn_ipv6.txt does not exist.
	# Without a fallback, bypass_ipv6 stays empty and chain forward drops ALL
	# LAN IPv6 (including CN destinations) until the nightly cron runs.
	# Fall back to the bundled baseline installed by install.sh.
	# install.sh copies routes/ to /usr/local/share/surflare/routes/.
	local _bundled_cn_v6="/usr/local/share/surflare/routes/cn_ipv6.txt"
	[ -f "$cn_v6_file" ] || { [ -f "$_bundled_cn_v6" ] && cn_v6_file="$_bundled_cn_v6"; }
	if [ -f "$cn_v4_file" ]; then
		local bypass_v4
		bypass_v4=$(grep -v '^#' "$cn_v4_file" | grep -v '^[[:space:]]*$' | paste -sd, -)
		if [ -n "$bypass_v4" ]; then
			nft add element inet killswitch bypass_ipv4 "{ $bypass_v4 }" 2>/dev/null || \
				log "WARN: failed to load bypass_ipv4"
		fi
	fi
	if [ -f "$cn_v6_file" ]; then
		local bypass_v6
		bypass_v6=$(grep -v '^#' "$cn_v6_file" | grep -v '^[[:space:]]*$' | paste -sd, -)
		if [ -n "$bypass_v6" ]; then
			nft add element inet killswitch bypass_ipv6 "{ $bypass_v6 }" 2>/dev/null || \
				log "WARN: failed to load bypass_ipv6"
		fi
	fi
	local _ks_extra="/etc/surflare/cn_ipv4_extra.txt"
	if [ -f "$_ks_extra" ]; then
		local extra_v4
		extra_v4=$(grep -v '^#' "$_ks_extra" \
			| grep -v '^[[:space:]]*$' | paste -sd, -)
		if [ -n "$extra_v4" ]; then
			nft add element inet killswitch bypass_ipv4 "{ $extra_v4 }" 2>/dev/null || \
				log "WARN: failed to load cloud CDN extra bypass_ipv4"
		fi
	fi
}

_update_killswitch_server_ips() {
	# Phase 2B: 3-level fallback -- socket IPs -> disk backup -> keep existing
	if [ -z "$_diag_server_ips" ]; then
		# Level 2: try disk backup when socket extraction failed
		if [ -f /etc/surflare/server_ips ]; then
			_diag_server_ips=$(tr '\n' ' ' < /etc/surflare/server_ips 2>/dev/null)
			[ -n "$_diag_server_ips" ] && \
				log "server_ips: socket empty, using disk backup"
		fi
		# Level 2.5: try persist file (saved before storm cooldown flush)
		if [ -z "$_diag_server_ips" ] && [ -f /run/surflare_watchdog.server_ips_v4 ]; then
			_diag_server_ips=$(tr -s '[:space:]' ' ' \
				< /run/surflare_watchdog.server_ips_v4 2>/dev/null \
				| sed 's/^ //; s/ $//')
			[ -n "$_diag_server_ips" ] && \
				log "server_ips: socket+disk empty, using persist file"
		fi
		# Level 3: keep existing set unchanged
		[ -z "$_diag_server_ips" ] && {
			log "CRITICAL: no server IPs from socket, disk, or persist; keeping existing set"
			return
		}
	fi
	nft list table inet killswitch >/dev/null 2>&1 || return
	local ip_csv
	ip_csv=$(echo "$_diag_server_ips" | tr ' ' ',')
	# F7: atomic swap of server_ips via single nft -f batch.
	# flush + add in one file = one netlink transaction = no empty window.
	# Validate in a scratch table first; if validation passes, swap
	# production in a single batch.  If the batch fails, fall back to
	# disk backup.
	local _ks_tmp="/tmp/ks_swap_$$.nft"
	cat > "$_ks_tmp" << NFTEOF
table inet killswitch_swap {
	set server_ips { type ipv4_addr; }
}
NFTEOF
	if nft -f "$_ks_tmp" 2>/dev/null \
		&& nft add element inet killswitch_swap server_ips "{ $ip_csv }" 2>/dev/null; then
		local _swap_tmp="/tmp/ks_swap_prod_$$.nft"
		cat > "$_swap_tmp" << SWAPEOF
flush set inet killswitch server_ips
add element inet killswitch server_ips { $ip_csv }
SWAPEOF
		if ! nft -f "$_swap_tmp" 2>/dev/null; then
			log "WARN: server_ips atomic swap failed; retrying"
			if ! nft -f "$_swap_tmp" 2>/dev/null; then
				local _disk_ips=""
				[ -f /etc/surflare/server_ips ] && \
					_disk_ips=$(tr -s ' \t\n' ',' < /etc/surflare/server_ips)
				if [ -n "$_disk_ips" ] && \
				   nft -f - 2>/dev/null << DISKEOF
flush set inet killswitch server_ips
add element inet killswitch server_ips { $_disk_ips }
DISKEOF
				then
					log "WARN: server_ips swap-in failed; restored from disk backup"
				else
					log "CRITICAL: server_ips swap-in failed, disk restore failed; killswitch server_ips is EMPTY"
				fi
			fi
		fi
		rm -f "$_swap_tmp"
		nft delete table inet killswitch_swap 2>/dev/null || true
	else
		log "WARN: killswitch server_ips scratch build failed; keeping previous set"
		nft delete table inet killswitch_swap 2>/dev/null || true
	fi
	rm -f "$_ks_tmp"
	# F8: persist the current node's server IPs to disk so a watchdog
	# restart (e.g. crash + procd respawn) can re-apply the killswitch
	# with the correct allow-list even before the next diagnostic run
	# refreshes _diag_server_ips.
	local _persist_v4="/etc/surflare/server_ips"
	if [ -n "$_diag_server_ips" ]; then
		echo "$_diag_server_ips" > "$_persist_v4" 2>/dev/null || \
			log "WARN: failed to persist server_ips to $_persist_v4"
	fi
	log "Kill switch: server_ips updated (${_diag_server_ips})"
}

# Unused: cleanup() uses modular teardown (flush server_ips, keep table),
# stop_service() uses _full_teardown (delete table).  Retained for manual
# emergency use: source this file and call _remove_killswitch.
_remove_killswitch() {
	nft delete table inet killswitch 2>/dev/null || true
}

# Replace the tproxy redirect rule with a reject so LAN TCP gets fast ICMP
# failure instead of black-holing into a dead proxy or leaking via direct
# forwarding.  Idempotent: safe to call when tproxy is already tombstoned
# or the table does not exist.  Leaves bypass_devices/auto_bypass sets and
# the DTLS detection rule intact so they survive across the tombstone window.
_tombstone_tproxy() {
	nft list table inet sw_lan_tproxy >/dev/null 2>&1 || return 0
	# Load CN IPs into cn_direct so domestic traffic bypasses tproxy
	# during the tombstone window.  In rule mode cn_direct is normally
	# empty (sing-box handles CN split); during tombstone sing-box is
	# dead so we must route CN direct at the nftables layer.
	# _restore_tproxy() recreates cn_direct as empty (destroy+reload),
	# returning to normal rule-mode behavior automatically.
	_load_tproxy_cn_direct force
	# Replace each tproxy rule with a protocol-matched reject so only
	# the originally proxied protocols are blocked.  Without the qualifier
	# the first reject catches ALL br-lan traffic and over-blocks
	# non-TCP/non-QUIC flows (e.g. UDP game traffic to CN IPs).
	local _line _handle _replaced=0
	while IFS= read -r _line; do
		[ -z "$_line" ] && continue
		_handle=${_line##* }
		if echo "$_line" | grep -q 'meta l4proto tcp'; then
			nft replace rule inet sw_lan_tproxy prerouting handle "$_handle" \
				iifname "br-lan" meta l4proto tcp \
				reject with tcp reset 2>/dev/null && \
				_replaced=$((_replaced + 1))
		elif echo "$_line" | grep -q 'udp dport 443'; then
			nft replace rule inet sw_lan_tproxy prerouting handle "$_handle" \
				iifname "br-lan" udp dport 443 \
				reject 2>/dev/null && \
				_replaced=$((_replaced + 1))
		else
			nft replace rule inet sw_lan_tproxy prerouting handle "$_handle" \
				iifname "br-lan" reject \
				2>/dev/null && _replaced=$((_replaced + 1))
		fi
	done <<EOF
$(nft -a list chain inet sw_lan_tproxy prerouting 2>/dev/null | grep 'tproxy.*10800')
EOF
	[ "$_replaced" -gt 0 ] && log "Tombstone: ${_replaced} tproxy rule(s) replaced with REJECT"
	# No tproxy rule found means already tombstoned or manually removed;
	# keep the table (bypass sets, DTLS detection) intact either way.
}

# Restore tproxy from a tombstoned or missing state by reloading the
# deployed nft file.  This is simpler and more robust than per-handle
# replacement: tombstoned rules lose their original protocol/port
# qualifiers, so a fresh load from the authoritative file is the only
# way to guarantee correct rule content.
# Case (a): table exists (tombstoned or partial) -> destroy + reload.
# Case (b): table missing entirely (first boot) -> load.
# Case (c): table exists with live tproxy -> reload is idempotent
#           (destroy + recreate with same content).
_restore_tproxy() {
	local _lan_tproxy_nft="/etc/surflare-lan-tproxy.nft"
	if [ ! -f "$_lan_tproxy_nft" ]; then
		log "WARN: $_lan_tproxy_nft not found, cannot restore tproxy"
		return 1
	fi
	# Snapshot bypass sets before destroy so they survive the reload.
	# _update_bypass_devices overwrites these on the next connect.
	local _saved_bypass _saved_auto _saved_bypass6
	_saved_bypass=$(nft list set inet sw_lan_tproxy bypass_devices 2>/dev/null \
		| grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr '\n' ',' | sed 's/,$//')
	_saved_bypass6=$(nft list set inet sw_lan_tproxy bypass_devices6 2>/dev/null \
		| grep -oE '[0-9a-f:]+:[0-9a-f:]+' | grep -v '^fe80' | tr '\n' ',' | sed 's/,$//')
	_saved_auto=$(nft list set inet sw_lan_tproxy auto_bypass 2>/dev/null \
		| grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr '\n' ',' | sed 's/,$//')
	# Prepend destroy so the load is atomic: old table removed and new
	# table created in one nft -f transaction.
	local _restore_tmp="/tmp/tproxy_restore_$$.nft"
	{
		printf 'destroy table inet sw_lan_tproxy\n'
		cat "$_lan_tproxy_nft"
	} > "$_restore_tmp"
	local _nft_err _load_ok=0
	if _nft_err=$(nft -f "$_restore_tmp" 2>&1); then
		log "LAN tproxy restored (fresh load from ${_lan_tproxy_nft})"
		_load_ok=1
	else
		log "WARN: LAN tproxy restore failed: ${_nft_err}"
	fi
	rm -f "$_restore_tmp"
	# Sentinel: verify tproxy table exists after load
	if ! nft list table inet sw_lan_tproxy >/dev/null 2>&1; then
		log "CRITICAL: tproxy restore failed -- table missing after nft -f"
		return 1
	fi
	# Restore saved bypass IPs immediately to close the rebuild gap.
	# _update_bypass_devices will overwrite these on the next connect,
	# but until then bypass devices keep their exemption.
	if [ -n "$_saved_bypass" ]; then
		nft add element inet sw_lan_tproxy bypass_devices \
			"{ $_saved_bypass }" 2>/dev/null || true
	fi
	if [ -n "$_saved_bypass6" ]; then
		nft add element inet sw_lan_tproxy bypass_devices6 \
			"{ $_saved_bypass6 }" 2>/dev/null || true
	fi
	if [ -n "$_saved_auto" ]; then
		nft add element inet sw_lan_tproxy auto_bypass \
			"{ $_saved_auto }" 2>/dev/null || true
	fi
	# Reload CN CIDRs: destroy+reload above empties cn_direct/cn6_direct.
	# Without this, all LAN traffic goes through VPN proxy (no CN bypass).
	_load_tproxy_cn_direct
	# Stamp the nft file hash so adopt can detect stale rules without
	# rebuilding the table every restart.  Only stamp on successful
	# load (_load_ok): a failed nft -f leaves stale rules, and stamping
	# would make the adopt guard think rules are current.
	if [ "$_load_ok" -eq 1 ] && command -v md5sum >/dev/null 2>&1; then
		md5sum "$_lan_tproxy_nft" > "$TPROXY_NFT_STAMP" 2>/dev/null
	fi
}

# Enter storm-protection cooldown. Called from the three storm trigger
# sites (post-crash, post-reconnect, connect failure) which previously
# duplicated the same ~12 lines. The reason string is logged for forensic
# clarity -- it identifies which storm path actually triggered.
_enter_storm_cooldown() {
	local _reason="$1"
	_healthy_consecutive=0
	stop_packet_trace >/dev/null 2>&1
	_remove_dns_fallback
	log "Storm protection triggered (${_reason}): cooling for ${STORM_COOLING}s"
	_send_alert "VPN storm cooldown" "reason=${_reason} reconnects=${reconnect_count}"
	# Phase 2A: Tombstone mode -- keep killswitch alive (CN bypass stays),
	# replace tproxy with REJECT (no TCP black-hole, no IP leak), flush
	# server_ips so VPN server traffic is also blocked.
	#
	# Before v64: deleted tproxy + killswitch -> 600s IP leak window.
	# Tombstone: killswitch stays armed, overseas gets REJECT (fast fail).
	_tombstone_tproxy
	# Persist server_ips to tmpfs before flushing; _update_killswitch_server_ips
	# reads this as a fallback after cooldown.
	local _persist_v4="/run/surflare_watchdog.server_ips_v4"
	if [ -n "$_diag_server_ips" ]; then
		echo "$_diag_server_ips" > "$_persist_v4" 2>/dev/null || true
	fi
	# Flush server_ips so VPN server traffic is also blocked by killswitch
	nft flush set inet killswitch server_ips 2>/dev/null || true
	nft flush set inet killswitch server_ips6 2>/dev/null || true
	# Keep killswitch armed -- DO NOT call _remove_killswitch
	# F13: persist cool-until so a watchdog restart mid-cool respects
	# the remaining window.
	_cool_target=$(( $(date +%s) + STORM_COOLING ))
	echo "$_cool_target" > /run/surflare_watchdog.storm_cool_until
	# Sub-loop: run lightweight probes every 60s during cooldown.
	# storm_sleep_pid set per iteration so cleanup() can SIGTERM the
	# current sleep. USR1 breaks out via run_health_check_now flag.
	local _storm_probe_interval=60
	local _storm_remaining=$STORM_COOLING
	local _storm_sleep _storm_dup _spid _storm_mem
	while [ "$_storm_remaining" -gt 0 ]; do
		_storm_sleep=$(( _storm_remaining < _storm_probe_interval ? _storm_remaining : _storm_probe_interval ))
		sleep "$_storm_sleep" &
		storm_sleep_pid=$!; wait "$storm_sleep_pid"; storm_sleep_pid=""
		_storm_remaining=$(( _storm_remaining - _storm_sleep ))
		[ "$run_health_check_now" = 1 ] && break
		if [ "$_storm_remaining" -gt 0 ]; then
			_storm_dup=0
			for _spid in $(pgrep -f 'surflare_watchdog\.sh$' 2>/dev/null); do
				[ "$_spid" -eq "$$" ] && continue
				# Only count procd-started instances (PPid=1), not
				# our own child subshells (PPid=$$)
				grep -q "PPid:.*1$" "/proc/$_spid/status" 2>/dev/null || continue
				_storm_dup=$((_storm_dup + 1))
			done
			[ "$_storm_dup" -gt 0 ] && log "WARN: ${_storm_dup} duplicate watchdog(s) during storm cooldown"
			_storm_mem=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
			[ "${_storm_mem:-0}" -lt 500000 ] && log "WARN: low memory during storm cooldown: ${_storm_mem}kB available"
		fi
	done
	# Only reset counters if cooldown actually elapsed (not interrupted by USR1)
	local _now
	_now=$(date +%s)
	if [ "$_now" -ge "$_cool_target" ] 2>/dev/null; then
		reconnect_count=0
		fail_count=0
		transient_count=0
		_cn_consecutive=0
		_transit_grace_ts=0
		FAIL_THRESHOLD=$FAIL_THRESHOLD_BASE
	else
		log "Storm cooldown interrupted early, counters not reset"
	fi
	# Restore tproxy after cooldown (normal or interrupted).  Without
	# this, a passing health check leaves tproxy tombstoned forever
	# because the probes bypass tproxy and can succeed while LAN
	# devices are blocked by the REJECT rules.  If routing is also
	# broken, the next health check detects PROXY_BROKEN and triggers
	# a proper reconnect with full routing rebuild.
	_restore_tproxy
}

# Populate the bypass_devices set in sw_lan_tproxy.
# Sources (both are checked, results merged):
#   1. BYPASS_LAN_DEVICES: explicit space-separated IPs
#   2. BYPASS_LAN_MACS_FILE: one MAC per line; IP resolved from dhcp.leases
#
# Configure MACs in /etc/surflare/bypass-macs.conf (bypass-macs.conf.example).
# The MAC-based path re-resolves IPs on every VPN connect, so devices work
# regardless of DHCP reassignment.
_update_bypass_devices() {
	nft list table inet sw_lan_tproxy >/dev/null 2>&1 || return 0
	nft flush set inet sw_lan_tproxy bypass_devices 2>/dev/null || true

	local all_ips="" ip_csv mac ip line
	# Source 1: explicit IPs
	if [ -n "$BYPASS_LAN_DEVICES" ]; then
		ip_csv=$(echo "$BYPASS_LAN_DEVICES" | xargs | tr ' ' ',')
		[ -n "$ip_csv" ] && all_ips="$ip_csv"
	fi
	# Source 2: MACs from file, resolved via dhcp.leases
	if [ -f "$BYPASS_LAN_MACS_FILE" ] && [ -f /tmp/dhcp.leases ]; then
		while IFS= read -r line; do
			mac=$(echo "$line" | awk '{print tolower($1)}' | tr -d '\r')
			case "$mac" in '#'*|'') continue ;; esac
			ip=$(awk -v m="$mac" 'tolower($2)==m{print $3;exit}' /tmp/dhcp.leases)
			[ -n "$ip" ] && all_ips="${all_ips:+$all_ips,}$ip"
		done < "$BYPASS_LAN_MACS_FILE"
	fi
	# IPv6: resolve bypass MACs to GUA addresses via neighbor table.
	# Link-local (fe80::) excluded: tproxy only matches routable addresses.
	local all_v6=""
	if [ -f "$BYPASS_LAN_MACS_FILE" ]; then
		while IFS= read -r line; do
			mac=$(echo "$line" | awk '{print tolower($1)}' | tr -d '\r')
			case "$mac" in '#'*|'') continue ;; esac
			local _v6
			_v6=$(ip -6 neigh show dev br-lan 2>/dev/null \
				| awk -v m="$mac" 'tolower($5)==tolower(m) && $1!~/^fe80/ {print $1}')
			[ -n "$_v6" ] && all_v6="${all_v6:+$all_v6,}$(echo "$_v6" | tr '\n' ',' | sed 's/,$//')"
		done < "$BYPASS_LAN_MACS_FILE"
	fi
	# Flush + repopulate bypass_devices6 (atomic: empty is valid when no IPv6 neighbors)
	nft flush set inet sw_lan_tproxy bypass_devices6 2>/dev/null || true
	if [ -n "$all_v6" ]; then
		nft add element inet sw_lan_tproxy bypass_devices6 "{ $all_v6 }" 2>/dev/null || \
			log "WARN: bypass_devices6 update failed (${all_v6})"
	fi

	if [ -z "$all_ips" ] && [ -z "$all_v6" ]; then
		# No bypass devices: sync auto_bypass only to killswitch bypass_src
		# and dns_enforce vpn_bypass.  Without this, stale device IPs from
		# a previous connect cycle remain in bypass_src after DHCP change.
		if nft list table inet killswitch >/dev/null 2>&1; then
			local _auto_ips
			_auto_ips=$(nft list set inet sw_lan_tproxy auto_bypass 2>/dev/null \
				| grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | paste -sd,)
			{
				printf 'flush set inet killswitch bypass_src\n'
				printf 'flush set inet killswitch bypass_src6\n'
				[ -n "$_auto_ips" ] && \
					printf 'add element inet killswitch bypass_src { %s }\n' "$_auto_ips"
			} | nft -f - 2>/dev/null || true
		fi
		_sync_dns_enforce_bypass
		return 0
	fi
	# Deduplicate in case same IP appears in both BYPASS_LAN_DEVICES and MAC file
	if [ -n "$all_ips" ]; then
		all_ips=$(echo "$all_ips" | tr ',' '\n' | sort -u | paste -sd,)
		nft add element inet sw_lan_tproxy bypass_devices "{ $all_ips }" 2>/dev/null || \
			log "WARN: bypass_devices update failed (${all_ips})"
	fi
	# Sync bypass device IPs + auto_bypass IPs into killswitch bypass_src
	# so their non-CN traffic is accepted (not rejected/logged).
	# Atomic flush+add via nft -f: bypass_src is never empty mid-update.
	if nft list table inet killswitch >/dev/null 2>&1; then
		local _auto_ips
		_auto_ips=$(nft list set inet sw_lan_tproxy auto_bypass 2>/dev/null \
			| grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | paste -sd,)
		local _all_bypass=""
		[ -n "$all_ips" ] && _all_bypass="$all_ips"
		if [ -n "$_auto_ips" ]; then
			_all_bypass="${_all_bypass:+$_all_bypass,}$_auto_ips"
		fi
		{
			printf 'flush set inet killswitch bypass_src\n'
			[ -n "$_all_bypass" ] && \
				printf 'add element inet killswitch bypass_src { %s }\n' "$_all_bypass"
		} | nft -f - 2>/dev/null || \
			log "WARN: killswitch bypass_src atomic sync failed"
		# IPv6: sync bypass_devices6 to killswitch bypass_src6
		{
			printf 'flush set inet killswitch bypass_src6\n'
			[ -n "$all_v6" ] && \
				printf 'add element inet killswitch bypass_src6 { %s }\n' "$all_v6"
		} | nft -f - 2>/dev/null || true
	fi
	_sync_dns_enforce_bypass
}

# Sync auto_bypass + bypass_devices IPs to dns_enforce vpn_bypass set.
# Devices running their own VPN use non-router DNS; without this exemption,
# dns_enforce rejects their DNS queries and breaks their connectivity.
# Called after _update_bypass_devices and periodically from the main loop
# (auto_bypass is kernel-managed with 5m timeout, new devices can appear
# between reconnects).
_sync_dns_enforce_bypass() {
	local _dns_ips="" _static _auto
	_static=$(nft list set inet sw_lan_tproxy bypass_devices 2>/dev/null \
		| grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | paste -sd,)
	[ -n "$_static" ] && _dns_ips="$_static"
	_auto=$(nft list set inet sw_lan_tproxy auto_bypass 2>/dev/null \
		| grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | paste -sd,)
	[ -n "$_auto" ] && _dns_ips="${_dns_ips:+$_dns_ips,}$_auto"
	_dns_ips=$(echo "$_dns_ips" | tr ',' '\n' | sort -u | paste -sd,)

	# Sync to dns_enforce vpn_bypass (DNS exemption for VPN devices).
	# Atomic flush+add via nft -f to avoid a window where bypass devices'
	# DNS queries are rejected between the flush and the add.
	if nft list table ip dns_enforce >/dev/null 2>&1; then
		{
			printf 'flush set ip dns_enforce vpn_bypass\n'
			[ -n "$_dns_ips" ] && \
				printf 'add element ip dns_enforce vpn_bypass { %s }\n' "$_dns_ips"
		} | nft -f - 2>/dev/null || \
			log "WARN: dns_enforce vpn_bypass sync failed"
	fi

	# Sync auto_bypass IPs to killswitch bypass_src so the forward chain
	# reject rule does not block their non-CN traffic.  bypass_devices are
	# already in bypass_src via _update_bypass_devices; only auto_bypass
	# needs periodic re-sync here (devices join/leave on 5-min timeout).
	if [ -n "$_auto" ] && nft list table inet killswitch >/dev/null 2>&1; then
		nft add element inet killswitch bypass_src "{ $_auto }" 2>/dev/null || true
	fi
}


CONTROL_PROBE_TARGETS="114.114.114.114:53 223.5.5.5:53"
CONTROL_PROBE_TIMEOUT=3

# _route_updater_active: returns 0 (true) when surflare_route_updater.sh is
# in its bulk-download phase (lock file present and < 30 min old).
# Lock path must match ROUTE_UPDATER_LOCK in surflare_route_updater.sh.
#
# Suppression is unconditional during the window: _control_probe bypasses the
# proxy (SO_MARK=0xff) and cannot distinguish "proxy saturated, VPN alive"
# from "proxy busy, VPN dead".  Worst case: a real VPN outage goes undetected
# until the download window closes (< 30 min in practice).
# Stale lock (SIGKILL): age > 1800 s check prevents permanent suppression.
# Also check the updater PID is alive: a SIGKILLed updater leaves a stale
# lock even with the heartbeat (heartbeat itself can be killed).  If the
# process is gone, treat as inactive regardless of mtime.
_route_updater_active() {
    local lock="/run/surflare_route_updater.lock"
    [ -f "$lock" ] || return 1
    _proc_alive surflare_route_updater >/dev/null 2>&1 || return 1
    local mtime age
    mtime=$(stat -c '%Y' "$lock" 2>/dev/null) || return 1
    age=$(( $(date +%s) - mtime ))
    # NTP clock step can make age negative; treat as inactive (not active) then.
    [ "$age" -ge 0 ] && [ "$age" -lt 1800 ]
}

_control_probe() {
	local target ip port
	for target in $CONTROL_PROBE_TARGETS; do
		IFS=: read -r ip port <<< "$target"
		if timeout $((CONTROL_PROBE_TIMEOUT + 1)) python3 -c "
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET,socket.SO_MARK,0xff)
s.settimeout($CONTROL_PROBE_TIMEOUT)
rc=1
try:
 s.connect(('$ip',$port))
 rc=0
except Exception:
 pass
finally:
 s.close()
raise SystemExit(rc)
" 2>/dev/null; then
			return 0
		fi
	done
	return 1
}

compute_proxy_affinity() {
	local total proxy_count first_proxy
	total=$(grep -c '^processor' /proc/cpuinfo)
	if [ "$total" -le 2 ]; then
		PROXY_CPU_SET=""
		DESKTOP_CPU_SET=""
		return
	elif [ "$total" -le 4 ]; then
		proxy_count=1
	elif [ "$total" -le 8 ]; then
		proxy_count=2
	elif [ "$total" -le 16 ]; then
		proxy_count=4
	else
		proxy_count=6
	fi
	first_proxy=$((total - proxy_count))
	PROXY_CPU_SET="${first_proxy}-$((total - 1))"
	DESKTOP_CPU_SET="0-$((first_proxy - 1))"
}

recent_wifi_crash() {
	local window="${1:-120}"
	local now since_ts
	now=$(date +%s)
	since_ts=$((now - window))
	{
		timeout 3 journalctl -k --since "@${since_ts}" --no-pager -q 2>/dev/null || true
		timeout 3 dmesg --since "@${since_ts}" 2>/dev/null || true
	} | grep -qE "Hardware restart was requested|NMI_INTERRUPT_UNKNOWN"
}

_classify_timeout() {
	# Parse curl timing fields and log which network phase stalled.
	# Args: $1=label  $2=timing_string (dns:tcp:tls:ttfb:total)
	local label="$1" timing="$2"
	local dns tcp tls ttfb
	IFS=: read -r dns tcp tls ttfb _ <<< "$timing"
	# shellcheck disable=SC2195  # intentional: match non-numeric
	case "$dns.$tcp.$tls.$ttfb" in
		(*[!0-9.]|.|*..*) return ;;
	esac
	local stuck="unknown"
	# Priority: TCP > TLS > TTFB.  Once classified, stop.
	# Pure bash arithmetic -- no fork per check.
	if [ "${tcp%.*}" -gt 0 ] 2>/dev/null && [ "${tls%.*}" -le 0 ] 2>/dev/null; then
		stuck="TCP"
	elif [ "${dns%.*}" -gt 0 ] 2>/dev/null && [ "${tcp%.*}" -le 0 ] 2>/dev/null; then
		stuck="TCP"
	elif [ "${tls%.*}" -gt 0 ] 2>/dev/null && [ "${ttfb%.*}" -le 0 ] 2>/dev/null; then
		stuck="TLS"
	elif [ "${ttfb%.*}" -gt 0 ] 2>/dev/null; then
		stuck="TTFB"
	fi
	log "probe timeout ${label}: dns=${dns} tcp=${tcp} tls=${tls} ttfb=${ttfb} stuck=${stuck}"
	echo "$stuck"  # return value: callers must use $() to capture
}

_crash_timestamps=""

record_crash() {
	local now last=0
	now=$(date +%s)
	local window_start=$((now - CRASH_WINDOW))
	local pruned=""
	for ts in $_crash_timestamps; do
		if [ "$ts" -ge "$window_start" ]; then
			pruned="${pruned:+$pruned }${ts}"
			[ "$ts" -gt "$last" ] && last="$ts"
		fi
	done
	_crash_timestamps="$pruned"
	if [ "$last" -gt 0 ] && [ "$((now - last))" -lt "$CRASH_DEDUP_INTERVAL" ]; then
		return
	fi
	_crash_timestamps="${_crash_timestamps:+$_crash_timestamps }${now}"
}

crash_rate_exceeded() {
	local now window_start count
	now=$(date +%s)
	window_start=$((now - CRASH_WINDOW))
	count=0
	local new_ts=""
	for ts in $_crash_timestamps; do
		if [ "$ts" -ge "$window_start" ]; then
			count=$((count + 1))
			new_ts="${new_ts:+$new_ts }${ts}"
		fi
	done
	_crash_timestamps="$new_ts"
	[ "$count" -ge "$CRASH_MAX_PER_WINDOW" ]
}

# _get_isp_ip: retrieve and cache the ISP public IP address.
# This IP is used as a baseline to distinguish between:
# 1. Tunnel broken (exit IP == ISP IP): traffic leaked direct
# 2. Tunnel working but exit in CN (exit IP != ISP IP): not a failure
# Must be called BEFORE VPN connects (traffic goes direct to ISP).
_get_isp_ip() {
	local _cached_ip _cache_age _now

	# Try to load from cache file
	if [ -f "$ISP_IP_CACHE" ]; then
		_cached_ip=$(cat "$ISP_IP_CACHE" 2>/dev/null | head -1 | tr -d '[:space:]')
		_cache_age=$(( $(date +%s) - $(stat -c %Y "$ISP_IP_CACHE" 2>/dev/null || echo 0) ))
		if [ -n "$_cached_ip" ] && [ "$_cache_age" -lt "$ISP_IP_MAX_AGE" ]; then
			ISP_IP="$_cached_ip"
			log "ISP IP loaded from cache: ${ISP_IP} (${_cache_age}s old)"
			return 0
		fi
	fi

	# Cache expired or missing: fetch fresh IP.
	# On restart, killswitch may still be active from previous run.
	# Plain curl without mark 0xff gets blocked by ks-drop.
	if nft list table inet killswitch >/dev/null 2>&1; then
		log "WARN: killswitch active, ISP IP fetch skipped (using cache only)"
		return 1
	fi
	local _targets="https://icanhazip.com https://ifconfig.me https://api.ipify.org"
	local _attempt _url _ip
	for _attempt in 1 2 3; do
		for _url in $_targets; do
			_ip=$(curl -s --connect-timeout 5 --max-time 10 "$_url" 2>/dev/null | tr -d '[:space:]')
			# Validate: must be a valid IPv4 address
			if [[ "$_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
				ISP_IP="$_ip"
				# Persist to cache file
				mkdir -p "$(dirname "$ISP_IP_CACHE")" 2>/dev/null || true
				echo "$ISP_IP" > "$ISP_IP_CACHE" 2>/dev/null || true
				log "ISP IP fetched and cached: ${ISP_IP}"
				return 0
			fi
		done
		[ "$_attempt" -lt 3 ] && sleep 2
	done

	log "WARN: failed to fetch ISP IP after 3 attempts"
	return 1
}

# _is_isp_ip: check if an IP matches the cached ISP IP.
# Returns 0 if IP matches ISP IP (tunnel broken), 1 otherwise.
_is_isp_ip() {
	local _check_ip="$1"
	[ -n "$ISP_IP" ] && [ "$_check_ip" = "$ISP_IP" ]
}

# _health_is_failure: return 0 if the health result indicates a failure state.
# Centralizes the failure-state check used in multiple main-loop branches.
# CN exit: ISP IP baseline check is done in check_vpn_health() at detection time.
_health_is_failure() {
	case "$1" in
		CN|LOCAL_FAIL|TCP_BLOCK|PROXY_BROKEN) return 0 ;;
	esac
	return 1
}

# Helper: check if nft table exists (returns "yes" or "no")
_table_exists() {
	# Try inet first (most tables), then ip (dns_enforce uses ip family)
	nft list table inet "$1" >/dev/null 2>&1 && echo "yes" && return
	nft list table ip "$1" >/dev/null 2>&1 && echo "yes" && return
	echo "no"
}

# _check_fw4_health: verify the OpenWrt fw4/firewall service is providing
# masquerade for pppoe-wan egress. LAN-client traffic that gets correctly
# CN-bypassed in sw_lan_tproxy (skips tproxy/sing-box entirely, by design)
# is forwarded via the kernel's normal routing path with its source address
# unchanged. It depends on fw4's masquerade to rewrite that to N100's own
# WAN address. Without it, replies from the CN destination route to the
# private LAN source IP and never arrive; every such connection times out,
# while VPN-routed traffic (which sing-box originates itself) is unaffected.
# fw4 restarts are a normal, hotplug-triggered event on this router (see
# the bypass_devices repopulation comment elsewhere in this script) that
# this watchdog otherwise has no visibility into, so a failed restart can
# leave NAT silently missing until someone notices manually.
# Router-only: a laptop deployment does not gateway/forward for other
# devices, so masquerade does not apply.
# Coupled to fw4's internal srcnat_wan chain name (current fw4 generates
# this from the standard `oifname {...} jump srcnat_wan` wan-zone rule,
# verified live on N100). Accepted tradeoff: a future fw4 rename of this
# chain would need this check updated too, same as any other place in
# this script that names an fw4/nft chain directly.
# No separate existence check before the grep: if the table/chain is
# missing entirely, `nft list` fails and the pipeline sees empty input,
# so `grep -q masquerade` correctly returns 1 (unhealthy), which is the
# intended result since a router deployment always expects fw4 present.
_check_fw4_health() {
	[ "$PLATFORM" = "laptop" ] && return 0
	nft list chain inet fw4 srcnat_wan 2>/dev/null | grep -q masquerade
}

# _recover_fw4: restart fw4 when _check_fw4_health fails. Rate-limited via
# FW4_RESTART_COOLDOWN so a persistently broken fw4 (or a restart that
# itself fails) cannot retry every check interval. This cooldown gates the
# restart ACTION; _send_alert has its own separate 600s throttle on the
# alert itself.
_recover_fw4() {
	local _now _diff
	_now=$(date +%s)
	_diff=$((_now - ${_fw4_last_restart_ts:-0}))
	# _diff can go negative if the clock jumps backward (no RTC, pre-NTP
	# boot); treat that the same as "cooldown expired" rather than let a
	# negative number satisfy -lt and block the first restart forever.
	# Matches the same guard in _send_alert's own rate limiter.
	if [ "$_diff" -ge 0 ] && [ "$_diff" -lt "$FW4_RESTART_COOLDOWN" ]; then
		log "fw4 unhealthy but restart cooldown active, skipping"
		return 1
	fi
	_fw4_last_restart_ts=$_now
	log "WARN: fw4 masquerade missing, attempting reload"
	# Reload refreshes fw4's own table without flushing the entire
	# nftables ruleset. A full restart flushes surflare/sw_lan_tproxy
	# tables, breaking VPN until the watchdog reconnects (~60s outage).
	if timeout 20 /etc/init.d/firewall reload >/dev/null 2>&1 && _check_fw4_health; then
		log "fw4 reload recovered masquerade"
		_send_alert "surflare: fw4 auto-recovered" "fw4/masquerade was missing and has been reloaded automatically."
		return 0
	fi
	# Fallback: full restart if reload failed (e.g. fw4 table gone).
	# This flushes the entire ruleset; watchdog self-healing recovers VPN.
	log "fw4 reload did not recover masquerade, attempting full restart"
	if timeout 20 /etc/init.d/firewall restart >/dev/null 2>&1 && _check_fw4_health; then
		log "fw4 restart recovered masquerade"
		_send_alert "surflare: fw4 auto-recovered" "fw4/masquerade was missing and has been restarted automatically."
		return 0
	fi
	log "ERROR: fw4 restart did not recover masquerade"
	_send_alert "surflare: fw4 DOWN" "fw4/masquerade missing and automatic restart failed. Manual check needed: /etc/init.d/firewall restart"
	return 1
}

# _block_unreachable_doh: reject DoH to servers unreachable from this network.
# N100 CGNAT: 1.1.1.1/8.8.8.8 are GFW-blocked (SYN blackholed, 10s timeout).
# surflare-proxy tries DoH in order 1.1.1.1 -> 8.8.8.8 -> 223.5.5.5; the
# two blocked IPs waste 20s before fallback, causing DNS failures and 503.
# nft insert (not add) places the reject BEFORE the mark-0xff accept rule
# so the proxy gets instant ECONNREFUSED and falls back in <1ms.
# Scoped to tcp dport 443 (DoH only); UDP 53 and DoT 853 are unaffected.
_block_unreachable_doh() {
	nft list table inet surflare >/dev/null 2>&1 || return 0
	[ "$PLATFORM" = "laptop" ] && return 0
	# Dedup: skip if reject rule already present (multiple call sites)
	nft list chain inet surflare output 2>/dev/null | \
		grep -q '1.1.1.1.*reject' && return 0
	nft insert rule inet surflare output \
		ip daddr '{ 1.1.1.1, 1.0.0.1, 8.8.8.8, 8.8.4.4 }' tcp dport 443 reject \
		2>/dev/null || true
}
# _exempt_cn_output: load all CN IPv4 CIDRs into an nftables set and insert
# an accept rule before the output chain catchall so N100-local traffic to
# CN IPs never enters tproxy.  Replaces the narrower _exempt_local_dns_servers
# which only covered 4 hard-coded DNS IPs on ports 443/853.
# The output chain is type-route: changing mark triggers kernel reroute.
# Without this exemption, locally-generated CN traffic is marked 0x1 by the
# catchall -> rerouted to lo -> tproxy:10800 -> sing-box may reject it as
# loopback (source 100.65.183.92 is a local WAN address).
# Called after every successful connect_vpn (table is freshly created).
# Idempotent: dedup check returns early if the set already has elements.
_exempt_cn_output() {
	nft list table inet surflare >/dev/null 2>&1 || return 0
	[ "$PLATFORM" = "laptop" ] && return 0
	# Dedup: skip if set already has elements (persists across crashes)
	nft list set inet surflare cn_output 2>/dev/null | \
		grep -q 'elements' && return 0

	local cn_v4_file="/etc/surflare/cn_ipv4.txt"
	local _batch="/tmp/surflare_cn_output_$$.nft"

	# Create the interval set (idempotent)
	nft add set inet surflare cn_output '{ type ipv4_addr; flags interval; }' \
		2>/dev/null || true

	# Batch-load all CIDRs from cn_ipv4.txt
	if [ -f "$cn_v4_file" ]; then
		local _v4_cidrs
		_v4_cidrs=$(grep -v '^#' "$cn_v4_file" | grep -v '^[[:space:]]*$' | paste -sd, -)
		if [ -n "$_v4_cidrs" ]; then
			{
				printf 'flush set inet surflare cn_output\n'
				printf 'add element inet surflare cn_output { %s }\n' "$_v4_cidrs"
			} > "$_batch"
			nft -f "$_batch" 2>/dev/null || \
				log "WARN: cn_output set load failed"
			rm -f "$_batch"
		else
			log "WARN: ${cn_v4_file} has no valid CIDRs"
			rm -f "$_batch"
			return 0
		fi
	else
		log "WARN: ${cn_v4_file} missing, cn_output will be empty"
		return 0
	fi

	# Insert accept rule at chain head (before catchall).  Dedup: skip if
	# a rule referencing @cn_output already exists.
	nft list chain inet surflare output 2>/dev/null | \
		grep -q 'daddr @cn_output ' && return 0
	nft insert rule inet surflare output \
		ip daddr @cn_output accept \
		2>/dev/null || true
}
# _check_tunnel_egress: test whether the VPN tunnel can reach external endpoints.
# Tests OUTPUT -> mark 0x1 -> VPN path (locally originated traffic).
# Does NOT test surflare-proxy:10800 tproxy path (port 10800 is a tproxy
# listener, not SOCKS5; localhost connections trigger sing-box loopback reject).
# Returns 0 if tunnel works, 1 if broken.  Called after primary health check
# succeeds to detect the blind spot where the tunnel is up but egress is dead.
_check_tunnel_egress() {
	# Uses multiple targets with retry to avoid false positives from
	# transient CDN routing issues (gstatic.com PoP instability observed).
	local _targets="https://connectivitycheck.gstatic.com/generate_204 https://ifconfig.me https://icanhazip.com"
	local _attempt _url _code
	for _attempt in 1 2; do
		for _url in $_targets; do
			_code=$(curl -s --connect-timeout 3 --max-time 8 \
			       -o /dev/null -w '%{http_code}' \
			       "$_url" 2>/dev/null)
			case "$_code" in 200|204) return 0 ;; esac
		done
		[ "$_attempt" -lt 2 ] && sleep 1
	done
	return 1
}

# check_vpn_health: two-layer check -- local state first, then parallel external probes.
# Returns:
#   "OK"           -- Google 200/30x AND proxy path works
#   "PROXY_BROKEN" -- tunnel OK but surflare-proxy:10800 not forwarding
#   "LOCAL_FAIL"   -- local VPN state lost (process/nftables/routing gone)
#   <country>      -- country probe returned a country code (non-empty)
#   ""             -- all external probes timed out (but local state was OK = transient)
# "CN" is a valid country code return (VPN up but routing via China = broken exit).
#
# Architecture: "first success wins" -- probes run in parallel; results are polled
# every 1s. As soon as any probe produces a usable result, remaining probes are
# killed and the result is returned immediately. This avoids waiting the full
# max-time when at least one probe succeeds quickly.
check_vpn_health() {
	echo 0 > "$DNS_STUCK_FILE" 2>/dev/null || true
	# Check bypass_ipv4 set health: if empty, CN exit detection degrades
	# to ISP IP comparison only (all IPs treated as non-CN by nft set).
	local _bypass_empty=0
	if ! nft list set inet killswitch bypass_ipv4 2>/dev/null | grep -q 'elements'; then
		_bypass_empty=1
		log "WARN: bypass_ipv4 set empty, CN exit detection using ISP IP fallback"
	fi
	# Layer 1: local state -- deterministic, milliseconds, no network dependency
	if ! check_vpn_local_state; then
		echo "LOCAL_FAIL"
		return
	fi

	# Layer 2: parallel external probes -- seven run concurrently, first success wins
	local tmp_g tmp_cf tmp_cf2 tmp_ifc tmp_ich tmp_myip tmp_proxy
	local tmp_gt tmp_cft tmp_cf2t tmp_ifct tmp_icht tmp_myt tmp_proxyt
	local pid_g pid_cf pid_cf2 pid_ifc pid_ich pid_myip pid_proxy
	tmp_g=$(mktemp /tmp/surflare_hc.XXXXXX)
	tmp_cf=$(mktemp /tmp/surflare_hc.XXXXXX)
	tmp_cf2=$(mktemp /tmp/surflare_hc.XXXXXX)
	tmp_ifc=$(mktemp /tmp/surflare_hc.XXXXXX)
	tmp_ich=$(mktemp /tmp/surflare_hc.XXXXXX)
	tmp_myip=$(mktemp /tmp/surflare_hc.XXXXXX)
	tmp_gt=$(mktemp /tmp/surflare_hc.XXXXXX)
	tmp_cft=$(mktemp /tmp/surflare_hc.XXXXXX)
	tmp_cf2t=$(mktemp /tmp/surflare_hc.XXXXXX)
	tmp_ifct=$(mktemp /tmp/surflare_hc.XXXXXX)
	tmp_icht=$(mktemp /tmp/surflare_hc.XXXXXX)
	tmp_myt=$(mktemp /tmp/surflare_hc.XXXXXX)
	tmp_proxy=$(mktemp /tmp/surflare_hc.XXXXXX)
	tmp_proxyt=$(mktemp /tmp/surflare_hc.XXXXXX)
	# Ensure temp files are removed even if this function is interrupted mid-wait.
	# Stored in a global so the main EXIT trap can also clean up on unclean exit.
	_hc_tmp="$tmp_g $tmp_cf $tmp_cf2 $tmp_ifc $tmp_ich $tmp_myip $tmp_proxy $tmp_gt $tmp_cft $tmp_cf2t $tmp_ifct $tmp_icht $tmp_myt $tmp_proxyt"

	# Probe 1: Google -- blocked externally -> 200/30x means VPN is working
	(
		local _raw
		_raw=$(curl -s --connect-timeout 5 --max-time 12 \
		       -o /dev/null \
		       -w '%{http_code}\n%{time_namelookup}:%{time_connect}:%{time_appconnect}:%{time_starttransfer}:%{time_total}' \
		       https://www.google.com 2>/dev/null)
		echo "$_raw" | tail -1 >"$tmp_gt"
		local code
		code=$(echo "$_raw" | head -1)
		case "$code" in 200|301|302) echo "OK" ;; esac
	) >"$tmp_g" 2>/dev/null 9>&- 200>&- &
	pid_g=$!

	# Probe 2: Cloudflare trace via domain (parse loc= field, no rate limit)
	(
		local _body
		_body=$(curl -s --connect-timeout 5 --max-time 12 \
		     -w '\n%{time_namelookup}:%{time_connect}:%{time_appconnect}:%{time_starttransfer}:%{time_total}' \
		     'https://cloudflare.com/cdn-cgi/trace' 2>/dev/null)
		echo "$_body" | tail -1 >"$tmp_cft"
		echo "$_body" | head -n -1 | awk -F= '/^loc=/{print $2}' | tr -d '[:space:]'
	) >"$tmp_cf" 2>/dev/null 9>&- 200>&- &
	pid_cf=$!

	# Probe 3: Cloudflare trace via IP 1.0.0.1 (skips DNS for cloudflare.com,
	# uses a different Cloudflare anycast edge -- may succeed when domain probe fails)
	(
		local _body
		_body=$(curl -s --connect-timeout 5 --max-time 12 \
		     -w '\n%{time_namelookup}:%{time_connect}:%{time_appconnect}:%{time_starttransfer}:%{time_total}' \
		     'https://1.0.0.1/cdn-cgi/trace' 2>/dev/null)
		echo "$_body" | tail -1 >"$tmp_cf2t"
		echo "$_body" | head -n -1 | awk -F= '/^loc=/{print $2}' | tr -d '[:space:]'
	) >"$tmp_cf2" 2>/dev/null 9>&- 200>&- &
	pid_cf2=$!

	# Probe 4: ifconfig.co ISO country code (degrades gracefully on rate limit)
	(
		local _body
		_body=$(curl -s --connect-timeout 5 --max-time 12 \
		     -w '\n%{time_namelookup}:%{time_connect}:%{time_appconnect}:%{time_starttransfer}:%{time_total}' \
		     'https://ifconfig.co/country-iso' 2>/dev/null)
		echo "$_body" | tail -1 >"$tmp_ifct"
		echo "$_body" | head -n -1 | tr -d '[:space:]'
	) >"$tmp_ifc" 2>/dev/null 9>&- 200>&- &
	pid_ifc=$!

	# Probe 5: icanhazip.com (Cloudflare-backed, tiny response -- returns raw IP only).
	# Cannot determine country directly, but a non-empty response from a externally blocked
	# CDN proves the tunnel is routing correctly. Caller uses the IP to infer status.
	(
		local ip _body
		_body=$(curl -s --connect-timeout 5 --max-time 12 \
		     -w '\n%{time_namelookup}:%{time_connect}:%{time_appconnect}:%{time_starttransfer}:%{time_total}' \
		     'https://icanhazip.com' 2>/dev/null)
		echo "$_body" | tail -1 >"$tmp_icht"
		ip=$(echo "$_body" | head -n -1 | tr -d '[:space:]')
		# Validate: must look like an IP (v4 or v6), not an error page
		if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$ip" =~ :.*: ]]; then
			echo "IP:${ip}"
		fi
	) >"$tmp_ich" 2>/dev/null 9>&- 200>&- &
	pid_ich=$!

	# Probe 6: myip.wtf (returns raw IP, lightweight)
	(
		local ip _body
		_body=$(curl -s --connect-timeout 5 --max-time 12 \
		     -w '\n%{time_namelookup}:%{time_connect}:%{time_appconnect}:%{time_starttransfer}:%{time_total}' \
		     'https://myip.wtf/text' 2>/dev/null)
		echo "$_body" | tail -1 >"$tmp_myt"
		ip=$(echo "$_body" | head -n -1 | tr -d '[:space:]')
		if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$ip" =~ :.*: ]]; then
			echo "IP:${ip}"
		fi
	) >"$tmp_myip" 2>/dev/null 9>&- 200>&- &
	pid_myip=$!

	# Probe 7: tproxy path -- detects G1 blindspot (tunnel dead but external
	# probes succeed because both endpoints exit in same country).
	# Uses direct curl (no --proxy): traffic flows through OUTPUT chain
	# (inet surflare) -> fwmark 0x1 -> table 100 -> lo -> PREROUTING
	# (inet surflare tproxy to :10800) -> sing-box -> VPN.
	# NOTE: this enters sing-box via surflare's own tproxy rule, not via
	# sw_lan_tproxy (which handles LAN br-lan traffic).  Both share the
	# same sing-box tproxy inbound, so a sing-box outbound failure is
	# detected either way.  The previous SOCKS5 approach was rejected by
	# sing-box's loopback detector (sing-box/sing-box#1688).
	(
		local _raw
		_raw=$(curl -s \
		       --connect-timeout 5 --max-time 10 \
		       -o /dev/null \
		       -w '%{http_code}\n%{time_namelookup}:%{time_connect}:%{time_appconnect}:%{time_starttransfer}:%{time_total}' \
		       https://connectivitycheck.gstatic.com/generate_204 2>/dev/null)
		echo "$_raw" | tail -1 >"$tmp_proxyt"
		local code
		code=$(echo "$_raw" | head -1)
		case "$code" in 204|200) echo "OK" ;; *) echo "FAIL" ;; esac
	) >"$tmp_proxy" 2>/dev/null 9>&- 200>&- &
	pid_proxy=$!

	# --- Early-exit polling loop ---
	# Poll results every 1s. Return as soon as any probe produces a usable result.
	# Maximum wait = max-time (12s), but typically returns in 1-3s when tunnel is healthy.
	#
	# CN deferred confirmation: when a probe returns CN, do not immediately
	# accept it.  Wait up to 3s for other probes to return a non-CN result.
	# Rationale: surflare relay 503 causes sing-box to mark outbound
	# unavailable; new connections (including health probes) get routed
	# direct while existing long-lived connections (chat sessions, etc.) keep
	# working.  A single non-CN probe overrides CN because it proves the
	# tunnel is still forwarding traffic.
	local all_pids="$pid_g $pid_cf $pid_cf2 $pid_ifc $pid_ich $pid_myip"
	local deadline=$((SECONDS + 13))  # 13s absolute deadline (max-time + 1s margin)
	local result=""
	local _cn_candidate=""  # holds "CN" if a probe returned CN
	local _cn_wait_start=0  # SECONDS when CN was first seen

	while [ "$SECONDS" -lt "$deadline" ]; do
		# Check Google first (most reliable external connectivity indicator)
		local r_g
		r_g=$(cat "$tmp_g" 2>/dev/null)
		if [ "$r_g" = "OK" ]; then
			result="OK"
			break
		fi

		# Check country probes (Cloudflare domain, Cloudflare IP, ifconfig.co)
		local r_country
		for tmp_file in "$tmp_cf" "$tmp_cf2" "$tmp_ifc"; do
			r_country=$(cat "$tmp_file" 2>/dev/null)
			if [[ "$r_country" =~ ^[A-Z]{2}$ ]]; then
				result="$r_country"
				break 2  # break out of both for and while
			fi
		done

		# Check IP probes (icanhazip, myip.wtf) -- a valid IP from a CDN
		# proves the tunnel works but does NOT prove the exit country.
		# Cross-check against killswitch bypass_ipv4 (CN ranges): if the
		# exit IP is in a CN range, check ISP IP baseline:
		# - exit IP == ISP IP: tunnel broken (traffic leaked direct) -> "CN"
		# - exit IP != ISP IP: tunnel working but exit in CN -> "TUNNEL_OK"
		local r_ip _bare_ip
		for tmp_file in "$tmp_ich" "$tmp_myip"; do
			r_ip=$(cat "$tmp_file" 2>/dev/null)
			if [ -n "$r_ip" ]; then
				_bare_ip="${r_ip#IP:}"
				if [ "$_bypass_empty" -eq 0 ] && nft get element inet killswitch bypass_ipv4 "{ $_bare_ip }" >/dev/null 2>&1; then
					if [ -n "$ISP_IP" ] && [ "$_bare_ip" != "$ISP_IP" ]; then
						result="TUNNEL_OK"
						break 2
					else
						# CN: defer confirmation, keep polling for non-CN
						if [ -z "$_cn_candidate" ]; then
							_cn_candidate="CN"
							_cn_wait_start=$SECONDS
						fi
					fi
				elif [ "$_bypass_empty" -eq 1 ]; then
					# bypass_ipv4 empty: use ISP IP comparison only
					if [ -n "$ISP_IP" ] && [ "$_bare_ip" != "$ISP_IP" ]; then
						result="TUNNEL_OK"
						break 2
					else
						if [ -z "$_cn_candidate" ]; then
							_cn_candidate="CN"
							_cn_wait_start=$SECONDS
						fi
					fi
				else
					result="TUNNEL_OK"
					break 2
				fi
			fi
		done

		# Probe 7 (tproxy path): if proxy probe returned OK, tunnel works
		local r_proxy
		r_proxy=$(cat "$tmp_proxy" 2>/dev/null)
		if [ "$r_proxy" = "OK" ]; then
			result="TUNNEL_OK"
			break
		fi

		# CN deferred: if we have a CN candidate and waited 3s, confirm it
		if [ -n "$_cn_candidate" ] && [ $((SECONDS - _cn_wait_start)) -ge 3 ]; then
			result="$_cn_candidate"
			break
		fi

		# Check if all probes have already exited (no point polling further)
		local still_running=0
		for pid in $all_pids; do
			if kill -0 "$pid" 2>/dev/null; then
				still_running=1
				break
			fi
		done
		# If all probes exited and we have a CN candidate, confirm immediately
		if [ "$still_running" -eq 0 ]; then
			[ -n "$_cn_candidate" ] && result="$_cn_candidate"
			break
		fi

		# Sleep 1s before next poll (safer than 0.2s for POSIX/busybox compatibility)
		sleep 1
	done

	# Kill remaining probes (some may still be running if we got an early result)
	for pid in $all_pids; do
		kill "$pid" 2>/dev/null
	done
	# shellcheck disable=SC2086
	wait $all_pids 2>/dev/null || true
	# Wait for Probe 7 independently -- excluded from early-exit kill so
	# G1 blindspot detection always has data.
	wait "$pid_proxy" 2>/dev/null || true

	# Final check after wait: a probe may have written between the last poll and exit
	if [ -z "$result" ]; then
		r_g=$(cat "$tmp_g" 2>/dev/null)
		[ "$r_g" = "OK" ] && result="OK"
		if [ -z "$result" ]; then
			for tmp_file in "$tmp_cf" "$tmp_cf2" "$tmp_ifc"; do
				r_country=$(cat "$tmp_file" 2>/dev/null)
				if [[ "$r_country" =~ ^[A-Z]{2}$ ]]; then
					result="$r_country"
					break
				fi
			done
		fi
		if [ -z "$result" ]; then
			for tmp_file in "$tmp_ich" "$tmp_myip"; do
				r_ip=$(cat "$tmp_file" 2>/dev/null)
				if [ -n "$r_ip" ]; then
					_bare_ip="${r_ip#IP:}"
					if [ "$_bypass_empty" -eq 0 ] && nft get element inet killswitch bypass_ipv4 "{ $_bare_ip }" >/dev/null 2>&1; then
						# IP in CN range: check if tunnel broken or just CN exit
						if [ -n "$ISP_IP" ] && [ "$_bare_ip" != "$ISP_IP" ]; then
							result="TUNNEL_OK"
						else
							result="CN"
						fi
					elif [ "$_bypass_empty" -eq 1 ]; then
						# bypass_ipv4 empty: ISP IP comparison only
						if [ -n "$ISP_IP" ] && [ "$_bare_ip" != "$ISP_IP" ]; then
							result="TUNNEL_OK"
						else
							result="CN"
						fi
					else
						result="TUNNEL_OK"
					fi
					break
				fi
			done
		fi
	fi

	# Diagnostic: classify timeout phase from embedded curl timing
	if [ -z "$result" ]; then
		local _t _label
		local all_tcp_stuck=1  # assume TCP-stuck until proven otherwise
		local has_timing=0 unknown_count=0
		for _t in "$tmp_gt:google" "$tmp_cft:cf-domain" "$tmp_cf2t:cf-ip" \
		          "$tmp_ifct:ifconfig" "$tmp_icht:icanhazip" "$tmp_myt:myip" \
		          "$tmp_proxyt:proxy"; do
			_label="${_t#*:}"
			_t="${_t%%:*}"
			local _timing
			_timing=$(cat "$_t" 2>/dev/null)
			if [ -n "$_timing" ]; then
				has_timing=1
				local _stuck
				_stuck=$(_classify_timeout "$_label" "$_timing")
				[ "$_stuck" != "TCP" ] && all_tcp_stuck=0
				[ "$_stuck" = "unknown" ] && unknown_count=$((unknown_count + 1))
			else
				all_tcp_stuck=0
			fi
		done
		# Known edge: local DNS cache + total WiFi loss can mimic TCP_BLOCK
		# (dns>0 from cache, tcp=0 from no connectivity). Benign: reconnect
		# fails fast, storm protection caps at STORM_MAX attempts.
		if [ "$has_timing" -eq 1 ] && [ "$all_tcp_stuck" -eq 1 ]; then
			result="TCP_BLOCK"
		fi
		echo "$unknown_count" > "$DNS_STUCK_FILE" 2>/dev/null || true
	fi

	# G1 blindspot detection: external probes succeeded (OK/TUNNEL_OK/country)
	# but the proxy probe COMPLETED with a non-OK result -- VPN data path
	# broken despite positive external results.
	# Only override when proxy probe actually finished (non-empty output).
	# An empty tmp_proxy means the probe was killed before completing (early
	# exit from polling loop) -- not evidence of tunnel failure.
	# Probe 7 tests a single target (gstatic.com/generate_204). CDN PoP
	# routing issues (#19) can make this target unreachable from a specific
	# exit node while the proxy itself works fine. Confirm with
	# _check_tunnel_egress (3 targets x 2 retries) before committing to
	# PROXY_BROKEN -- eliminates CDN-specific false positives that caused
	# cascade reconnects (Chicago 54s -> Atlanta 58s pattern, 2026-06-30).
	if [ -n "$result" ] && [ "$result" != "TCP_BLOCK" ] && [ "$result" != "LOCAL_FAIL" ]; then
		local r_proxy
		r_proxy=$(cat "$tmp_proxy" 2>/dev/null)
		if [ -n "$r_proxy" ] && [ "$r_proxy" != "OK" ]; then
			if ! _check_tunnel_egress; then
				result="PROXY_BROKEN"
			fi
		fi
	fi

	rm -f "$tmp_g" "$tmp_cf" "$tmp_cf2" "$tmp_ifc" "$tmp_ich" "$tmp_myip" "$tmp_proxy" \
	      "$tmp_gt" "$tmp_cft" "$tmp_cf2t" "$tmp_ifct" "$tmp_icht" "$tmp_myt" "$tmp_proxyt"
	_hc_tmp=""

	# Tunnel egress check after primary probes pass.  Tests N100 OUTPUT
	# chain path (mark 0x1 -> VPN).  Relay-side 503 degradation is caught
	# separately by the 503 storm monitor below.
	if [ -n "$result" ] && [ "$result" != "TCP_BLOCK" ] && \
	   [ "$result" != "LOCAL_FAIL" ] && [ "$result" != "CN" ] && \
	   [ "$result" != "PROXY_BROKEN" ]; then
		if ! _check_tunnel_egress; then
			log "Tunnel egress check failed: VPN path not forwarding (primary=${result})"
			result="PROXY_BROKEN"
		fi
	fi

	# 503 storm override.  Health check passed but 503 monitor has
	# accumulated evidence of sustained relay degradation (ADR-0001).
	# Triggers PROXY_BROKEN when count >= 10 AND the most recent 503
	# was within 300s (storm is still active).  Previous design used
	# _s503_first (storm start) which made chronic storms (hours of
	# steady 503) invisible because elapsed always exceeded the window.
	# Using _s503_last detects both fast bursts and chronic storms.
	if [ "$result" = "OK" ] || [ "$result" = "TUNNEL_OK" ]; then
		if [ -f "$STORM_503_STATE" ]; then
			local _s503_count _s503_first _s503_last _s503_now
			read -r _s503_count _s503_first _s503_last < "$STORM_503_STATE" 2>/dev/null
			_s503_now=$(date +%s)
			if [ "${_s503_count:-0}" -ge "$STORM_503_OVERRIDE_COUNT" ] && \
			   [ $((_s503_now - ${_s503_last:-0})) -le "$STORM_503_OVERRIDE_WINDOW" ]; then
				result="PROXY_BROKEN"
				log "503 storm override (${_s503_count} total, last $((_s503_now - _s503_last))s ago, storm age $((_s503_now - _s503_first))s) -> PROXY_BROKEN"
			fi
		fi
	fi

	echo "$result"
}

wait_for_exit() {
	local name="$1" i=0
	while _proc_alive "$name" >/dev/null 2>&1 && [ "$i" -lt "$PROCESS_EXIT_TIMEOUT" ]; do
		sleep 1
		i=$((i + 1))
	done
	if _proc_alive "$name" >/dev/null 2>&1; then
		log "Process ${name} did not exit after SIGTERM, sending SIGKILL (nftables rules may be orphaned if this is surflare)"
		killall -KILL "$name" 2>/dev/null
	fi
}

# _classify_auth_error: classify surflare login stderr into error categories.
# Returns via stdout: "fatal" (do not retry), "retryable" (network/timeout), or "" (unknown).
# Fatal errors: rate limiting (HTTP 429), invalid credentials, subscription expired, device limit.
AUTH_STDERR_FILE="/tmp/surflare_auth_stderr.log"
_classify_auth_error() {
	local errfile="${1:-$AUTH_STDERR_FILE}"
	[ -f "$errfile" ] || return
	local err
	err=$(cat "$errfile" 2>/dev/null)
	[ -z "$err" ] && echo "retryable" && return  # empty stderr = likely timeout
	case "$err" in
		*"Too Many Requests"*|*"HTTP"*"429"*|*"429"*"Too Many"*|*"rate limit"*|*"Rate Limit"*)
			log "AUTH_FATAL: rate-limited by server (HTTP 429)"
			echo "fatal" ;;
		*"invalid username"*|*"invalid password"*|*"Invalid credentials"*|*"authentication failed"*)
			log "AUTH_FATAL: invalid credentials"
			echo "fatal" ;;
		*"Subscription expired"*|*"subscription expired"*)
			log "AUTH_FATAL: subscription expired"
			echo "fatal" ;;
		*"Device limit"*|*"device limit"*)
			log "AUTH_FATAL: device limit reached"
			echo "fatal" ;;
		*"Account check failed"*|*"账户检查失败"*)
			log "AUTH_FATAL: account check failed (server-side)"
			echo "fatal" ;;
		*)
			echo "retryable" ;;
	esac
}

# refresh_auth: refresh surflare auth token using stored credentials.
# Two credential paths, tried in order:
#   1. systemd-creds (laptop): SURFLARE_EMAIL env + CREDENTIALS_DIRECTORY
#      file.  Uses expect(1) heredoc (password via stdin, not argv).
#   2. credential file (router/procd): /etc/surflare/credentials with
#      email=... and password=... lines (chmod 600 enforced).  Uses
#      sexpect(1) -env (password via env var, not argv).
# Both paths deliver the password via PTY without exposing it in
# /proc/<pid>/cmdline.  Never falls back to surflare login -p.
refresh_auth() {
	local email="" password="" _cred_source=""

	# Path 1: systemd-creds (laptop)
	if [ -n "${SURFLARE_EMAIL:-}" ] && [ -n "${CREDENTIALS_DIRECTORY:-}" ] \
	   && [ -f "${CREDENTIALS_DIRECTORY}/surflare_password" ]; then
		email="$SURFLARE_EMAIL"
		password=$(cat "$CREDENTIALS_DIRECTORY/surflare_password")
		_cred_source="systemd-creds"
	fi

	# Path 2: credential file (router/procd)
	if [ -z "$password" ] && [ -f /etc/surflare/credentials ]; then
		# Permission check: refuse world-readable credential files
		local _perms
		_perms=$(stat -c %a /etc/surflare/credentials 2>/dev/null) || true
		if [ -n "$_perms" ] && [ "$_perms" != "600" ] && [ "$_perms" != "400" ]; then
			log "WARN: /etc/surflare/credentials has mode $_perms (expected 600); refusing to read"
			return 2
		fi
		# -m1: only first match (reject duplicates); tr -d '\r': strip CRLF
		email=$(grep -m1 '^email=' /etc/surflare/credentials | cut -d= -f2- | tr -d '\r')
		password=$(grep -m1 '^password=' /etc/surflare/credentials | cut -d= -f2- | tr -d '\r')
		_cred_source="credential-file"
	fi

	# No credentials found on either path
	if [ -z "$email" ] || [ -z "$password" ]; then
		[ -f /etc/surflare/credentials ] && \
			log "WARN: /etc/surflare/credentials exists but email= or password= is missing"
		unset password 2>/dev/null
		return 2
	fi
	# Validate email format (reject shell metacharacters)
	if ! echo "$email" | grep -qE "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+$"; then
		log "WARN: invalid email format, rejecting"
		unset password 2>/dev/null
		return 2
	fi

	local i=0 rc=1 _backoff="$LOGIN_RETRY_DELAY" _err_class=""
	rm -f "$AUTH_STDERR_FILE"
	while [ "$i" -lt "$LOGIN_RETRIES" ]; do
		if command -v expect >/dev/null 2>&1; then
			# expect (laptop): PTY-based login via Tcl heredoc.
			# stdout suppressed; stderr captured for error classification.
			if timeout 30 expect <<EXPECT_EOF >/dev/null 2>"$AUTH_STDERR_FILE"
set timeout 15
log_user 0
spawn surflare login -u {${email}}
expect {
    {Password:} {}
    timeout {exit 1}
    eof {exit 1}
}
send -- {${password}}
send "\r"
expect {
    eof {
        lassign [wait] pid spawnid os_error value
        exit \$value
    }
    timeout { exit 1 }
}
EXPECT_EOF
			then
				rc=0
			fi
		elif command -v sexpect >/dev/null 2>&1; then
			# sexpect (router): PTY-based login.  Password delivered via
			# -env (reads from env var, never in /proc cmdline).  Socket
			# path via mktemp to avoid TOCTOU; trap ensures cleanup on
			# SIGTERM during the auth window.
			local _sock
			_sock=$(mktemp /tmp/.surflare_auth.XXXXXX)
			rm -f "$_sock"  # mktemp creates the file; sexpect needs the path free
			export _SURFLARE_AUTH_PW="$password"
			# stderr from surflare login captured to AUTH_STDERR_FILE for error classification.
			# sexpect stderr (control messages) suppressed; spawned process stderr captured.
			if timeout 30 sh -c "
				sexpect -s '$_sock' spawn -t 10 timeout 20 surflare login -u '$email' >/dev/null 2>&1
				sexpect -s '$_sock' expect -t 15 'Password:' >/dev/null 2>&1 || exit 1
				sexpect -s '$_sock' send -env _SURFLARE_AUTH_PW -enter >/dev/null 2>&1
				sexpect -s '$_sock' wait >/dev/null 2>&1
			" 2>"$AUTH_STDERR_FILE"; then
				rc=0
			fi
			unset _SURFLARE_AUTH_PW
			rm -f "$_sock"
		else
			log "WARN: neither expect nor sexpect installed; cannot refresh auth"
			unset password
			return 2
		fi
		if [ "$rc" -eq 0 ]; then
			rm -f "$AUTH_STDERR_FILE"
			log "Auth token refreshed (attempt $((i + 1))/${LOGIN_RETRIES})"
			break
		fi
		# Classify error from stderr to decide retry strategy
		_err_class=$(_classify_auth_error "$AUTH_STDERR_FILE")
		if [ "$_err_class" = "fatal" ]; then
			log "Auth attempt $((i + 1))/${LOGIN_RETRIES}: fatal error, not retrying"
			rc=2
			break
		fi
		i=$((i + 1))
		if [ "$i" -lt "$LOGIN_RETRIES" ]; then
			sleep "$_backoff"
			_backoff=$((_backoff * 2))
			[ "$_backoff" -gt 60 ] && _backoff=60
		fi
	done
	unset password
	if [ "$rc" -eq 1 ]; then
		log "Auth token refresh failed after ${LOGIN_RETRIES} attempts (retryable)"
	elif [ "$rc" -eq 2 ]; then
		log "Auth token refresh failed: fatal error (see ${AUTH_STDERR_FILE})"
	fi
	return "$rc"
}

# _update_server_endpoint: capture VPN relay IPs from surflare-proxy sockets.
# In rule mode, sing-box has 4 types of outbound connections (relay, transit,
# DNS resolvers, proxied traffic) but only relay/transit should be captured.
# Filter: count connections per peer IP, keep only IPs with >= MIN_RELAY_CONNS.
# Relay has 47-89 connections (persistent tunnel), transit has 6-12; DNS and
# proxied traffic have 1-3 (ephemeral).  Called after confirmed-healthy reconnect.
_update_server_endpoint() {
	local ips
	# Merge TCP + UDP raw IPs first, then count per IP across both protocols,
	# then filter by MIN_RELAY_CONNS.  This ensures an IP with 1 TCP + 1 UDP
	# connection (total 2) is correctly counted as 2, not filtered by each
	# protocol independently.
	# ss format (N100 iproute2-tiny): Recv-Q($1) Send-Q($2) Local($3) Peer($4) Process($5)
	# Both -tnp and -unp use the same 5-field layout on this platform.
	ips=$({
		ss -tnp state established 2>/dev/null \
			| awk '/surflare/{split($4,a,":");ip=a[1];
			        if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ &&
			            ip !~ /^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.)/ &&
			            ip !~ /^(223\.(5\.5\.5|6\.6\.6)|120\.53\.53\.53|119\.29\.29\.29|180\.76\.76\.76|1\.(0\.0\.1|1\.1\.1|12\.12\.12)|8\.8\.(4\.4|8\.8)|114\.114\.(114\.114|115\.115)|208\.67\.(220\.220|222\.222))$/) print ip}'
		ss -unp 2>/dev/null \
			| awk '/surflare/{split($4,a,":");ip=a[1];
			        if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ &&
			            ip !~ /^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.)/ &&
			            ip !~ /^(223\.(5\.5\.5|6\.6\.6)|120\.53\.53\.53|119\.29\.29\.29|180\.76\.76\.76|1\.(0\.0\.1|1\.1\.1|12\.12\.12)|8\.8\.(4\.4|8\.8)|114\.114\.(114\.114|115\.115)|208\.67\.(220\.220|222\.222))$/) print ip}'
	} | sort | uniq -c | sort -rn \
	  | awk -v min="$MIN_RELAY_CONNS" '$1 >= min {print $2}' \
	  | tr '\n' ' ' | sed 's/[[:space:]]*$//')
	_diag_server_ips="$ips"
	_diag_connect_time=$(date +%s)
	[ -n "$ips" ] && log "Diag: server endpoints=${ips}"
}

# _diagnose_tunnel_failure: called when TCP_BLOCK is detected.
# Captures 3s of traffic on the PHYSICAL interface for ALL surflare server IPs
# and logs a verdict distinguishing three root causes:
#
#   bidirectional -> SERVER_APP_FAILURE  (physical layer OK, server not forwarding)
#   one_way       -> UPSTREAM_UNREACHABLE  (outbound sent, nothing returned at all)
#   proxy_silent  -> LOCAL_PROXY_DEAD    (surflare-proxy not generating traffic)
#
# ICMP ping is intentionally omitted: surflare servers block ICMP, so ping
# always times out regardless of server health, making it useless as a probe.
_diagnose_tunnel_failure() {
	local now lifetime first_ip phys_if local_ip filter
	now=$(date +%s)
	lifetime=$(( now - _diag_connect_time ))

	if [ -z "$_diag_server_ips" ]; then
		log "Diag: no server IPs captured, skipping probes"
		return
	fi

	first_ip="${_diag_server_ips%% *}"

	# ip route get output: "X.X.X.X via GW dev IF src LOCAL_IP uid UID"
	# Extract both phys_if and local_ip from one call -- handles any private
	# network range (10.x, 172.16-31.x, 192.168.x) without hardcoded subnets.
	local route_info
	route_info=$(ip route get "$first_ip" 2>/dev/null)
	phys_if=$(echo "$route_info" | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
	local_ip=$(echo "$route_info" | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}')
	[ -z "$phys_if" ] && phys_if="$WIFI_INTERFACE"
	if [ -z "$local_ip" ]; then
		log "Diag: cannot determine local IP for ${phys_if:-unknown}, skipping probes"
		return
	fi

	log "Diag: lifetime=${lifetime}s servers=${_diag_server_ips} if=${phys_if} local=${local_ip}"

	# Build tcpdump filter covering all server IPs: "host IP1 or host IP2 ..."
	filter=$(echo "$_diag_server_ips" | tr ' ' '\n' | grep -v '^$' \
		| awk '{printf "%shost %s",(NR>1?" or ":""),$0}')

	# Probe: 3s physical NIC capture filtered to all surflare server IPs
	find /tmp -name 'surflare_phys_*.pcap' -mmin +30 -delete 2>/dev/null || true
	local pcap
	pcap="/tmp/surflare_phys_$(date +%Y%m%d_%H%M%S).pcap"
	tcpdump -i "$phys_if" -nn -w "$pcap" "$filter" 2>/dev/null 9>&- 200>&- &
	local td_pid=$!
	# Verify tcpdump started successfully
	if ! kill -0 "$td_pid" 2>/dev/null; then
		log "WARN: tcpdump failed to start on $phys_if"
		return 0
	fi
	sleep 3
	kill "$td_pid" 2>/dev/null; wait "$td_pid" 2>/dev/null

	local out_pkts=0 in_pkts=0
	if [ -f "$pcap" ]; then
		out_pkts=$(tcpdump -r "$pcap" -nn "src $local_ip and (${filter})" 2>/dev/null | wc -l)
		in_pkts=$(tcpdump -r "$pcap" -nn "(${filter}) and dst $local_ip" 2>/dev/null | wc -l)
	fi
	log "Diag: phys_capture out=${out_pkts} in=${in_pkts} pcap=${pcap}"

	local conclusion
	local syn_out=0 syn_ack=0 sack_total=0 rst_in=0 sack_pct=0
	if [ "$out_pkts" -gt 0 ] && [ "$in_pkts" -eq 0 ]; then
		conclusion="UPSTREAM_UNREACHABLE -- outbound sent, nothing returned at physical layer"
	elif [ "$out_pkts" -eq 0 ]; then
		conclusion="LOCAL_PROXY_DEAD -- surflare-proxy not generating tunnel traffic"
	else
		syn_out=$(tcpdump -r "$pcap" -nn \
			"src $local_ip and tcp[tcpflags] & (tcp-syn|tcp-ack) == tcp-syn" \
			2>/dev/null | wc -l)
		syn_ack=$(tcpdump -r "$pcap" -nn \
			"dst $local_ip and tcp[tcpflags] & (tcp-syn|tcp-ack) == (tcp-syn|tcp-ack)" \
			2>/dev/null | wc -l)
		sack_total=$(tcpdump -r "$pcap" -nn 2>/dev/null \
			| grep -cE 'sack [0-9]' || true)
		rst_in=$(tcpdump -r "$pcap" -nn \
			"dst $local_ip and tcp[tcpflags] & tcp-rst != 0" \
			2>/dev/null | wc -l)
		local total_pkts=$(( out_pkts + in_pkts ))
		[ "$total_pkts" -gt 0 ] && sack_pct=$(( sack_total * 100 / total_pkts ))
		log "Diag: syn_out=${syn_out} syn_ack=${syn_ack} sack=${sack_total}/${total_pkts}(${sack_pct}%) rst=${rst_in}"

		if [ "$syn_out" -gt 0 ] && [ $(( syn_ack * 2 )) -lt "$syn_out" ]; then
			if [ "$rst_in" -gt 0 ]; then
				conclusion="SERVER_REFUSED -- syn=${syn_ack}/${syn_out} rst=${rst_in} server responding with RST"
			elif [ "$sack_pct" -gt "$DIAG_SACK_THRESHOLD" ]; then
				conclusion="TRANSIT_DEGRADATION -- syn=${syn_ack}/${syn_out} sack=${sack_pct}% link quality collapse"
			else
				conclusion="TARGETED_SYN_BLOCK -- syn=${syn_ack}/${syn_out} sack=${sack_pct}% targeted SYN blocking"
			fi
		elif [ "$sack_pct" -gt "$DIAG_SACK_THRESHOLD" ]; then
			conclusion="TRANSIT_DEGRADATION -- syn=${syn_ack}/${syn_out} sack=${sack_pct}% high packet loss on active streams"
		else
			conclusion="SERVER_APP_FAILURE -- syn=${syn_ack}/${syn_out} sack=${sack_pct}% server not forwarding"
		fi
	fi
	_diag_conclusion="${conclusion%% --*}"
	_diag_out="$out_pkts"
	_diag_in="$in_pkts"
	_diag_syn_out="$syn_out"
	_diag_syn_ack="$syn_ack"
	_diag_sack_pct="$sack_pct"
	_diag_rst_in="$rst_in"
	log "Diag: CONCLUSION=${conclusion}"
	# Grant transit grace when diagnosis proves transit is healthy.
	# SERVER_APP_FAILURE = bidirectional traffic with healthy SYN-ACK ratio,
	# meaning physical layer and transit are working; only the server app is
	# broken.  Reprobe (which tests transit candidates) is wasted in this case.
	if [ "$_diag_conclusion" = "SERVER_APP_FAILURE" ]; then
		_transit_grace_ts=$(date +%s)
		log "Diag: transit grace granted (SERVER_APP_FAILURE confirms transit healthy)"
	fi
}

# _record_connect: call after every confirmed-healthy reconnect.
# Captures the transit node that was actually used, updates session state.
_record_connect() {
	local node="$1" exit_country="$2" now
	_exit_country_blocked=0  # reset every call to prevent stale flag
	# Normalize health-check codes that are not ISO country codes
	case "$exit_country" in
		OK|TUNNEL_OK) exit_country="?" ;;
	esac
	# Enforce allowed exit countries (US/PR/CA)
	if [ "${#exit_country}" -eq 2 ] && [ "$exit_country" != "?" ]; then
		case "$exit_country" in
			US|PR|CA) ;;
			*) _exit_country_blocked=1
			   log "EXIT_COUNTRY_BLOCKED: exit=$exit_country, expected US/PR/CA"
			   ;;
		esac
	fi
	now=$(date +%s)
	_sess_prev_node="$_sess_node"
	_sess_prev_s=$(( _sess_connect_s > 0 ? now - _sess_connect_s : 0 ))
	_sess_node="$node"
	_sess_exit="$exit_country"
	_sess_connect_s="$now"
	_diag_conclusion=""
	_diag_out=0
	_diag_in=0
	_diag_syn_out=0
	_diag_syn_ack=0
	_diag_sack_pct=0
	_diag_rst_in=0
	# Read the transit written by connect_vpn for every connection (not just after reprobe)
	_sess_transit=$(cat /run/surflare_last_transit 2>/dev/null || echo "unknown")
	log "Session: node=${_sess_node} transit=${_sess_transit} exit=${_sess_exit} prev=${_sess_prev_node:-none}(${_sess_prev_s}s)"
	if [ "$_sess_prev_s" -gt 0 ] && [ "$_sess_prev_s" -lt 300 ]; then
		log "NODE_DEGRADED: ${_sess_prev_node} survived ${_sess_prev_s}s (threshold 300s)"
		_stats_degraded="${_stats_degraded:+$_stats_degraded }${_sess_prev_node}"
	fi
}

# _report_stats: aggregate operational stats to dmesg.
# Called every STATS_REPORT_INTERVAL (6h) from main loop, and on SIGUSR1.
_report_stats() {
	local _now _uptime_s _uptime_h _s503_count
	_now=$(date +%s)
	_uptime_s=$((_now - _stats_start_ts))
	_uptime_h=$((_uptime_s / 3600))
	read -r _s503_count _ _ < "$STORM_503_STATE" 2>/dev/null || _s503_count=0
	log "STATS: up=${_uptime_h}h reconn=${_stats_reconnects} rot=${_stats_rotations} 503=${_s503_count} degraded=${_stats_degraded:-none} node=${_sess_node:-?} exit=${_sess_exit:-?}"
	_stats_degraded=""
	_stats_last_report=$_now
}

# _record_disconnect: call after _diagnose_tunnel_failure when TCP_BLOCK fires.
# Appends one JSON line to EVENT_LOG for pattern analysis.
_record_disconnect() {
	[ "$_sess_connect_s" -eq 0 ] && return
	local now lifetime _san_node _san_transit _san_exit
	now=$(date +%s)
	# Sanitize session vars for JSON (strip quotes/backslashes)
	# shellcheck disable=SC1003  # backslash is literal inside single quotes
	_san_node=$(echo "${_sess_node:-?}" | tr -d '"\')
	# shellcheck disable=SC1003
	_san_transit=$(echo "${_sess_transit:-?}" | tr -d '"\')
	# shellcheck disable=SC1003
	_san_exit=$(echo "${_sess_exit:-?}" | tr -d '"\')
	lifetime=$(( now - _sess_connect_s ))
	[ ! -f "$EVENT_LOG" ] && install -m 644 /dev/null "$EVENT_LOG" 2>/dev/null || true
	printf '{"ts":"%s","node":"%s","lifetime_s":%d,"transit":"%s","exit":"%s","prev_node":"%s","prev_s":%d,"hour":%d,"diag":"%s","out":%d,"in":%d,"syn_out":%d,"syn_ack":%d,"sack_pct":%d,"rst_in":%d}\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"$_san_node" "$lifetime" \
		"$_san_transit" \
		"$_san_exit" \
		"${_sess_prev_node:-none}" "$_sess_prev_s" \
		"$((10#$(date +%H)))" \
		"${_diag_conclusion:-no_diag}" \
		"$_diag_out" "$_diag_in" \
		"$_diag_syn_out" "$_diag_syn_ack" \
		"$_diag_sack_pct" "$_diag_rst_in" \
		>> "$EVENT_LOG" 2>/dev/null || true
	log "Event recorded: node=${_sess_node} lifetime=${lifetime}s transit=${_sess_transit:-?}"
}

# _detect_blocked_domains: identify domains blocked by GFW.
# Called after TCP_BLOCK confirmed (tunnel broken, local network OK).
# conntrack SYN_SENT to port 443 finds stuck handshakes; dnsmasq reply
# log maps IPs to domains; cn_domain_ips nft set filters CN-bypassed IPs.
# Advisory only -- logs CANDIDATE_INJECT, never modifies INJECT_DOMAINS.
_detect_blocked_domains() {
	[ "$PLATFORM" = "router" ] || return 0
	command -v conntrack >/dev/null 2>&1 || \
		{ log "WARN: conntrack not installed, domain detection skipped"; return 0; }

	local _ip _domain _dns_log _now _last_detect _proxy_config

	# Rate-limit: 5-minute cooldown
	_now=$(date +%s)
	_last_detect=$(cat /run/surflare_last_domain_detect 2>/dev/null || echo 0)
	if [ $((_now - _last_detect)) -lt 300 ]; then
		return 0
	fi
	echo "$_now" > /run/surflare_last_domain_detect

	# Cache dnsmasq log to temp file (single logread call, not per-IP)
	_dns_log="/tmp/.surflare_dns_$$"
	_proxy_config="/tmp/.surflare_proxy_cfg_$$"
	trap 'rm -f "$_dns_log" "$_proxy_config"' RETURN
	logread 2>/dev/null > "$_dns_log"
	[ -s "$_dns_log" ] || return 0

	# Cache sing-box proxy config for domain matching
	# Primary: admin API (runtime config, may not be configured)
	# Fallback: wrapper pre-patch snapshot (stale but contains full rule set)
	if ! curl -sf --max-time 3 "http://127.0.0.1:9090/configs" \
		-o "$_proxy_config" 2>/dev/null || [ ! -s "$_proxy_config" ]; then
		cp /tmp/singbox-config-dump.json "$_proxy_config" 2>/dev/null || true
	fi

	# conntrack: SYN_SENT to port 443 = stuck TCP handshake
	conntrack -L -p tcp --dport 443 --state SYN_SENT 2>/dev/null | \
		grep -o 'dst=[0-9.]*' | sed 's/dst=//' | sort -u | head -20 | \
		while IFS= read -r _ip; do
		[ -n "$_ip" ] || continue

		# Step 1: Reverse lookup FIRST (must be before cn_domain_ips check)
		# logread format: "<timestamp> <host> dnsmasq[<pid>]: reply <domain> is <ip>"
		# $ anchor prevents 1.2.3.4 matching 1.2.3.40
		_domain=$(grep "reply.* is ${_ip}$" "$_dns_log" | tail -1 | \
			sed -n 's/.*reply \([^ ]*\) is .*/\1/p')
		[ -z "$_domain" ] && _domain="unknown"

		# Step 2: Skip if in cn_domain_ips (CN bypass, allowed direct)
		# nft get element (NOT grep -- cn_domain_ips is interval set)
		nft get element inet sw_lan_tproxy cn_domain_ips \
			"{ $_ip }" >/dev/null 2>&1 && continue

		# Step 3: Skip if domain is in cached proxy config
		# KNOWN LIMITATION: grep on full config may match dns.server entries
		# (false negative). Acceptable for advisory output.
		if [ "$_domain" != "unknown" ] && [ -s "$_proxy_config" ]; then
			grep -q "\"$_domain\"" "$_proxy_config" && continue
		fi

		log "CANDIDATE_INJECT: ${_domain} (${_ip}) -- TCP stuck on direct route"
	done
}

# _export_diag_state: write structured JSON diagnostic snapshot.
# Called on health failures, every STATS_REPORT_INTERVAL, and on SIGUSR1 (deferred).
# $1 = health result string (OK, CN, LOCAL_FAIL, TCP_BLOCK, PROXY_BROKEN)
_export_diag_state() {
	local _health="${1:-unknown}"
	local _now _uptime_s _s503_count _err_count
	local _ct_count _ct_max _ct_pct
	local _fd_count=0 _fd_limit=0 _fd_pct=0 _pid
	local _proxy_alive=false
	local _nft_sw _nft_ks _nft_moat
	local _san_node _san_exit _san_transit _san_health
	local _diag_file="/var/log/surflare/diag_state.json"

	_now=$(date +%s)
	_uptime_s=$((_now - _stats_start_ts))

	# Independent fd reading (not dependent on observability probes' local vars)
	# tail -1 matches existing pattern (line 357) in case of multiple PIDs
	_pid=$(_pids_by_comm surflare-proxy | tail -1)
	if [ -n "$_pid" ]; then
		# shellcheck disable=SC2012
		_fd_count=$(ls "/proc/$_pid/fd" 2>/dev/null | wc -l)
		_fd_limit=$(awk '/Max open files/{print $4}' "/proc/$_pid/limits" 2>/dev/null)
		_fd_limit=${_fd_limit:-65535}
		[ "${_fd_limit:-0}" -gt 0 ] 2>/dev/null && \
			_fd_pct=$((_fd_count * 100 / _fd_limit))
		_proxy_alive=true
	fi

	# Read 503 state (3 fields: count first_epoch last_epoch)
	read -r _s503_count _ _ < "$STORM_503_STATE" 2>/dev/null || _s503_count=0

	# Read proxy error rate (2 fields: count epoch)
	# Plan 02-01 must be merged first; without it, file absent -> _err_count=0
	_err_count=0
	if [ -f "${PROXY_ERR_STATE:-/run/surflare_proxy_err_count}" ]; then
		read -r _err_count _ < \
			"${PROXY_ERR_STATE:-/run/surflare_proxy_err_count}" 2>/dev/null || _err_count=0
	fi

	# Conntrack (guard against empty/nonexistent files, same as Probe 7)
	_ct_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
	_ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 1)
	_ct_max=${_ct_max:-1}  # prevent division by zero if file empty
	if [ "${_ct_max:-0}" -gt 0 ] 2>/dev/null && [ -n "$_ct_count" ]; then
		_ct_pct=$((_ct_count * 100 / _ct_max))
	else
		_ct_pct=0
	fi

	# nft tables (PLATFORM=router only)
	if [ "$PLATFORM" = "router" ]; then
		nft list table inet sw_lan_tproxy >/dev/null 2>&1 && _nft_sw=true || _nft_sw=false
		nft list table inet killswitch >/dev/null 2>&1 && _nft_ks=true || _nft_ks=false
		nft list table inet surflare_moat >/dev/null 2>&1 && _nft_moat=true || _nft_moat=false
	else
		_nft_sw=false; _nft_ks=false; _nft_moat=false
	fi

	# Sanitize node/exit/transit (same as _record_disconnect)
	# shellcheck disable=SC1003
	_san_node=$(echo "${_sess_node:-?}" | tr -d '"\')
	# shellcheck disable=SC1003
	_san_exit=$(echo "${_sess_exit:-?}" | tr -d '"\')
	# shellcheck disable=SC1003
	_san_transit=$(echo "${_sess_transit:-?}" | tr -d '"\')
	# shellcheck disable=SC1003
	_san_health=$(echo "$_health" | tr -d '"\')

	# Write JSON
	mkdir -p "$(dirname "$_diag_file")" 2>/dev/null
	printf '{"ts":"%s","uptime_s":%d,"proxy":{"alive":%s,"pid":%d},"fd":{"count":%d,"limit":%d,"pct":%d},"conntrack":{"count":%d,"max":%d,"pct":%d},"nftables":{"sw_lan_tproxy":%s,"killswitch":%s,"surflare_moat":%s},"vpn":{"node":"%s","exit":"%s","transit":"%s","health":"%s"},"stats":{"reconnects":%d,"rotations":%d,"503s":%d,"proxy_errors":%d,"degraded":"%s"}}\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"$_uptime_s" \
		"$_proxy_alive" "${_pid:-0}" \
		"$_fd_count" "$_fd_limit" "$_fd_pct" \
		"$_ct_count" "$_ct_max" "$_ct_pct" \
		"$_nft_sw" "$_nft_ks" "$_nft_moat" \
		"$_san_node" "$_san_exit" "$_san_transit" \
		"$_san_health" \
		"${_stats_reconnects:-0}" "${_stats_rotations:-0}" \
		"$_s503_count" "${_err_count:-0}" \
		"${_stats_degraded:-none}" \
		> "$_diag_file" 2>/dev/null || \
		{ log "WARN: diag state export failed"; return 1; }
	log "diag_state.json updated ($(wc -c < "$_diag_file" 2>/dev/null || echo 0) bytes)"
}

# _run_advisory_diagnosis: rule engine mapping signals to diagnosis.
#
# ADVISORY ONLY -- this function MUST NOT:
#   - Execute nft commands
#   - Modify INJECT_DOMAINS or surflare-proxy config
#   - Restart any service
#   - Change routing or firewall rules
#
# It reads diagnostic data and writes a structured JSON report.
# Violation of advisory-only is a P0 bug.
_run_advisory_diagnosis() {
	local _health="${1:-unknown}"
	local _auth_expired="${3:-0}"
	local _diag="${2:-}"
	local _diag_file="/var/log/surflare/diagnosis.json"

	# Recursion guard (defense-in-depth).
	# Prevents nested calls if _run_advisory_diagnosis is ever invoked
	# from within a signal handler or callback. Currently unreachable
	# in the single-threaded main loop -- placed for future safety.
	if [ "${_ADVISORY_DIAGNOSIS_RUNNING:-0}" -eq 1 ]; then
		log "BUG: recursive _run_advisory_diagnosis call"
		return 1
	fi
	_ADVISORY_DIAGNOSIS_RUNNING=1

	# Fault injection: create synthetic data when _INJECT_FAULT is set.
	# Zero overhead when unset (single -n check).
	# Guard MUST be after re-entrancy check (so recursive calls during
	# injection are caught) and before all signal-reading code (so
	# synthetic data overrides real data).
	if [ -n "${_INJECT_FAULT:-}" ]; then
		_inject_diag_state "$_INJECT_FAULT" || { _ADVISORY_DIAGNOSIS_RUNNING=0; return 1; }
		# Override health and diag from env if provided
		_health="${_INJECT_HEALTH:-$_health}"
		_diag="${_INJECT_DIAG:-$_diag}"
	fi

	local _now _conclusion _confidence _signals _recommendation
	local _fd_pct=0 _proxy_err=0 _503_count=0 _ct_pct=0
	local _candidate_count=0 _uptime_s=0
	local _proxy_alive=false _proxy_pid=0 _last_reconnect_s_ago=0
	local _error_samples="" _lr_ts=0
	local _num_candidates=${#NODE_CANDIDATES[@]}
	: "${_num_candidates:=0}"  # default to 0 if array is unset
	local _node _exit _transit
	local _san_conclusion _san_signals _san_recommendation
	local _san_node _san_exit _san_transit

	# busybox date -u works identically to GNU date for +%s and +%Y-%m-%dT%H:%M:%SZ formats
	_now=$(date +%s)

	# Read diag_state.json fields (Plan 02-02 must be merged)
	if [ -f /var/log/surflare/diag_state.json ]; then
		# Extract fields using grep + sed (no python3 on N100)
		# Each field read is independent; missing field -> default
		# Extract pct from specific parent keys (not position-based)
		# Whitespace-tolerant: diag_state.json may have spaces around
		# colons if pretty-printed or if printf format changes.
		_fd_pct=$(grep -o '"fd"[[:space:]]*:[[:space:]]*{[^}]*}' /var/log/surflare/diag_state.json | \
			grep -o '"pct"[[:space:]]*:[[:space:]]*[0-9]*' | sed 's/[^0-9]//g')
		_ct_pct=$(grep -o '"conntrack"[[:space:]]*:[[:space:]]*{[^}]*}' /var/log/surflare/diag_state.json | \
			grep -o '"pct"[[:space:]]*:[[:space:]]*[0-9]*' | sed 's/[^0-9]//g')
		_uptime_s=$(grep -o '"uptime_s":[0-9]*' /var/log/surflare/diag_state.json | \
			sed 's/"uptime_s"://')
		_node=$(grep -o '"node":"[^"]*"' /var/log/surflare/diag_state.json | \
			sed 's/"node":"//; s/"//')
		_exit=$(grep -o '"exit":"[^"]*"' /var/log/surflare/diag_state.json | \
			sed 's/"exit":"//; s/"//')
		_transit=$(grep -o '"transit":"[^"]*"' /var/log/surflare/diag_state.json | \
			sed 's/"transit":"//; s/"//')
	fi
	_fd_pct=${_fd_pct:-0}
	_ct_pct=${_ct_pct:-0}
	_uptime_s=${_uptime_s:-0}

	# Read proxy error count (Plan 02-01)
	if [ -f /run/surflare_proxy_err_count ]; then
		read -r _proxy_err _ < /run/surflare_proxy_err_count 2>/dev/null || _proxy_err=0
	fi
	_proxy_err=${_proxy_err:-0}

	# Read 503 count
	if [ -f /run/surflare_503_state ]; then
		read -r _503_count _ _ < /run/surflare_503_state 2>/dev/null || _503_count=0
	fi
	_503_count=${_503_count:-0}

	# Count CANDIDATE_INJECT from watchdog log (logread).
	# _detect_blocked_domains (Plan 02-02) logs "CANDIDATE_INJECT:" to syslog,
	# but does NOT write a persisted file at /run/surflare_candidate_inject_count.
	# If a future change adds file persistence, add the file path as primary
	# source here with logread as fallback.
	_candidate_count=$(logread 2>/dev/null | tail -100 | \
		grep -c 'CANDIDATE_INJECT' 2>/dev/null || echo 0)

	# --- Rule engine: priority-ordered, first match wins ---
	_conclusion="UNKNOWN"
	_confidence="low"
	_signals=""
	_recommendation="Unable to determine cause. Check logs manually."

	# Rule 0: AUTH_EXPIRED -- auth token expired (flag set by proxy log monitor)
	if [ "$_auth_expired" = "1" ] && [ "$_health" != "LOCAL_FAIL" ]; then
		_conclusion="AUTH_TOKEN_EXPIRED"
		_confidence="high"
		_signals="auth_expired=1"
		_recommendation="Auth token expired. Run surflare login to refresh."


	# Rule 1: LOCAL_FAIL
	elif [ "$_health" = "LOCAL_FAIL" ]; then
		_conclusion="LOCAL_STATE_LOST"
		_confidence="high"
		_signals="health=LOCAL_FAIL"
		_recommendation="VPN state lost, reconnect forced. Check procd/surflare status."

	# Rule 2: CN_EXIT_INFRA_DOWN -- all candidate nodes tried (consecutive CN exits >= total candidates)
	elif [ "$_health" = "CN" ] && \
	     [ "${_cn_consecutive:-0}" -ge "${_num_candidates}" ]; then
		_conclusion="CN_EXIT_INFRA_DOWN"
		_confidence="high"
		_signals="health=CN,all_nodes_tried=${_cn_consecutive}"
		_recommendation="All exit nodes route via CN. Relay infrastructure may be down."

	# Rule 3: CN exit, single node
	elif [ "$_health" = "CN" ]; then
		_conclusion="CN_EXIT_SINGLE_NODE"
		_confidence="medium"
		_signals="health=CN,node=${_node:-?}"
		_recommendation="Exit via CN on current node. Rotate node."

	# Rule 4: UPSTREAM_UNREACHABLE + fd high
	elif [ "$_diag" = "UPSTREAM_UNREACHABLE" ] && [ "$_fd_pct" -gt 80 ] 2>/dev/null; then
		_conclusion="UPSTREAM_UNREACHABLE_RESOURCE"
		_confidence="high"
		_signals="diag=UPSTREAM_UNREACHABLE,fd_pct=${_fd_pct}"
		_recommendation="Upstream unreachable + fd exhaustion. Proxy likely stuck."

	# Rule 5: UPSTREAM_UNREACHABLE
	elif [ "$_diag" = "UPSTREAM_UNREACHABLE" ]; then
		_conclusion="UPSTREAM_UNREACHABLE"
		_confidence="medium"
		_signals="diag=UPSTREAM_UNREACHABLE,fd_pct=${_fd_pct}"
		_recommendation="Cannot reach upstream server. Check relay availability."

	# Rule 6: SERVER_REFUSED + 503 storm
	elif [ "$_diag" = "SERVER_REFUSED" ] && [ "$_503_count" -gt 10 ] 2>/dev/null; then
		_conclusion="SERVER_REFUSED_503_STORM"
		_confidence="high"
		_signals="diag=SERVER_REFUSED,503s=${_503_count}"
		_recommendation="Server refusing connections + 503 storm. Subscription expired?"

	# Rule 7: SERVER_REFUSED
	elif [ "$_diag" = "SERVER_REFUSED" ]; then
		_conclusion="SERVER_REFUSED"
		_confidence="medium"
		_signals="diag=SERVER_REFUSED"
		_recommendation="Server refusing connections. Check auth token."

	# Rule 8: TARGETED_SYN_BLOCK
	elif [ "$_diag" = "TARGETED_SYN_BLOCK" ]; then
		_conclusion="TARGETED_SYN_BLOCK"
		_confidence="high"
		_signals="diag=TARGETED_SYN_BLOCK,syn_out=${_diag_syn_out:-?},syn_ack=${_diag_syn_ack:-?}"
		_recommendation="GFW blocking SYN to relay IP. Node burned."

	# Rule 9: TRANSIT_DEGRADATION
	elif [ "$_diag" = "TRANSIT_DEGRADATION" ]; then
		_conclusion="TRANSIT_DEGRADATION"
		_confidence="medium"
		_signals="diag=TRANSIT_DEGRADATION,sack_pct=${_diag_sack_pct:-?}"
		_recommendation="Transit path degraded. High packet loss detected."

	# Rule 10: PROXY_BROKEN + fd high
	elif [ "$_health" = "PROXY_BROKEN" ] && [ "$_fd_pct" -gt 80 ] 2>/dev/null; then
		_conclusion="PROXY_BROKEN_RESOURCE"
		_confidence="high"
		_signals="health=PROXY_BROKEN,fd_pct=${_fd_pct}"
		_recommendation="Proxy not forwarding + fd exhaustion. Leak likely."

	# Rule 11: PROXY_BROKEN + 503 storm
	elif [ "$_health" = "PROXY_BROKEN" ] && [ "$_503_count" -gt 10 ] 2>/dev/null; then
		_conclusion="PROXY_BROKEN_503"
		_confidence="high"
		_signals="health=PROXY_BROKEN,503s=${_503_count}"
		_recommendation="Proxy not forwarding + 503 storm. Backend issue."

	# Rule 12: PROXY_BROKEN
	elif [ "$_health" = "PROXY_BROKEN" ]; then
		_conclusion="PROXY_BROKEN"
		_confidence="medium"
		_signals="health=PROXY_BROKEN,proxy_errors=${_proxy_err}"
		_recommendation="Proxy path degraded; watchdog will attempt auto-reconnect."

	# Rule 13: SERVER_APP_FAILURE
	elif [ "$_diag" = "SERVER_APP_FAILURE" ]; then
		_conclusion="SERVER_APP_FAILURE"
		_confidence="medium"
		_signals="diag=SERVER_APP_FAILURE"
		_recommendation="Server application error. Transient, retry may help."

	# Rule 14: BLOCKED_DOMAINS (TCP_BLOCK + candidates found)
	elif [ "$_health" = "TCP_BLOCK" ] && [ "$_candidate_count" -gt 0 ] 2>/dev/null; then
		_conclusion="BLOCKED_DOMAINS"
		_confidence="medium"
		_signals="health=TCP_BLOCK,candidate_inject=${_candidate_count}"
		_recommendation="Domains blocked on direct route. Consider INJECT_DOMAINS."

	# Rule 15: MIXED_SIGNALS
	elif [ "$_diag" = "MIXED_SIGNALS" ]; then
		_conclusion="MIXED_SIGNALS"
		_confidence="low"
		_signals="diag=MIXED_SIGNALS"
		_recommendation="Multiple conflicting signals. Manual investigation needed."

	# Rule 16: UNKNOWN (fallback)
	else
		_conclusion="UNKNOWN"
		_confidence="low"
		_signals="health=${_health},diag=${_diag:-none}"
		_recommendation="Unable to determine cause. Check logs manually."
	fi

	# Sanitize for JSON (same pattern as _export_diag_state)
	# shellcheck disable=SC1003
	_san_conclusion=$(printf '%s' "$_conclusion" | tr -d '"\')
	# shellcheck disable=SC1003
	_san_signals=$(printf '%s' "$_signals" | tr -d '"\')
	# shellcheck disable=SC1003
	_san_recommendation=$(printf '%s' "$_recommendation" | tr -d '"\')
	# shellcheck disable=SC1003
	_san_node=$(printf '%s' "${_node:-?}" | tr -d '"\')
	# shellcheck disable=SC1003
	_san_exit=$(printf '%s' "${_exit:-?}" | tr -d '"\')
	# shellcheck disable=SC1003
	_san_transit=$(printf '%s' "${_transit:-?}" | tr -d '"\')

	# Collect diagnosis enrichment context: process liveness, recent error
	# samples, and seconds since last reconnect. All read-only (advisory).
	_proxy_pid=$(_pids_by_comm surflare-proxy 2>/dev/null | tail -1)
	if [ -n "$_proxy_pid" ]; then
		_proxy_alive=true
	else
		_proxy_pid=0
	fi
	if [ -f /run/surflare_last_reconnect ]; then
		read -r _lr_ts < /run/surflare_last_reconnect 2>/dev/null || _lr_ts=0
		if [ "${_lr_ts:-0}" -gt 0 ] 2>/dev/null; then
			_last_reconnect_s_ago=$(( _now - _lr_ts ))
		fi
	fi
	if [ -f "$PROXY_LOG" ]; then
		_error_samples=$(tail -50 "$PROXY_LOG" 2>/dev/null | grep 'ERROR' | \
			tail -3 | tr '\n' ';' | tr -d '\t\r' | \
			sed 's/\\/\\\\/g; s/"/\\"/g' | cut -c1-500)
	fi

	# Write diagnosis JSON
	# busybox printf: %d with non-numeric args defaults to 0 (safe fallback)
	mkdir -p "$(dirname "$_diag_file")" 2>/dev/null
	# All %d args default to 0 so busybox printf never hits "invalid number"
	# which returns exit 1 without writing stderr to the redirected file.
	# Subshell ensures shell-level errors are also captured by 2>>.
	( printf '{"version":1,"ts":"%s","health":"%s","tier1":{"conclusion":"%s","confidence":"%s","signals":"%s","recommendation":"%s"},"context":{"node":"%s","exit":"%s","transit":"%s","uptime_s":%d,"reconnects":%d,"fd_pct":%d,"proxy_errors":%d,"503s":%d,"candidate_inject":%d,"proxy_alive":%s,"proxy_pid":%d,"last_reconnect_s_ago":%d,"error_samples":"%s"}}\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"$_health" \
		"$_san_conclusion" "$_confidence" "$_san_signals" "$_san_recommendation" \
		"$_san_node" "$_san_exit" "$_san_transit" \
		"${_uptime_s:-0}" "${_stats_reconnects:-0}" \
		"${_fd_pct:-0}" "${_proxy_err:-0}" "${_503_count:-0}" "${_candidate_count:-0}" \
		"${_proxy_alive:-false}" "${_proxy_pid:-0}" "${_last_reconnect_s_ago:-0}" "$_error_samples" \
	) > "$_diag_file" 2>>/tmp/diag_err.log
	# busybox printf returns exit 1 even when output is written successfully
	# (observed with all-numeric args, empty stderr).  Check the file
	# instead of the exit code to avoid false "export failed" warnings.
	if [ ! -s "$_diag_file" ]; then
		log "WARN: diagnosis export failed (uptime=${_uptime_s:-?} fd=${_fd_pct:-?} err=${_proxy_err:-?} 503=${_503_count:-?} pid=${_proxy_pid:-?} reconnect_ago=${_last_reconnect_s_ago:-?})"
		_ADVISORY_DIAGNOSIS_RUNNING=0
		return 1
	fi

	log "Diagnosis: ${_conclusion} (${_confidence}) -- ${_recommendation}"
	_ADVISORY_DIAGNOSIS_RUNNING=0
}

# _inject_diag_state: create synthetic diagnostic data for testing.
# Called ONLY when _INJECT_FAULT is set.
# NEVER called in production (guarded by _INJECT_FAULT check in caller).
#
# Backs up original files on first call; _inject_restore_state restores them.
_inject_diag_state() {
	local _scenario="${1:?scenario required}"
	local _diag_dir="/var/log/surflare"
	local _diag_file="${_diag_dir}/diag_state.json"
	local _err_file="/run/surflare_proxy_err_count"
	local _503_file="/run/surflare_503_state"

	mkdir -p "$_diag_dir" 2>/dev/null

	# Backup originals on first call (not subsequent scenarios in same run)
	if [ -z "${_INJECT_BACKUP_DONE:-}" ]; then
		[ -f "$_diag_file" ] && cp "$_diag_file" "${_diag_file}.inject-backup"
		[ -f "$_err_file" ] && cp "$_err_file" "${_err_file}.inject-backup"
		[ -f "$_503_file" ] && cp "$_503_file" "${_503_file}.inject-backup"
		_INJECT_BACKUP_DONE=1
	fi

	case "$_scenario" in
		UPSTREAM_UNREACHABLE_FD)
			# fd_pct=85, proxy_errors=0, 503s=0, conntrack_pct=30
			printf '{"ts":"%s","uptime_s":3600,"fd":{"count":5570,"limit":65535,"pct":85},"conntrack":{"count":900,"max":3000,"pct":30},"nftables":{"sw_lan_tproxy":true,"killswitch":true,"surflare_moat":true},"vpn":{"node":"de-fra-01","exit":"de-fra-01","transit":"de-fra-01","health":"TCP_BLOCK"},"stats":{"reconnects":3,"rotations":1,"503s":0,"proxy_errors":0,"degraded":"none"}}\n' \
				"$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$_diag_file"
			echo "0 $(date +%s)" > "$_err_file"
			echo "0 0 0" > "$_503_file"
			;;
		SERVER_REFUSED_503)
			# fd_pct=20, proxy_errors=0, 503s=15, conntrack_pct=10
			printf '{"ts":"%s","uptime_s":7200,"fd":{"count":1310,"limit":65535,"pct":20},"conntrack":{"count":300,"max":3000,"pct":10},"nftables":{"sw_lan_tproxy":true,"killswitch":true,"surflare_moat":true},"vpn":{"node":"us-east-01","exit":"us-east-01","transit":"us-east-01","health":"TCP_BLOCK"},"stats":{"reconnects":5,"rotations":2,"503s":15,"proxy_errors":0,"degraded":"none"}}\n' \
				"$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$_diag_file"
			echo "0 $(date +%s)" > "$_err_file"
			echo "15 $(($(date +%s) - 600)) $(date +%s)" > "$_503_file"
			;;
		TARGETED_SYN_BLOCK)
			# fd_pct=15, proxy_errors=0, 503s=0, conntrack_pct=5
			printf '{"ts":"%s","uptime_s":1800,"fd":{"count":983,"limit":65535,"pct":15},"conntrack":{"count":150,"max":3000,"pct":5},"nftables":{"sw_lan_tproxy":true,"killswitch":true,"surflare_moat":true},"vpn":{"node":"jp-tok-01","exit":"jp-tok-01","transit":"jp-tok-01","health":"TCP_BLOCK"},"stats":{"reconnects":2,"rotations":0,"503s":0,"proxy_errors":0,"degraded":"none"}}\n' \
				"$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$_diag_file"
			echo "0 $(date +%s)" > "$_err_file"
			echo "0 0 0" > "$_503_file"
			;;
		TRANSIT_DEGRADATION)
			# fd_pct=25, proxy_errors=2, 503s=0, conntrack_pct=40
			printf '{"ts":"%s","uptime_s":5400,"fd":{"count":1638,"limit":65535,"pct":25},"conntrack":{"count":1200,"max":3000,"pct":40},"nftables":{"sw_lan_tproxy":true,"killswitch":true,"surflare_moat":true},"vpn":{"node":"sg-sin-01","exit":"sg-sin-01","transit":"sg-sin-01","health":"TCP_BLOCK"},"stats":{"reconnects":1,"rotations":0,"503s":0,"proxy_errors":2,"degraded":"none"}}\n' \
				"$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$_diag_file"
			echo "2 $(date +%s)" > "$_err_file"
			echo "0 0 0" > "$_503_file"
			;;
		PROXY_BROKEN_FD)
			# fd_pct=88, proxy_errors=12, 503s=0, conntrack_pct=20
			printf '{"ts":"%s","uptime_s":10800,"fd":{"count":5766,"limit":65535,"pct":88},"conntrack":{"count":600,"max":3000,"pct":20},"nftables":{"sw_lan_tproxy":true,"killswitch":true,"surflare_moat":true},"vpn":{"node":"de-fra-01","exit":"de-fra-01","transit":"de-fra-01","health":"PROXY_BROKEN"},"stats":{"reconnects":8,"rotations":3,"503s":0,"proxy_errors":12,"degraded":"none"}}\n' \
				"$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$_diag_file"
			echo "12 $(date +%s)" > "$_err_file"
			echo "0 0 0" > "$_503_file"
			;;
		CN_EXIT)
			# fd_pct=10, proxy_errors=0, 503s=0, conntrack_pct=8
			printf '{"ts":"%s","uptime_s":900,"fd":{"count":655,"limit":65535,"pct":10},"conntrack":{"count":240,"max":3000,"pct":8},"nftables":{"sw_lan_tproxy":true,"killswitch":true,"surflare_moat":true},"vpn":{"node":"us-east-01","exit":"cn-beijing-01","transit":"us-east-01","health":"CN"},"stats":{"reconnects":1,"rotations":0,"503s":0,"proxy_errors":0,"degraded":"none"}}\n' \
				"$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$_diag_file"
			echo "0 $(date +%s)" > "$_err_file"
			echo "0 0 0" > "$_503_file"
			;;
		*)
			log "WARN: unknown inject scenario: $_scenario"
			return 1
			;;
	esac
}

# _inject_restore_state: restore original files after fault injection.
# Called from test harness trap on EXIT.
# Restores backups created by _inject_diag_state; removes synthetic
# files that had no original.
_inject_restore_state() {
	local _diag_file="/var/log/surflare/diag_state.json"
	local _err_file="/run/surflare_proxy_err_count"
	local _503_file="/run/surflare_503_state"
	for _f in "$_diag_file" "$_err_file" "$_503_file"; do
		if [ -f "${_f}.inject-backup" ]; then
			mv "${_f}.inject-backup" "$_f"
		else
			rm -f "$_f"  # didn't exist before, remove synthetic
		fi
	done
	_INJECT_BACKUP_DONE=""
}

# _llm_enrich_diagnosis: call analysis API for diagnosis enrichment.
#
# Reads /var/log/surflare/diagnosis.json (from _run_advisory_diagnosis),
# sends tier1 context to analysis API, prints analysis to stdout.
#
# 3-tier fallback: DeepSeek CN -> Agnes -> give up.
# Each tier is OpenAI-compatible; tried in order until one succeeds.
#
# ADVISORY ONLY -- no system state modification.
# Returns 1 on any failure; caller must handle empty output.
_llm_enrich_diagnosis() {
	local _conf="/etc/surflare/llm.conf"
	local _diag_file="/var/log/surflare/diagnosis.json"
	local _llm_out="/var/log/surflare/diagnosis_llm.json"
	local _enabled _timeout _max_tokens
	local _tier1_context _sys_msg _user_msg _esc_sys _esc_user
	local _response _analysis _rc

	# Config check (grep-based, same pattern as wechat.conf -- no source)
	[ -f "$_conf" ] || return 1
	_enabled=$(grep -m1 '^ENABLED=' "$_conf" | cut -d= -f2- | tr -d '"\r ')
	[ "$_enabled" = "true" ] || return 1
	_timeout=$(grep -m1 '^TIMEOUT=' "$_conf" | cut -d= -f2- | tr -d '"\r ')
	_timeout="${_timeout:-15}"
	_max_tokens=$(grep -m1 '^MAX_TOKENS=' "$_conf" | cut -d= -f2- | tr -d '"\r ')
	_max_tokens="${_max_tokens:-256}"

	# Read tier1 diagnosis context
	[ -f "$_diag_file" ] || return 1
	_tier1_context=$(cat "$_diag_file" 2>/dev/null)
	[ -n "$_tier1_context" ] || return 1

	# Build prompt: system message grounds the analysis with platform, architecture,
	# and recovery context; user message provides the diagnosis data.
	# Output in Chinese per user requirement. System message stays ASCII to
	# keep the source file clean (non-ASCII check); the API obeys the language
	# instruction regardless of prompt language.
	_sys_msg="You are a VPN network diagnosis assistant running on an OpenWrt/iStoreOS router (procd init, NOT systemd). Architecture: sing-box tproxy transparent proxy + killswitch firewall; surflare-proxy is the sing-box process. The watchdog auto-reconnects on tunnel failure; most PROXY_BROKEN events self-recover within 30 seconds. Analyze the diagnosis data and identify the root cause. Distinguish transient failures (relay connection dropped, auto-recoverable) from persistent failures (process/port/config issue, needs manual intervention). Advisory only: provide analysis, do not execute actions. Respond in Chinese, 3-5 sentences, direct root cause and one recommendation."
	_user_msg="Diagnosis data: ${_tier1_context}"

	# Escape both messages for JSON: backslash, double-quote, newline
	_esc_sys=$(printf '%s' "$_sys_msg" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g')
	_esc_user=$(printf '%s' "$_user_msg" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g')

	# --- Helper: try one analysis tier ---
	# _try_llm_tier API_KEY MODEL BASE_URL
	# Returns 0 on success (prints analysis), 1 on failure.
	# NOTE: _try_llm_tier is a nested function (bash 4+ feature).
	# N100 runs bash (confirmed in Task 0 pre-flight of 03-04). Not POSIX sh compatible.
	_try_llm_tier() {
		local _key="$1" _mdl="$2" _url="$3"
		[ -n "$_key" ] || return 1

		_response=$(curl -sf --max-time "$_timeout" \
			-X POST "$_url" \
			-H "Content-Type: application/json" \
			-H "Authorization: Bearer ${_key}" \
			-d "{\"model\":\"${_mdl}\",\"messages\":[{\"role\":\"system\",\"content\":\"${_esc_sys}\"},{\"role\":\"user\",\"content\":\"${_esc_user}\"}],\"max_tokens\":${_max_tokens},\"temperature\":0.3}" \
			2>/dev/null)
		_rc=$?

		if [ "$_rc" -ne 0 ] || [ -z "$_response" ]; then
			return 1
		fi

		# Save full response for debugging (non-fatal)
		printf '%s\n' "$_response" > "$_llm_out" 2>/dev/null || true

		# Two-pass content extraction:
		# Pass 1: extract raw content between "content":" and "}}]
		#   Cannot use [^"]* -- breaks on JSON-escaped quotes (\").
		#   Match from "content":" to the message-object closing "}}]
		#   which is unique in OpenAI response structure.
		_analysis=$(printf '%s' "$_response" | \
			sed 's/.*"content":"//; s/"}].*//')

		# Fallback: if two-pass extraction failed (edge case: content contains "}] sequence)
		if [ -z "$_analysis" ]; then
			_analysis=$(printf '%s' "$_response" | \
				sed 's/.*"content":"//; s/".*//' | head -c 500)
		fi

		if [ -z "$_analysis" ]; then
			return 1
		fi

		# Pass 2: unescape JSON string literals in correct order.
		# Order matters: \" must be unescaped BEFORE \\ to avoid
		# mangling \\" (escaped backslash + quote).
		# \n -> space (not real newline) for single-line alert body.
		_analysis=$(printf '%s' "$_analysis" | \
			sed 's/\\"/"/g; s/\\n/ /g; s/\\\\/\\/g')

		printf '%s' "$_analysis"
		return 0
	}

	# --- Tier 1: DeepSeek CN (primary, ~0.24s) ---
	local _ds_key _ds_model _ds_url
	_ds_key=$(grep -m1 '^DEEPSEEK_API_KEY=' "$_conf" | cut -d= -f2- | tr -d '"\r ')
	_ds_model=$(grep -m1 '^DEEPSEEK_MODEL=' "$_conf" | cut -d= -f2- | tr -d '"\r ')
	_ds_model="${_ds_model:-deepseek-chat}"
	_ds_url=$(grep -m1 '^DEEPSEEK_URL=' "$_conf" | cut -d= -f2- | tr -d '"\r ')
	_ds_url="${_ds_url:-https://api.deepseek.com/v1/chat/completions}"

	if _try_llm_tier "$_ds_key" "$_ds_model" "$_ds_url"; then
		log "Analysis: primary tier succeeded"
		return 0
	fi
	log "WARN: DeepSeek tier failed, trying Agnes fallback"

	# --- Tier 2: Agnes (fallback, ~1.65s, free) ---
	local _ag_key _ag_model _ag_url
	_ag_key=$(grep -m1 '^AGNES_API_KEY=' "$_conf" | cut -d= -f2- | tr -d '"\r ')
	_ag_model=$(grep -m1 '^AGNES_MODEL=' "$_conf" | cut -d= -f2- | tr -d '"\r ')
	_ag_model="${_ag_model:-agnes-2.0-flash}"
	_ag_url=$(grep -m1 '^AGNES_URL=' "$_conf" | cut -d= -f2- | tr -d '"\r ')
	_ag_url="${_ag_url:-https://apihub.agnes-ai.com/v1/chat/completions}"

	if _try_llm_tier "$_ag_key" "$_ag_model" "$_ag_url"; then
		log "Analysis: fallback tier succeeded"
		return 0
	fi
	log "WARN: all analysis tiers failed"

	# --- Tier 3: qwen LAN (future, gated on H0b) ---
	# Placeholder: uncomment when H0b certification is complete.
	# local _qw_url
	# _qw_url=$(grep -m1 '^QWEN_LAN_URL=' "$_conf" | cut -d= -f2- | tr -d '"\r ')
	# _qw_url="${_qw_url:-http://192.168.100.11:11434/v1/chat/completions}"
	# if _try_llm_tier "not-needed" "qwen3.5" "$_qw_url"; then
	#     log "LLM: qwen LAN tier succeeded"
	#     return 0
	# fi

	return 1
}

# _send_diagnosis_alert: send structured diagnosis via alert bridge.
#
# Reads diagnosis.json (tier1) and fires _llm_enrich_diagnosis (tier2)
# in background. Main loop sends tier1-only alert immediately and
# continues. Analysis follow-up uses _deliver_alert (no rate limiter) so it
# is not blocked by tier1 consuming the 600s window. Follow-up is gated
# on tier1 actually being delivered -- if tier1 is rate-limited, the
# Analysis subshell is not spawned (saves API calls).
#
# ADVISORY ONLY -- no system state modification.
_send_diagnosis_alert() {
	local _health="${1:-unknown}"
	local _diag_file="/var/log/surflare/diagnosis.json"
	local _conclusion _confidence _signals _recommendation
	local _alert_body _alert_title

	# Read tier1 from diagnosis.json
	[ -f "$_diag_file" ] || return 0
	_conclusion=$(grep -o '"conclusion":"[^"]*"' "$_diag_file" | \
		sed 's/"conclusion":"//; s/"//')
	_confidence=$(grep -o '"confidence":"[^"]*"' "$_diag_file" | \
		sed 's/"confidence":"//; s/"//')
	_signals=$(grep -o '"signals":"[^"]*"' "$_diag_file" | \
		sed 's/"signals":"//; s/"//')
	_recommendation=$(grep -o '"recommendation":"[^"]*"' "$_diag_file" | \
		sed 's/"recommendation":"//; s/"//')

	[ -n "$_conclusion" ] || return 0

	# Grace period: medium/low severity failures wait DIAG_GRACE_PERIOD seconds
	# before alerting. If the watchdog recovers within the window, no alert is
	# sent (avoids wasting operator attention on transient self-healing events).
	# High-severity conclusions (auth expired, local process lost) bypass grace
	# because they require immediate manual action.
	# State file /run/surflare_diag_fail_since is cleared on health recovery.
	local _grace_file="/run/surflare_diag_fail_since"
	local _gnow _gsince _gelapsed
	case "$_conclusion" in
		AUTH_TOKEN_EXPIRED|LOCAL_FAIL|PROCESS_LOST)
			rm -f "$_grace_file" 2>/dev/null
			;;
		*)
			if [ "${DIAG_GRACE_PERIOD:-0}" -le 0 ] 2>/dev/null; then
				: # grace disabled, fall through to alert
			else
				_gnow=$(date +%s)
				if [ ! -f "$_grace_file" ]; then
					echo "$_gnow" > "$_grace_file" 2>/dev/null
					log "Diagnosis grace: ${_conclusion} first seen, waiting ${DIAG_GRACE_PERIOD}s"
					return 0
				fi
				read -r _gsince < "$_grace_file" 2>/dev/null || _gsince=0
				_gelapsed=$(( _gnow - _gsince ))
				if [ "$_gelapsed" -lt "${DIAG_GRACE_PERIOD}" ]; then
					log "Diagnosis grace: ${_conclusion} for ${_gelapsed}s, need ${DIAG_GRACE_PERIOD}s, skipping"
					return 0
				fi
				log "Diagnosis grace: ${_conclusion} persisted ${_gelapsed}s, alerting"
			fi
			;;
	esac

	# Compose tier1 alert (sent immediately, no analysis wait)
	_alert_title="[Diagnosis] ${_conclusion} (${_confidence:-?})"
	_alert_body="${_recommendation:-check logs}"
	[ -n "$_signals" ] && _alert_body="Signals: ${_signals}\n${_alert_body}"

	# Only spawn Analysis follow-up if tier1 was actually delivered (not rate-limited).
	# Follow-up uses _deliver_alert directly -- the subshell's variable changes
	# don't propagate back, so the main shell's _alert_last_ts is unaffected.
	# This means the follow-up bypasses the 600s limiter without enabling spam:
	# each failure produces at most 2 alerts (tier1 + follow-up), and tier1
	# itself is still rate-limited at 600s.
	local _prev_ts=${_alert_last_ts:-0}
	_send_alert "$_alert_title" "$(printf '%b' "$_alert_body")"

	if [ "$_alert_last_ts" != "$_prev_ts" ]; then
		(
			_llm_analysis=$(_llm_enrich_diagnosis) || exit 0
			[ -n "$_llm_analysis" ] || exit 0
			_deliver_alert "[Analysis] ${_conclusion}" "$_llm_analysis"
		) 9>&- 200>&- &
	fi

	return 0
}

TRANSIT_CACHE_FILE="/run/surflare_transit_cache"
TRANSIT_REPROBE_AFTER=3
TRANSIT_ALLDOWN_WAIT=300                # cooldown when all transit candidates unreachable

_transit_fail_count=0
_transit_cooldown_until=0               # epoch: skip reprobe until this time

get_cached_transit() {
	if [ -f "$TRANSIT_CACHE_FILE" ]; then
		local cached
		cached=$(cat "$TRANSIT_CACHE_FILE" 2>/dev/null)
		if [ -n "$cached" ]; then
			echo "$cached"
			return
		fi
	fi
	echo ""
}

save_transit_cache() {
	echo "$1" > "$TRANSIT_CACHE_FILE" 2>/dev/null || true
}

# Increment _transit_fail_count and reprobe if threshold reached.
# Call this after any reconnect failure or anomalous post-reconnect health check.
maybe_reprobe_transit() {
	# Skip if in all-down cooldown (timestamp-based, non-blocking)
	if [ "${_transit_cooldown_until:-0}" -gt 0 ] && [ "$(date +%s)" -lt "$_transit_cooldown_until" ]; then
		return
	fi
	_transit_cooldown_until=0
	_transit_fail_count=$((_transit_fail_count + 1))
	if [ "$_transit_fail_count" -ge "$TRANSIT_REPROBE_AFTER" ]; then
		# Transit grace: skip one reprobe when a recent SERVER_APP_FAILURE
		# proved transit is healthy.  Grace is one-time (consumed on use) and
		# expires after TRANSIT_GRACE_TTL seconds to avoid acting on stale data.
		if [ "${_transit_grace_ts:-0}" -gt 0 ]; then
			local _grace_age=$(( $(date +%s) - _transit_grace_ts ))
			if [ "$_grace_age" -lt "$TRANSIT_GRACE_TTL" ]; then
				log "Transit fail threshold reached, skipping reprobe (SERVER_APP_FAILURE ${_grace_age}s ago)"
				_transit_grace_ts=0
				_transit_fail_count=0
				return
			fi
			log "Transit grace expired (${_grace_age}s >= ${TRANSIT_GRACE_TTL}s), proceeding with reprobe"
			_transit_grace_ts=0
		fi
		log "Transit fail threshold reached, reprobing..."
		local new_transit
		new_transit=$(probe_best_transit)
		cleanup_probe_state
		if [ -n "$new_transit" ]; then
			save_transit_cache "$new_transit"
			log "Transit cache updated: ${new_transit}"
		else
			# All transit candidates unreachable (relay infrastructure down).
			# Set timestamp-based cooldown instead of blocking sleep so the
			# main loop continues health checks and signal handling.
			_transit_cooldown_until=$(( $(date +%s) + TRANSIT_ALLDOWN_WAIT ))
			log "All transits unreachable, cooldown until $(date -d @${_transit_cooldown_until} +%H:%M:%S 2>/dev/null || echo +${TRANSIT_ALLDOWN_WAIT}s)"
		fi
		_transit_fail_count=0
	fi
}

cleanup_probe_state() {
	surflare disconnect >/dev/null 2>&1
	killall surflare-proxy 2>/dev/null
	_stop_proxy_log_monitor
	wait_for_exit surflare-proxy
	if nft list table inet surflare >/dev/null 2>&1; then
		nft flush table inet surflare 2>/dev/null || true
		nft delete table inet surflare 2>/dev/null || true
	fi
	while ip rule del fwmark 0x1 lookup 100 2>/dev/null; do :; done
	while ip -6 rule del fwmark 0x1 lookup 100 2>/dev/null; do :; done
	ip route flush table 100 2>/dev/null || true
}

probe_best_transit() {
	if [ ${#TRANSIT_CANDIDATES[@]} -eq 0 ]; then
		echo ""
		return
	fi
	local node best_node="" best_ms=999999
	local _probe_idx=0 _probe_total=${#TRANSIT_CANDIDATES[@]}
	for node in "${TRANSIT_CANDIDATES[@]}"; do
		_probe_idx=$((_probe_idx + 1))
		if [ "${_active_node:-$NODE}" = "$node" ]; then
			log "Probing transit candidate: ${node} (${_probe_idx}/${_probe_total}) -- skipped (same as node)"
			continue
		fi
		log "Probing transit candidate: ${node} (${_probe_idx}/${_probe_total})"
		if ! timeout "$TRANSIT_CONNECT_TIMEOUT" surflare connect \
			--node "${_active_node:-$NODE}" --mode "${MODE:-global}" \
			--transit "$node" --daemon >/dev/null 2>&1 9>&- 200>&-; then
			log "Probe ${node}: connect failed"
			cleanup_probe_state
			continue
		fi
		local wait_sec=0
		while [ "$wait_sec" -lt "$TRANSIT_ROUTE_READY_TIMEOUT" ]; do
			_proc_alive surflare-proxy >/dev/null 2>&1 && \
			nft list table inet surflare >/dev/null 2>&1 && \
			ip rule show | grep -q 'fwmark 0x1 lookup 100' && break
			sleep 1
			wait_sec=$((wait_sec + 1))
		done
		if [ "$wait_sec" -ge "$TRANSIT_ROUTE_READY_TIMEOUT" ]; then
			log "Probe ${node}: VPN routing not ready after ${TRANSIT_ROUTE_READY_TIMEOUT}s"
			cleanup_probe_state
			continue
		fi
		sleep "$TRANSIT_PROBE_SETTLE"
		_update_server_endpoint
		_update_killswitch_server_ips
		# Require 200/30x from Google -- local proxy errors (502/503) return
		# instantly and would otherwise produce a falsely-low latency reading.
		local probe_result http_code ms
		probe_result=$(curl -s --connect-timeout 4 --max-time 10 \
			-o /dev/null -w '%{http_code}:%{time_starttransfer}' \
			https://www.google.com 2>/dev/null)
		http_code="${probe_result%%:*}"
		ms="${probe_result##*:}"
		case "$http_code" in
			200|301|302) ;;
			*)
				log "Probe ${node}: health check unreachable (http=${http_code:-none})"
				cleanup_probe_state
				continue
				;;
		esac
		if ! [[ "$ms" =~ ^[0-9]+\.?[0-9]*$ ]]; then
			log "Probe ${node}: non-numeric latency '${ms}'"
			cleanup_probe_state
			continue
		fi
		local ms_int
		ms_int=$(awk "BEGIN {printf \"%.0f\", ${ms} * 1000}" 2>/dev/null)
		if [ -z "$ms_int" ] || [ "$ms_int" -le 0 ] 2>/dev/null; then
			log "Probe ${node}: invalid latency measurement"
			cleanup_probe_state
			continue
		fi
		log "Probe ${node}: ${ms_int}ms"
		if [ "$ms_int" -lt "$best_ms" ]; then
			best_ms=$ms_int
			best_node=$node
		fi
		cleanup_probe_state
	done
	if [ -n "$best_node" ]; then
		log "Best transit: ${best_node} (${best_ms}ms)"
	else
		log "All transit candidates failed, using direct connection"
	fi
	echo "$best_node"
}

# _node_is_log_healthy: return 0 if no recent urltest errors for this node/transit combo.
# Reads /run/surflare_node_health.json written by surflare_log_health.sh (3-min cron).
# Returns 1 (skip) if node has >10 errors in the log window, or if health data unavailable.
_node_is_log_healthy() {
	local node="$1" transit="${2:-}"
	local health_file="/run/surflare_node_health.json"
	[ -f "$health_file" ] || return 0  # no data: assume healthy, let cascade decide
	# Skip if health file is stale (>20 min)
	local age
	age=$(( $(date +%s) - $(stat -c %Y "$health_file" 2>/dev/null || echo 0) ))
	[ "$age" -gt 1200 ] && return 0  # stale: assume healthy
	# Construct log key: "mh_via_TRANSIT_to_NODE" or just "NODE"
	local log_key
	if [ -n "$transit" ]; then
		log_key="mh_via_${transit}_to_${node}"
	else
		log_key="$node"
	fi
	local err_count
	err_count=$(python3 - "$health_file" "$log_key" << 'PYEOF2'
import json, sys
try:
    with open(sys.argv[1]) as _f:
        d = json.load(_f)
    print(d.get("nodes", {}).get(sys.argv[2], {}).get("error_count", 0))
except Exception:
    print(0)
PYEOF2
) 2>/dev/null || err_count=0
	if [ "${err_count:-0}" -gt 10 ]; then
		log "LOG_HEALTH: skipping ${node} via ${transit:-direct} (${err_count} recent errors)"
		return 1  # unhealthy, skip
	fi
	return 0  # healthy
}

_rotate_node() {
	local n=${#NODE_CANDIDATES[@]}
	if [ "$n" -le 1 ]; then
		return
	fi
	local prev="${_active_node}"
	local effective_transit
	effective_transit=$(cat "$TRANSIT_CACHE_FILE" 2>/dev/null) || true
	# Mirror connect_vpn fallback: if cache absent, use first transit candidate
	if [ -z "$effective_transit" ] && [ ${#TRANSIT_CANDIDATES[@]} -gt 0 ]; then
		effective_transit="${TRANSIT_CANDIDATES[0]}"
	fi
	local tried=0
	while [ "$tried" -lt "$n" ]; do
		_node_idx=$(( (_node_idx + 1) % n ))
		tried=$((tried + 1))
		if [ -n "$effective_transit" ] && \
		   [ "${NODE_CANDIDATES[$_node_idx]}" = "$effective_transit" ]; then
			continue
		fi
		# Skip nodes with recent urltest errors (log-based real-time health)
		if ! _node_is_log_healthy "${NODE_CANDIDATES[$_node_idx]}" "$effective_transit"; then
			continue
		fi
		break
	done
	# Verify the selected node is actually healthy (not a fallthrough to unhealthy)
	if ! _node_is_log_healthy "${NODE_CANDIDATES[$_node_idx]}" "$effective_transit"; then
		log "WARN: all nodes unhealthy, keeping ${prev} (skipped ${_active_node})"
		_active_node="$prev"
		# All nodes unhealthy: connect_vpn will check surflare status
		# for auth need before reconnecting.
	else
		_active_node="${NODE_CANDIDATES[$_node_idx]}"
	fi
	log "Node rotation: ${prev} -> ${_active_node} ($((_node_idx + 1))/${n})"
	_stats_rotations=$((_stats_rotations + 1))
	printf '%s\t%d\n' "$_active_node" "$_node_idx" > "$ROTATION_STATE" 2>/dev/null || true
}

connect_vpn() {
	# flock prevents concurrent calls from watchdog loop and systemd-sleep post hook
	(
		flock -n 9 || {
			log "connect_vpn already running, skipping"
			exit 2
		}

		# Rollback flag: use_legacy_settle reverts O1 to fixed sleep
		local _use_poll
		if [ -f /etc/surflare/use_legacy_settle ]; then
			_use_poll=0
		else
			_use_poll=1
		fi

		# Tombstone FIRST -- before any proxy teardown.  The window between
		# proxy death and tombstone causes ECONNREFUSED for LAN CN traffic
		# (tproxy rules still active, :10800 dead).  Tombstoning before
		# disconnect covers the entire teardown window.
		_tombstone_tproxy

		log "Tombstoning tproxy, disconnecting, flushing nftables..."
		if ! surflare disconnect 2>/dev/null; then
			log "disconnect returned non-zero (may not have been connected), continuing cleanup..."
		fi
		sleep "$DISCONNECT_SETTLE"

		log "Killing remaining processes..."
		killall surflare surflare-proxy sexpect 2>/dev/null
		wait_for_exit surflare
		wait_for_exit surflare-proxy

		# Stop the proxy log monitor and clear 503 storm state.  Without
		# this, the old 503 count persists across reconnects and causes
		# every post-reconnect health check to immediately re-trigger
		# PROXY_BROKEN, cascading through all nodes without recovery.
		_stop_proxy_log_monitor

		# Flush ALL conntrack entries after proxy death.  The scoped
		# flush (mark 1) in _unarm_killswitch_output only clears
		# tproxy-marked flows, but proxy upstream connections via
		# loopback (src=127.0.0.1) carry no mark and persist for
		# tcp_timeout_established=7440s, eventually saturating the
		# table and causing "too many open files" on the next proxy.
		# Tombstone (REJECT) is active so no LAN traffic is flowing;
		# the flush is safe and the table rebuilds on reconnect.
		if conntrack -F >/dev/null 2>&1; then
			log "conntrack flushed (full table, proxy dead, tombstone active)"
		else
			log "WARN: conntrack flush failed; stale entries may persist"
		fi

		# Flush residual nftables/routing rules that surflare disconnect may have missed.
		# Without this, all TCP/UDP traffic stays fwmark'd -> routed to table 100 -> loopback
		# -> ECONNREFUSED, causing "Account check failed" on the next connect attempt.
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
		while ip -6 rule del fwmark 0x1 lookup 100 2>/dev/null; do
			rule_count=$((rule_count + 1))
		done
		[ "$rule_count" -gt 0 ] && log "Removed ${rule_count} residual ip rule(s) fwmark 0x1 lookup 100"
		ip route flush table 100 2>/dev/null || true

		# O3 (v3.2): token refresh gated by file timestamp. Runs in
		# direct-routing window (nft flushed, API reachable via ISP).
		# File-based because this subshell's variable updates are lost on exit.
		# Only writes timestamp on success; failure must not suppress retry.
		# Reactive auth: binary manages JWT renewal (detour_refresh.go).
		# Watchdog only calls refresh_auth when binary reports auth needed.
		# Three triggers: (1) not logged in, (2) session expired,
		# (3) subscription expired (log only, do not refresh).
		# Known limitation: if binary renewal fails silently (no disconnect),
		# watchdog has no detection mechanism.  Accepted tradeoff: binary
		# is observed to disconnect on renewal failure ("Session renewal
		# failed, disconnecting VPN"), so silent failure is unlikely.
		rm -f /run/surflare_urltest_all_unhealthy 2>/dev/null  # transitional: previous version created this
		local _auth_status _status_rc=0 _need_auth=0
		_auth_status=$(timeout 5 surflare status 2>&1) || _status_rc=$?
		if [ "$_status_rc" -eq 124 ]; then
			# timeout: binary hung or not running -- auth likely needed
			log "connect_vpn: surflare status timed out (rc=124)"
			_need_auth=1
		elif [ "$_status_rc" -ne 0 ]; then
			# non-zero exit: binary errored -- treat as auth needed
			log "connect_vpn: surflare status failed (rc=${_status_rc})"
			_need_auth=1
		fi
		# Auth expired flag: proxy log detected "authentication required".
		# Forces _need_auth=1 even if surflare status reports OK.
		# Flag cleared HERE (single clear point, no race with main loop).
		if [ -f /run/surflare_auth_expired ]; then
			log "connect_vpn: auth expired (proxy reported authentication required)"
			_need_auth=1
			rm -f /run/surflare_auth_expired
		fi
		# Check subscription first (do NOT refresh, just log)
		if echo "$_auth_status" | grep -qiE "subscription.*not active|not active.*subscription"; then
			log "WARN: subscription expired, manual renewal required"
			log "Visit https://www.surflare.com to renew"
			echo "subscription" > /run/surflare_auth_fail_signal 2>/dev/null || true
		elif [ "$_need_auth" -eq 1 ] \
		   || echo "$_auth_status" | grep -qiE "not logged in|session expired|not authenticated"; then
			log "connect_vpn: auth needed (status_rc=${_status_rc})"
			refresh_auth
			_auth_rc=$?
			if [ "$_auth_rc" -eq 0 ]; then
				date +%s > "$LAST_REFRESH_FILE"
			elif [ "$_auth_rc" -eq 2 ]; then
				log "refresh_auth FATAL (rate-limit/creds/expired), signaling parent"
				echo "fatal" > /run/surflare_auth_fail_signal 2>/dev/null || true
			else
				log "refresh_auth failed (retryable), will retry next cycle"
				echo "retryable" > /run/surflare_auth_fail_signal 2>/dev/null || true
			fi
		fi

		if [ -f "/sys/class/net/${WIFI_INTERFACE}/threaded" ] && \
		   [ "$(cat "/sys/class/net/${WIFI_INTERFACE}/threaded" 2>/dev/null)" != "1" ]; then
			echo 1 > "/sys/class/net/${WIFI_INTERFACE}/threaded" 2>/dev/null || true
		fi

		local effective_transit="$TRANSIT"
		if [ ${#TRANSIT_CANDIDATES[@]} -gt 0 ] && [ -z "$TRANSIT" ]; then
			effective_transit=$(get_cached_transit)
			[ -z "$effective_transit" ] && effective_transit="${TRANSIT_CANDIDATES[0]}"
			log "Using transit: ${effective_transit} (from cache or first candidate)"
		fi
		local use_node="${_active_node:-$NODE}"
		if [ -n "$effective_transit" ] && [ "$use_node" = "$effective_transit" ]; then
			log "Skipping transit ${effective_transit} (same as node), using direct"
			effective_transit=""
		fi
		printf '%s\n' "${effective_transit:-off}" > /run/surflare_last_transit 2>/dev/null || true
		# Unarm killswitch output chain for API access, forward chain
		# stays intact.  Only the output chain (policy drop) is removed
		# so surflare connect can reach its API.  The forward chain
		# continues blocking non-whitelisted LAN forwarding throughout.
		# After connect, _reinstall_killswitch_output recreates the
		# output chain without touching sets or forward chain.
		local _ks_was_armed=0
		if nft list table inet killswitch >/dev/null 2>&1; then
			_unarm_killswitch_output
			_ks_was_armed=1
			log "connect_vpn: killswitch output unarmed for API access"
		fi
		log "Connecting to ${use_node} mode=${MODE:-global} transit=${effective_transit:-off} (daemon mode)..."
		# Raise fd limit before spawning the proxy process.  procd_set_param
		# limits in init.d sets rlimit on the watchdog script, but
		# surflare connect --daemon daemonizes and may break fork inheritance.
		# So this best-effort bump is NOT sufficient alone; the real
		# guarantee is the ulimit in the wrapper, run in the proxy exec.
		ulimit -n 65535 2>/dev/null || true
		if ! surflare connect --node "$use_node" \
			${MODE:+--mode "$MODE"} \
			${effective_transit:+--transit "$effective_transit"} \
			--daemon 9>&- 200>&-; then
			log "Connection failed, will retry on next check cycle"
			[ "$_ks_was_armed" -eq 1 ] && _reinstall_killswitch_output
			return 1
		fi
		if [ "$_ks_was_armed" -eq 1 ]; then
			_reinstall_killswitch_output
			log "connect_vpn: killswitch output reinstalled after connect"
		fi
		# Load CN output bypass immediately after Phase 1 table creation.
		# surflare connect has already created inet surflare with the output
		# chain catchall (mark->reroute->tproxy).  Without cn_output, CN
		# outbound traffic hits the catchall during the Phase 2 data-plane
		# settle window (~60s), causing sing-box loopback rejects.
		# Loading here shrinks the gap from ~2min to <1s.
		_exempt_cn_output
		# The proxy's inet surflare table now handles output routing; killswitch
		# O1 (v3.2): poll-based readiness with data-plane verification.
		# Phase 1: wait for local state (process/nftables/routing).
		# Phase 2: verify data-plane forwarding (surflare ping through tunnel).
		# Uses surflare ping instead of relay connection counting (ss) because
		# relay TCP establishment does not guarantee data forwarding -- auth
		# staleness passes relay count but fails ping.
		if [ "$_use_poll" -eq 1 ]; then
			local _ready_wait=0
			while [ "$_ready_wait" -lt "$CONNECT_SETTLE" ]; do
				if check_vpn_local_state; then
					log "Local state ready after ${_ready_wait}s, waiting for data-plane..."
					break
				fi
				sleep 1
				_ready_wait=$((_ready_wait + 1))
			done
			if [ "$_ready_wait" -ge "$CONNECT_SETTLE" ]; then
				log "VPN establishment timed out: not ready after ${CONNECT_SETTLE}s"
				[ "$_ks_was_armed" -eq 1 ] && _reinstall_killswitch_output
				return 1
			fi
			# Phase 2: verify data-plane forwarding with surflare ping.
			# Replaces relay connection counting (ss), which only checks TCP
			# establishment, not actual forwarding.  When auth is stale the
			# relay accepts TCP handshakes but drops data -- relay count
			# passes but external probes all time out.  surflare ping sends
			# TCP SYN through the tunnel and catches this.
			# Working tunnel: ping returns in 1-2s (first probe succeeds).
			# Broken tunnel: each probe times out after 5s; timeout(1) caps
			# each attempt at 8s to avoid blocking the full 20s.
			# Uses $SECONDS (bash builtin, seconds since shell start) to
			# track wall-clock elapsed time, not loop-counter approximations.
			local _ping_start=$SECONDS _ping_elapsed=0 _ping_ready=0
			while [ "$_ping_elapsed" -lt "$DATAPLANE_SETTLE" ]; do
				if timeout 8 surflare ping google.com -p 443 2>&1 \
					| grep -q 'Loss:[[:space:]]*0\.0%'; then
					_ping_elapsed=$((SECONDS - _ping_start))
					_ping_ready=1
					log "Data-plane ready: ping OK after ${_ping_elapsed}s"
					break
				fi
				_ping_elapsed=$((SECONDS - _ping_start))
				if [ $((_ping_elapsed % 10)) -eq 0 ] && [ "$_ping_elapsed" -gt 0 ]; then
					local _conn_count
					_conn_count=$(ss -tnp state established 2>/dev/null | grep -c surflare)
					log "Waiting for data-plane: ${_ping_elapsed}s (${_conn_count} surflare conns)"
				fi
				sleep 2
				_ping_elapsed=$((SECONDS - _ping_start))
			done
			if [ "$_ping_ready" -eq 0 ]; then
				log "WARN: data-plane not ready after ${_ping_elapsed}s (limit ${DATAPLANE_SETTLE}s), proceeding anyway"
			fi
			log "VPN ready after ${_ready_wait}s (CONNECT_SETTLE ceiling: ${CONNECT_SETTLE}s, data-plane: ${_ping_elapsed}s)"
		else
			local _settle_start=$SECONDS
			sleep "$CONNECT_SETTLE"
			if ! _proc_alive surflare-proxy >/dev/null 2>&1; then
				log "VPN establishment timed out: surflare-proxy not running after ${CONNECT_SETTLE}s"
				[ "$_ks_was_armed" -eq 1 ] && _reinstall_killswitch_output
				return 1
			fi
			log "VPN settle wait: ${CONNECT_SETTLE}s (actual: $(( SECONDS - _settle_start ))s)"
		fi

		compute_proxy_affinity
		_remove_dns_fallback
		local proxy_pid
		proxy_pid=$(_pids_by_comm surflare-proxy | head -1)
		if [ -n "$proxy_pid" ] && [ -n "$PROXY_CPU_SET" ]; then
			taskset -apc "$PROXY_CPU_SET" "$proxy_pid" >/dev/null 2>&1 &&
				log "Pinned surflare-proxy (PID ${proxy_pid}) to CPUs ${PROXY_CPU_SET}" || true
		fi

		if [ -n "$DESKTOP_CPU_SET" ]; then
			local irq pinned=0
			# shellcheck disable=SC2013  # word-split intentional: iterating over IRQ numbers
			for irq in $(grep iwlwifi /proc/interrupts | awk -F: '{gsub(/^[[:space:]]+/,"",$1); print $1}'); do
				if echo "$DESKTOP_CPU_SET" > "/proc/irq/${irq}/smp_affinity_list" 2>/dev/null; then
					pinned=$((pinned + 1))
				fi
			done
			[ "$pinned" -gt 0 ] && log "Pinned ${pinned} iwlwifi IRQ(s) to CPUs ${DESKTOP_CPU_SET}"
		fi

		_setup_chnroute

		# Load sw_lan_tproxy and killswitch tables immediately after connect.
		# Previously these were only loaded on the first healthy health check
		# cycle, leaving LAN devices without tproxy rules for 30+ seconds.
		if ! nft list table inet sw_lan_tproxy >/dev/null 2>&1; then
			_restore_tproxy
			_update_bypass_devices
		fi
		if ! nft list table inet killswitch >/dev/null 2>&1; then
			_install_killswitch
		fi

		exit 0
	) 9>"$LOCK_FILE"
	return $?
}

# --- Packet trace integration (conditional nflog capture) ---
_trace_active=0
_trace_pcap=""
_trace_tcpdump_pid=""
_trace_table="inet watchdog_trace"
_trace_group=12346

start_packet_trace() {
	[ "${_trace_active:-0}" -eq 1 ] && return 0

	# Ensure nfnetlink_log kernel module is loaded (nft log ... group N
	# requires it; on early boot the module may not be auto-loaded yet,
	# causing nft -f to fail with "No such file or directory").
	modprobe nfnetlink_log 2>/dev/null || true

	local ts
	ts=$(date +%Y%m%d_%H%M%S)
	_trace_pcap="/tmp/surflare_watchdog_${ts}.pcap"

	# Clean stale pcaps (keep last 5, delete older than 30 min)
	find /tmp -name 'surflare_watchdog_*.pcap' -mmin +30 -delete 2>/dev/null || true
	find /tmp -name 'surflare_watchdog_*.pcap.err' -mmin +30 -delete 2>/dev/null || true

	# Defensive cleanup: remove orphaned table from previous SIGKILL
	nft delete table "$_trace_table" 2>/dev/null || true

	# Resolve probe destination IPs (same hosts as check_vpn_health)
	local probe_ips="" ip ips ip_set=""
	for host in google.com www.google.com 1.1.1.1 1.0.0.1 \
	            ifconfig.co icanhazip.com myip.wtf; do
		# Filter to bare IPv4 only: busybox nslookup prints "127.0.0.1:53" (colon
		# format) while GNU nslookup uses "127.0.0.1#53" (hash format).  Both :#
		# variants must be excluded; the original /#/ check missed the colon form,
		# causing "127.0.0.1:53" to enter the nft ip daddr set, which nft parses
		# as a mapping expression -> "mapping outside of map context" -> trace fail.
		ips=$(nslookup "$host" 2>/dev/null \
			| awk '/^Address:/{if ($2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print $2}' \
			| sort -u || true)
		[ -n "$ips" ] && probe_ips="$probe_ips $ips"
	done
	probe_ips=$(echo "$probe_ips" | tr ' ' '\n' | sort -u | tr '\n' ' ')

	if [ -z "$probe_ips" ]; then
		log "Packet trace: cannot resolve any probe IPs, skipping"
		return 1
	fi

	for ip in $probe_ips; do
		ip_set="${ip_set:+$ip_set, }$ip"
	done

	# Bitwise OR preserves surflare's fwmark 0x1 for VPN routing
	if ! nft -f - <<EOF
table $_trace_table {
    chain output {
        type filter hook output priority mangle;
        meta nfproto ipv4 ip daddr { $ip_set } tcp dport { 80, 443 } ct mark set ct mark | 0xface log prefix "WD_TRACE_OUT" group $_trace_group
    }
    chain input {
        type filter hook input priority mangle;
        ct mark & 0xface == 0xface log prefix "WD_TRACE_IN" group $_trace_group
    }
}
EOF
	then
		log "Packet trace: nft rule install failed"
		return 1
	fi

	tcpdump -i "nflog:$_trace_group" -w "$_trace_pcap" \
		2>"${_trace_pcap}.err" &
	_trace_tcpdump_pid=$!

	local ready=0 _si=0
	while [ "$_si" -lt 20 ]; do
		if kill -0 "$_trace_tcpdump_pid" 2>/dev/null; then
			ready=1; break
		fi
		sleep 1
		_si=$((_si + 1))
	done

	if [ "$ready" -eq 1 ]; then
		_trace_active=1
		log "Packet trace started: pcap=$_trace_pcap"
	else
		log "Packet trace failed to start (tcpdump error)"
		nft delete table "$_trace_table" 2>/dev/null || true
		_trace_active=0
	fi
}

stop_packet_trace() {
	[ "${_trace_active:-0}" -eq 0 ] && return 0

	if [ -n "${_trace_tcpdump_pid:-}" ]; then
		kill "$_trace_tcpdump_pid" 2>/dev/null || true
		local waited=0
		while kill -0 "$_trace_tcpdump_pid" 2>/dev/null && [ $waited -lt 10 ]; do
			sleep 1; waited=$((waited + 1))
		done
		kill -0 "$_trace_tcpdump_pid" 2>/dev/null && \
			kill -9 "$_trace_tcpdump_pid" 2>/dev/null || true
		wait "$_trace_tcpdump_pid" 2>/dev/null  # reap zombie
		_trace_tcpdump_pid=""
	fi

	nft delete table "$_trace_table" 2>/dev/null || true
	_trace_active=0
	log "Packet trace stopped: pcap=$_trace_pcap"
}

_manage_trace() {
	local health="$1"
	local is_healthy=0
	case "$health" in
		OK|TUNNEL_OK) is_healthy=1 ;;
		"") ;;
		LOCAL_FAIL|CN) ;;
		*) ;;  # unknown: do not assume healthy
	esac

	if [ "$is_healthy" -eq 1 ]; then
		[ "${_trace_active:-0}" -eq 1 ] && stop_packet_trace
		return 0
	fi

	if [ "$health" = "LOCAL_FAIL" ] || [ "$health" = "TCP_BLOCK" ] || [ "$health" = "PROXY_BROKEN" ]; then
		[ "${_trace_active:-0}" -eq 0 ] && start_packet_trace
	fi
	# CN and "": caller handles fail_count logic, start on first failure
}

_check_trace_alive() {
	[ "${_trace_active:-0}" -eq 0 ] && return 0
	if ! kill -0 "$_trace_tcpdump_pid" 2>/dev/null; then
		log "WARNING: tcpdump died (PID $_trace_tcpdump_pid), cleaning up"
		wait "$_trace_tcpdump_pid" 2>/dev/null  # reap zombie
		nft delete table "$_trace_table" 2>/dev/null || true
		_trace_active=0
		_trace_tcpdump_pid=""
	fi
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
# kill -0 alone is insufficient: kernel PID recycling can make a stale PID
# appear live if an unrelated process reused it (observed: orphan subshell
# held PID after SIGKILL storm, causing false "already running" exit).
# Double-check: the live process must be a surflare_watchdog.sh process.
# /proc/PID/comm is "bash" for shebang-launched scripts (15-char limit),
# so we check /proc/PID/cmdline for the full script path instead.

# Install traps + define cleanup BEFORE any orphan kill.  Without this,
# SIGTERM arriving during Phase 1 (e.g. from a dying orphan's cleanup
# cascade) uses the default handler: silent terminate, no log, no
# teardown.  With traps set, any unexpected SIGTERM is logged and
# cleaned up properly.
storm_sleep_pid=""
_hc_tmp=""
_cleanup_done=0
# Set to 1 only after this process actually acquires the instance lock
# (see the INSTANCE_LOCK block below). A process that loses the race for
# the lock never starts the proxy, never touches nftables, and owns
# nothing that needs tearing down; without this guard cleanup() cannot
# tell that case apart from a real instance stopping, and destroys the
# real instance's live state instead of just exiting quietly.
_instance_lock_acquired=0
cleanup() {
	[ "$_cleanup_done" -eq 1 ] && return 0
	_cleanup_done=1
	if [ "$_instance_lock_acquired" -ne 1 ]; then
		return 0
	fi
	stop_packet_trace >/dev/null 2>&1
	_stop_proxy_log_monitor
	[ -n "$storm_sleep_pid" ] && kill "$storm_sleep_pid" 2>/dev/null
	# shellcheck disable=SC2086
	[ -n "$_hc_tmp" ] && rm -f $_hc_tmp
	# Belt-and-suspenders: remove any leaked health-check temp files from
	# interrupted mktemp sequences (SIGTERM between individual mktemp calls
	# before _hc_tmp is fully populated).
	rm -f /tmp/surflare_hc.* 2>/dev/null
	# Tear down nftables FIRST so forward-chain logging (ks-fwd-mon)
	# stops immediately.  Process kills come after -- they are
	# idempotent and do not need nftables protection at this point.
	if [ -f "$RESTART_MARKER" ]; then
		rm -f "$RESTART_MARKER"
		log "Restart: watchdog exiting, proxy preserved"
		# Zero-kill restart: proxy stays alive with :10800 listening,
		# nft tables intact, relay connection active, tproxy rules in
		# place.  New watchdog instance adopts via _cleanup_on_startup().
		# Kill non-proxy auxiliaries that could conflict with the new
		# watchdog's process management.  surflare-proxy is NOT killed.
		killall sexpect 2>/dev/null || true
		killall -9 surflare 2>/dev/null || true
		killall surflare_route_updater.sh 2>/dev/null || true
	else
		_full_teardown
		log "Stop: full teardown"
		killall surflare-proxy 2>/dev/null || true
		killall sexpect 2>/dev/null || true
		killall -9 surflare 2>/dev/null || true
		killall surflare_route_updater.sh 2>/dev/null || true
	fi
	rm -f "$PIDFILE"
	rm -f "$WATCHDOG_ACK_FILE" 2>/dev/null || true
}

_full_teardown() {
	nft delete table inet killswitch 2>/dev/null
	nft delete table inet sw_lan_tproxy 2>/dev/null
	nft delete table ip dns_enforce 2>/dev/null
	nft delete table inet surflare 2>/dev/null
	nft delete table inet surflare_moat 2>/dev/null
	ip rule del fwmark 0x1 lookup 100 2>/dev/null
	ip -6 rule del fwmark 0x1 lookup 100 2>/dev/null
	rm -f /run/surflare_watchdog.killswitch_ready
	rm -f /run/surflare_watchdog.storm_cool_until
	rm -f "$STORM_503_STATE" "${STORM_503_STATE}.tmp"
}

trap 'log "watchdog stopped"; cleanup; exit 0' INT TERM
trap 'cleanup' EXIT
trap 'log "received SIGHUP (terminal hangup), ignoring"' HUP
trap ':' PIPE  # no-op handler for SIGPIPE (prevents bash exit on broken pipe)

# Single-instance guard (root fix for duplicate-watchdog storms).
# procd respawn (exit on connect) and the cron restart can spawn a second
# watchdog while the first is still alive -- e.g. mid storm-cooldown sleep.
# Without this guard both run concurrent main loops ("N duplicate
# watchdog(s)"), racing nftables/connect and amplifying the storm. A new
# instance that cannot acquire the lock exits immediately, so at most one
# watchdog process is ever active. Separate fd/lockfile from the
# connect_vpn reconnect-mutex (LOCK_FILE / fd 9) so that guard still works.
INSTANCE_LOCK=/run/surflare_watchdog.instance.lock
exec 200>"$INSTANCE_LOCK"
if ! flock -n 200; then
	log "another watchdog instance holds the instance lock, exiting to prevent duplicate"
	exit 1
fi
_instance_lock_acquired=1

# Phase 1: Clean up ALL orphan watchdog processes (PPid=1)
# Restart cycles can accumulate multiple orphan processes that PID file
# tracking misses. Scan all processes, not just the one in PID file.
# CRITICAL: On OpenWrt, procd IS PID 1.  All procd-managed processes
# have PPid=1, which is the normal parent -- NOT an orphan.  We must
# skip $$ (ourselves) and the PID in PIDFILE to avoid self-kill.
_orphan_killed=0
_self_pid=$$
_old_pid_from_file=""
[ -f "$PIDFILE" ] && _old_pid_from_file=$(cat "$PIDFILE" 2>/dev/null)
for _opid in $(pgrep -f surflare_watchdog.sh 2>/dev/null); do
	[ "$_opid" = "$_self_pid" ] && continue
	[ "$_opid" = "$_old_pid_from_file" ] && continue
	# Guard against PID recycling: verify cmdline before killing.
	grep -q surflare_watchdog /proc/"$_opid"/cmdline 2>/dev/null || continue
	_op_ppid=$(awk '/^PPid/{print $2}' /proc/"$_opid"/status 2>/dev/null)
	if [ "$_op_ppid" = "1" ]; then
		log "Orphan watchdog process (PID $_opid), killing"
		kill -TERM "$_opid" 2>/dev/null
		_orphan_killed=$((_orphan_killed + 1))
	fi
done
# Wait for SIGTERM to take effect, then SIGKILL stragglers
if [ "$_orphan_killed" -gt 0 ]; then
	sleep 2
	for _opid in $(pgrep -f surflare_watchdog.sh 2>/dev/null); do
		[ "$_opid" = "$_self_pid" ] && continue
		[ "$_opid" = "$_old_pid_from_file" ] && continue
		grep -q surflare_watchdog /proc/"$_opid"/cmdline 2>/dev/null || continue
		_op_ppid=$(awk '/^PPid/{print $2}' /proc/"$_opid"/status 2>/dev/null)
		if [ "$_op_ppid" = "1" ]; then
			kill -9 "$_opid" 2>/dev/null
		fi
	done
	log "Killed $_orphan_killed orphan watchdog process(es)"
fi

# Phase 2: Check PID file for the most recent tracked process
if [ -f "$PIDFILE" ]; then
	_old_pid=$(cat "$PIDFILE" 2>/dev/null)
	if [ -n "$_old_pid" ] && kill -0 "$_old_pid" 2>/dev/null; then
		# PID file process still alive (skipped in Phase 1, expected
		# to have been stopped by procd); duplicate check will handle it
		log "WARN: previous watchdog $_old_pid still alive after procd stop"
	fi
	rm -f "$PIDFILE"
fi

readonly DETECTOR_ALIVE_FILE="/run/surflare_detector.alive"
readonly WATCHDOG_ACK_FILE="/run/surflare_watchdog.early_ack"

readonly PROBE_ACTIVE_FILE="/run/surflare_probe.active"
PROBE_FRESH_SECONDS=75    # marker older than this => probe dead/hung; reclaim
PROBE_HARD_MAX=360        # absolute cap on deferring to a probe run
_probe_defer_start=0      # epoch of current defer streak (0 = not deferring)

# _probe_active: returns 0 if a legitimate node_probe is running (defer this cycle).
# Returns 1 if no probe, or marker is stale/over-long (watchdog reclaims session).
_probe_active() {
    [ -f "$PROBE_ACTIVE_FILE" ] || { _probe_defer_start=0; return 1; }
    local now mtime age
    now=$(date +%s)
    mtime=$(stat -c %Y "$PROBE_ACTIVE_FILE" 2>/dev/null || echo 0)
    age=$(( now - mtime ))
    if [ "$age" -gt "$PROBE_FRESH_SECONDS" ]; then
        log "node_probe marker stale (age=${age}s); reclaiming session"
        _pids_by_comm surflare_node_probe | while read -r _spid; do kill "$_spid" 2>/dev/null; done; true
        rm -f "$PROBE_ACTIVE_FILE"
        _probe_defer_start=0
        return 1
    fi
    [ "$_probe_defer_start" -eq 0 ] && _probe_defer_start="$now"
    if [ $(( now - _probe_defer_start )) -gt "$PROBE_HARD_MAX" ]; then
        log "node_probe held session > ${PROBE_HARD_MAX}s; force-reclaiming"
        _pids_by_comm surflare_node_probe | while read -r _spid; do kill "$_spid" 2>/dev/null; done; true
        rm -f "$PROBE_ACTIVE_FILE"
        _probe_defer_start=0
        return 1
    fi
    return 0
}

run_health_check_now=0

# Register USR1 trap BEFORE writing the PID file so the detector cannot
# read the PID and signal us before the trap is in place.
trap '
    run_health_check_now=1
    _export_diag_pending=1
    [[ -n "${storm_sleep_pid:-}" ]] && { kill "$storm_sleep_pid" 2>/dev/null || true; }
    touch "$WATCHDOG_ACK_FILE" 2>/dev/null || true
    log "EARLY_WARN_TRIGGERED: detector requested immediate health check"
    _report_stats 2>/dev/null || true
' USR1

# USR2: diagnostic mode -- pause the main loop WITHOUT tearing down
# nftables protections.  Allows manual surflare CLI diagnosis while
# killswitch/tproxy/moat stay active.  Send SIGUSR2 again to resume.
_diag_mode=0
trap '
    if [ "$_diag_mode" -eq 0 ]; then
        _diag_mode=1
        log "DIAGNOSTIC MODE: main loop paused (nft protections active). Send SIGUSR2 to resume."
    else
        _diag_mode=0
        log "DIAGNOSTIC MODE: resumed"
    fi
' USR2

echo $$ >"$PIDFILE"
taskset -pc 0 $$ >/dev/null 2>&1 || true

# Self-heal: kill duplicate watchdog instances from procd respawn race.
# procd respawn can start a new instance between init stop and start,
# creating two parallel main loops.  Wait 3s for any late spawns to
# initialise, then kill orphans (PPid=1). No stdin filter: procd starts
# services with stdin=/dev/null, so a stdin=pipe filter would miss every
# real orphan. Legitimate children of $$ have PPid=$$, never 1, so PPid=1
# alone avoids hitting connect_vpn subshells.
sleep 3
for _dup in $(pgrep -f surflare_watchdog.sh 2>/dev/null); do
	[ "$_dup" = "$$" ] && continue
	_dup_ppid=$(awk '/^PPid/{print $2}' /proc/"$_dup"/status 2>/dev/null)
	[ "$_dup_ppid" != "1" ] && continue
	kill -9 "$_dup" 2>/dev/null && \
		log "Startup: killed duplicate watchdog PID $_dup"
done

# Clean up orphaned trace table from previous SIGKILL
nft delete table inet watchdog_trace 2>/dev/null || true
_startup_cleanup_dns_fallback
_patch_surflare_icmp_lan

fail_count=0
reconnect_count=0
transient_count=0
_DNS_RESTART_TIMES=""                 # space-separated epoch timestamps for rate limiter
auth_fail_count=0
_cn_consecutive=0                    # consecutive CN exit detections across node rotations
_healthy_consecutive=0               # consecutive OK checks for failback gate
_alert_last_ts=0                     # rate limiter for _send_alert (epoch)
                                     # Auth is reactive: no background refresh, no periodic timer.
                                     # Binary manages JWT renewal; watchdog refreshes only on detected need.
last_heartbeat=$(date +%s)
_stats_reconnects=0
_stats_rotations=0
_stats_degraded=""
_stats_start_ts=$(date +%s)
_stats_last_report=$(date +%s)
_tproxy_503_cooldown_until=0
_tproxy_503_rotate_ts=0
STATS_REPORT_INTERVAL=21600  # 6h
_fw4_last_check=$(date +%s)
FW4_CHECK_INTERVAL=300        # 5 min
_fw4_last_restart_ts=0
FW4_RESTART_COOLDOWN=900      # 15 min, avoid thrashing repeated restarts
_active_node="$NODE"
_node_idx=0
if [ -f "$ROTATION_STATE" ]; then
	IFS=$'\t' read -r _saved_node _saved_idx < "$ROTATION_STATE" 2>/dev/null || true
	if [ -n "$_saved_node" ] && [ -n "$_saved_idx" ]; then
		_valid=0
		for _i in "${!NODE_CANDIDATES[@]}"; do
			if [ "${NODE_CANDIDATES[$_i]}" = "$_saved_node" ]; then
				_valid=1
				break
			fi
		done
		if [ "$_valid" -eq 1 ]; then
			_active_node="$_saved_node"
			_node_idx="$_i"
			log "Restored rotation state: ${_active_node} ($((_node_idx + 1))/${#NODE_CANDIDATES[@]})"
		else
			log "Saved node '${_saved_node}' not in NODE_CANDIDATES, starting from ${NODE}"
		fi
	fi
fi
_ppid=$(awk '/^PPid/{print $2}' /proc/$$/status 2>/dev/null)
_parent=$(cat /proc/"${_ppid:-0}"/comm 2>/dev/null || echo "?")
log "watchdog started: ppid=${_ppid}(${_parent}) node=${_active_node} candidates=${#NODE_CANDIDATES[@]} interval=${CHECK_INTERVAL}s threshold=${FAIL_THRESHOLD} transient=${TRANSIENT_THRESHOLD}"

# Binary hash verification (warn-only, md5-gate in wrapper provides functional protection)
_real_md5=$(md5sum /usr/bin/surflare-proxy.real 2>/dev/null | awk '{print $1}')
_expected_md5=$(grep '^EXPECTED_MD5=' /usr/bin/surflare-proxy 2>/dev/null | cut -d'"' -f2)
log "STARTUP: surflare-proxy.real md5=${_real_md5:-MISSING}"
if [ -n "$_real_md5" ] && [ -n "$_expected_md5" ] && [ "$_real_md5" != "$_expected_md5" ]; then
	log "WARN: binary hash mismatch (expected=$_expected_md5, got=$_real_md5)"
fi

# Fetch ISP public IP BEFORE killswitch/VPN setup.
# Used to distinguish CN exit: tunnel broken (IP == ISP) vs tunnel working (IP != ISP).
_get_isp_ip || log "WARN: ISP IP unavailable, CN exit will be treated as failure"

_killswitch_armed=0
_setup_kernel_moat
_cleanup_on_startup
_ensure_smartdns_loader_fix

# Load dns_enforce + killswitch at startup (neither depends on proxy).
# dns_enforce FIRST: without it, killswitch forward policy-drop silently
# blackholes LAN DNS to external servers (slow timeout vs fast reject).
# sw_lan_tproxy is NOT loaded here: it tproxies LAN traffic to :10800,
# but surflare-proxy is not running yet.  Loaded after connect_vpn.
_ensure_dns_enforce || true
if ! nft list table inet killswitch >/dev/null 2>&1; then
	if _install_killswitch; then
		_killswitch_armed=1
		log "Startup: killswitch installed"
	else
		log "WARN: startup killswitch install failed"
	fi
fi

log "Startup nftables: killswitch=$(_table_exists killswitch) dns_enforce=$(_table_exists dns_enforce) surflare_moat=$(_table_exists surflare_moat)"

# Track CIDR file mtimes so the main loop can reload cn_direct
# when surflare_route_updater.sh updates the files (cron 02:30 daily).
# Max of all three files: cn_ipv4.txt, cn_ipv4_extra.txt, cn_ipv6.txt.
_cn_direct_mtime=$(stat -c %Y /etc/surflare/cn_ipv4.txt /etc/surflare/cn_ipv4_extra.txt /etc/surflare/cn_ipv6.txt 2>/dev/null | sort -rn | head -1)
: "${_cn_direct_mtime:=0}"

# --source-only: define functions but do not enter main loop.
# Used by test harnesses (Plan 03-04) to source this file.
if [ "${_SOURCE_ONLY:-0}" -eq 1 ]; then
	# shellcheck disable=SC2317  # return works when sourced, exit when executed
	return 0 2>/dev/null || exit 0
fi

while true; do
	# Diagnostic mode: pause without tearing down protections.
	# SIGUSR2 toggles _diag_mode; while active, the loop sleeps
	# and skips all health checks/reconnects.  nft tables stay up.
	if [ "${_diag_mode:-0}" -eq 1 ]; then
		sleep "$CHECK_INTERVAL" & storm_sleep_pid=$!
		wait "$storm_sleep_pid" || true
		storm_sleep_pid=""
		continue
	fi
	# Change 6: probe defer guard -- skip entire cycle when node_probe holds the session
	if _probe_active; then
		log "node_probe active; deferring health check + reactions this cycle"
		sleep "$CHECK_INTERVAL" & storm_sleep_pid=$!
		wait "$storm_sleep_pid" || true
		storm_sleep_pid=""
		continue
	fi
	# Wrapper integrity: surflare auto-update can overwrite the wrapper
	# script at /usr/bin/surflare-proxy with an ELF binary, bypassing
	# md5-gate. Restore from backup if replaced.
	if [ -f /usr/bin/surflare-proxy ] && \
	   [ "$(head -c2 /usr/bin/surflare-proxy 2>/dev/null)" != "#!" ]; then
		if [ -x /usr/local/lib/surflare-proxy-wrapper ]; then
			cp /usr/local/lib/surflare-proxy-wrapper /usr/bin/surflare-proxy
			log "WRAPPER_REPLACED: restored from /usr/local/lib/surflare-proxy-wrapper"
		else
			log "WRAPPER_REPLACED: no backup available"
		fi
	fi
	# Detector liveness: warn if heartbeat file is stale.
	# Skip on router: early_detector requires nm-online (laptop only),
	# so the heartbeat file never updates on procd/OpenWrt.
	if [ "$PLATFORM" != "router" ]; then
		_det_age=$(( $(date +%s) - $(stat -c %Y "$DETECTOR_ALIVE_FILE" 2>/dev/null || echo 0) ))
		if [[ -f "$DETECTOR_ALIVE_FILE" ]] && (( _det_age > 75 )); then
			log "WARN: early_detector_stale age=${_det_age}s -- P0 coverage degraded"
		fi
		unset _det_age
	fi
	# Reload cn_direct when surflare_route_updater updates any CIDR file.
	# All nft operations stay in the watchdog process (no cross-process race).
	_cn_cur=$(stat -c %Y /etc/surflare/cn_ipv4.txt /etc/surflare/cn_ipv4_extra.txt /etc/surflare/cn_ipv6.txt 2>/dev/null | sort -rn | head -1)
	: "${_cn_cur:=0}"
	if [ "$_cn_cur" -gt "$_cn_direct_mtime" ] \
	   && nft list set inet sw_lan_tproxy cn_direct >/dev/null 2>&1; then
		_load_tproxy_cn_direct && _cn_direct_mtime=$_cn_cur
	fi
	unset _cn_cur
	if recent_wifi_crash 120; then
		record_crash
		if crash_rate_exceeded; then
			log "Crash cascade: ${CRASH_MAX_PER_WINDOW} crashes in ${CRASH_WINDOW}s, cooldown ${CRASH_EXTENDED_COOLDOWN}s"
			sleep "$CRASH_EXTENDED_COOLDOWN" &
			storm_sleep_pid=$!; wait "$storm_sleep_pid"; storm_sleep_pid=""
			_crash_timestamps=""
			continue
		fi
		log "iwlwifi crash detected, waiting ${CRASH_COOLDOWN}s for stabilization"
		sleep "$CRASH_COOLDOWN" &
		storm_sleep_pid=$!; wait "$storm_sleep_pid"; storm_sleep_pid=""
		if recent_wifi_crash 10; then
			log "Firmware still crashing after cooldown, deferring reconnect"
			sleep "$CHECK_INTERVAL" & storm_sleep_pid=$!; wait "$storm_sleep_pid"; storm_sleep_pid=""
			continue
		fi
		log "Firmware stable, triggering VPN reconnect"
		[ "${_trace_active:-0}" -eq 0 ] && start_packet_trace
		connect_vpn
		rc=$?
		_block_unreachable_doh
		if [ "$rc" -eq 2 ]; then
			log "Post-crash reconnect skipped (flock held), will retry next cycle"
		elif [ "$rc" -eq 0 ]; then
			new_health=$(check_vpn_health)
			log "Post-crash reconnect health: ${new_health:-failed}"
			if [ "$new_health" = "OK" ] || \
			   { ! _health_is_failure "$new_health" && [ -n "$new_health" ]; }; then
				fail_count=0
				reconnect_count=0
				transient_count=0
				_remove_dns_fallback
				_update_server_endpoint
				if [ "$_killswitch_armed" -eq 0 ]; then
					if _install_killswitch; then
						_killswitch_armed=1
					else
						log "WARN: post-crash killswitch install failed -- IP leak protection inactive"
					fi
				fi
				_update_killswitch_server_ips
				_restore_tproxy
				_block_unreachable_doh
				_update_bypass_devices
				_patch_surflare_icmp_lan
				_record_connect "${_active_node}" "${new_health}"
				_start_proxy_log_monitor
			else
				_healthy_consecutive=0
				fail_count=$((fail_count + 1))
			fi
		else
			_healthy_consecutive=0
			reconnect_count=$((reconnect_count + 1))
			log "Post-crash reconnect failed (reconnect_count=${reconnect_count})"
			if [ "$reconnect_count" -ge "$STORM_MAX" ]; then
				_enter_storm_cooldown "post-crash"
			fi
		fi
		sleep "$CHECK_INTERVAL" & storm_sleep_pid=$!; wait "$storm_sleep_pid"; storm_sleep_pid=""
		continue
	fi

	_auth_expired_this_cycle=0
	# Auth expired flag: short-circuit to connect_vpn with auth refresh.
	# connect_vpn clears the flag (single clear point). sleep 1 prevents
	# busy-loop if connect_vpn returns rc=2 (flock busy).
	# Do NOT reset _auth_expired_this_cycle here -- the diagnosis engine
	# needs to see it if health is still bad after the refresh attempt.
	# The variable is re-initialized to 0 at the top of each loop iteration.
	if [ -f /run/surflare_auth_expired ]; then
		_auth_expired_this_cycle=1
		log "Auth expired signal detected, forcing reconnect with auth refresh"
		connect_vpn
		sleep 1
	fi

	health=$(check_vpn_health)

	# -- Classify health result ----------------------------------------------
	if [ "$health" = "LOCAL_FAIL" ]; then
		# Local VPN state lost (process/nftables/routing gone) -- definitive failure,
		# no network uncertainty. Skip accumulation and force reconnect immediately.
		log "Local VPN state lost (process/nftables/routing), triggering immediate reconnect"
		if nft list table inet surflare >/dev/null 2>&1; then
			nft flush table inet surflare 2>/dev/null || true
			nft delete table inet surflare 2>/dev/null || true
			_stale=0
			while ip rule del fwmark 0x1 lookup 100 2>/dev/null; do _stale=$((_stale+1)); done
			while ip -6 rule del fwmark 0x1 lookup 100 2>/dev/null; do _stale=$((_stale+1)); done
			ip route flush table 100 2>/dev/null || true
			log "Flushed stale nftables/routing (${_stale} rule(s))"
		fi
		_export_diag_state "$health"
		_run_advisory_diagnosis "$health" "" "$_auth_expired_this_cycle"
		_send_diagnosis_alert "$health"
		transient_count=0
		_cn_consecutive=0
		_healthy_consecutive=0
		fail_count=$FAIL_THRESHOLD

	elif [ "$health" = "TCP_BLOCK" ]; then
		if _control_probe; then
			_diagnose_tunnel_failure
			_record_disconnect
			_detect_blocked_domains
			_export_diag_state "$health"
			_run_advisory_diagnosis "$health" "${_diag_conclusion:-}" "$_auth_expired_this_cycle"
			_send_diagnosis_alert "$health"
			log "Health check TCP block (tunnel confirmed, local network OK), triggering reconnect"
			transient_count=0
			_cn_consecutive=0
			_healthy_consecutive=0
			fail_count=$FAIL_THRESHOLD
		else
			transient_count=$((transient_count + 1))
			_healthy_consecutive=0
			log "Health check TCP block but local network also down, treating as transient ${transient_count}/${TRANSIENT_THRESHOLD}"
		fi

	elif [ "$health" = "PROXY_BROKEN" ]; then
		# Tunnel is healthy (direct probes succeed) but surflare-proxy:10800
		# is not forwarding traffic.  LAN devices would have no connectivity.
		log "Proxy path broken: surflare-proxy:10800 not forwarding, triggering reconnect"
		_export_diag_state "$health"
		_run_advisory_diagnosis "$health" "" "$_auth_expired_this_cycle"
		_send_diagnosis_alert "$health"
		# Capture forensic snapshot BEFORE reconnect tears down proxy
		# state.  Fire-and-forget background; won't delay reconnect.
		if [ -x /usr/local/sbin/diag-proxy-broken.sh ]; then
			/usr/local/sbin/diag-proxy-broken.sh &>/dev/null 9>&- 200>&- &
		fi
		transient_count=0
		_cn_consecutive=0
		_healthy_consecutive=0
		fail_count=$FAIL_THRESHOLD

	elif [ "$health" = "OK" ] || \
	     { ! _health_is_failure "$health" && [ -n "$health" ]; }; then
		# VPN healthy -- Google 200/30x (tunnel working) OR country probe returned non-CN country
		# Clear diagnosis grace timer: tunnel is working, any pending grace is moot
		rm -f /run/surflare_diag_fail_since 2>/dev/null

		# Exit country enforcement BEFORE failback gate -- a blocked exit
		# is NOT a healthy check and must not accumulate toward the gate.
		if [ "$_exit_country_blocked" -eq 1 ]; then
			_exit_country_blocked=0
			_healthy_consecutive=0
			fail_count=$FAIL_THRESHOLD
			log "Exit country enforcement: non-allowed exit, forcing reconnect"
		else
			_healthy_consecutive=$((_healthy_consecutive + 1))
			if [ "$_healthy_consecutive" -ge "$FAILBACK_THRESHOLD" ] || \
			   { [ "${fail_count:-0}" -eq 0 ] && [ "${transient_count:-0}" -eq 0 ]; }; then
				# Gate passed or was never degraded -- reset all counters
				fail_count=0
				reconnect_count=0
				transient_count=0
				_cn_consecutive=0
				_transit_grace_ts=0
				_healthy_consecutive=0
			fi
			# Reset backoff only on genuine recovery, not blocked-exit
			if [ "$FAIL_THRESHOLD" -ne "$FAIL_THRESHOLD_BASE" ]; then
				log "Backoff reset: threshold ${FAIL_THRESHOLD} -> ${FAIL_THRESHOLD_BASE}"
				FAIL_THRESHOLD=$FAIL_THRESHOLD_BASE
			fi
		fi
		_remove_dns_fallback
		_patch_surflare_icmp_lan

		# Ensure sw_lan_tproxy is loaded on first successful connect.
		# Without this, LAN devices have no tproxy rules until the first reconnect.
		if ! nft list table inet sw_lan_tproxy >/dev/null 2>&1; then
			_restore_tproxy
			_update_bypass_devices
		fi
		if [ "$_killswitch_armed" -eq 0 ]; then
			if _install_killswitch; then
				_killswitch_armed=1
			else
				log "WARN: killswitch install failed -- IP leak protection inactive"
			fi
		fi

		# Tproxy health check: detect relay degradation invisible to tunnel probes.
		# node_health.json (written by surflare_log_health.sh every 3 min) tracks
		# tproxy 503 count in a 10-min window.  High 503 rate means relay is
		# returning errors even though the tunnel itself is healthy.
		# Cooldown after rotation: node_health.json is global (not per-node),
		# so stale data from the previous node persists until the cron refreshes.
		# Without cooldown, every rotation immediately re-triggers on stale data.
		_now=$(date +%s)
		if [ "$_now" -ge "${_tproxy_503_cooldown_until:-0}" ] && [ -f "$NODE_HEALTH_FILE" ]; then
			_nh_mtime=$(stat -c %Y "$NODE_HEALTH_FILE" 2>/dev/null || echo 0)
			_nh_age=$(( _now - _nh_mtime ))
			# Skip if file is stale (>600s) or was written before cooldown started
			# (stale data from previous node that the cron hasn't refreshed yet)
			if [ "$_nh_age" -le 600 ] && [ "$_nh_mtime" -ge "${_tproxy_503_rotate_ts:-0}" ]; then
				_tproxy_503=$(grep -o '"http_503": *[0-9]*' "$NODE_HEALTH_FILE" | awk -F': *' '{print $2}')
				if [ "${_tproxy_503:-0}" -ge "$TPROXY_503_ROTATE_THRESHOLD" ]; then
					log "Relay degraded: ${_tproxy_503} tproxy 503 in health window, rotating"
					fail_count=$FAIL_THRESHOLD
					_tproxy_503_cooldown_until=$(( _now + TPROXY_503_COOLDOWN ))
					_tproxy_503_rotate_ts=$_now
				fi
			fi
		fi

		# Periodic heartbeat -- confirms watchdog is alive during long healthy stretches
		now=$(date +%s)
		if [ "${HEARTBEAT_INTERVAL:-0}" -gt 0 ] && [ $((now - last_heartbeat)) -ge "$HEARTBEAT_INTERVAL" ]; then
			log "VPN healthy: exit=${health}"
			last_heartbeat=$now
		fi

	elif [ "$health" = "CN" ]; then
		# CN exit detected: tunnel broken (exit IP == ISP IP).
		# ISP IP baseline check is done in check_vpn_health() at detection time.
		# Track consecutive CN across rotations: if every candidate has been
		# tried (one full rotation), the relay infrastructure is down and
		# further reconnects only add downtime.  Enter storm cooldown instead.
		_export_diag_state "$health"
		transient_count=0
		_healthy_consecutive=0
		_cn_consecutive=$((_cn_consecutive + 1))
		_run_advisory_diagnosis "$health" "" "$_auth_expired_this_cycle"
		_send_diagnosis_alert "$health"
		if [ "$_cn_consecutive" -ge "${#NODE_CANDIDATES[@]}" ]; then
			_enter_storm_cooldown "cn-exit-all-nodes"
			_cn_consecutive=0
		else
			fail_count=$((fail_count + 1))
			log "Health check failed (CN exit, tunnel broken), consecutive count: ${fail_count}, cn_rotation: ${_cn_consecutive}/${#NODE_CANDIDATES[@]}"
		fi

	else
		# health="" -- all external probes timed out; local state was OK (check_vpn_health
		# returns LOCAL_FAIL if local state is bad, so here local is confirmed healthy).
		# This is a transient network spike, not a definitive VPN failure.
		transient_count=$((transient_count + 1))
		_healthy_consecutive=0
		log "Health check transient timeout (local state OK), transient ${transient_count}/${TRANSIENT_THRESHOLD}"
		if [ "$transient_count" -ge 2 ] && [ "$(cat "$DNS_STUCK_FILE" 2>/dev/null || echo 0)" -ge 4 ]; then
			_insert_dns_fallback
		fi
		if [ "$transient_count" -ge "$TRANSIENT_THRESHOLD" ]; then
			if _route_updater_active; then
				# Route updater download window: proxy saturation is expected.
				# Reset transient_count without escalating to fail_count so the
				# watchdog does not cascade-reconnect during bulk downloads.
				transient_count=0
				log "HEALTH_SUPPRESSED: route_updater download window active; transient timeout expected, not escalating"
			elif _control_probe; then
				fail_count=$((fail_count + 1))
				transient_count=0
				log "Transient threshold reached (local network OK), escalating to fail_count: ${fail_count}"
			else
				transient_count=0
				log "Transient threshold reached but local network down, resetting (not escalating)"
			fi
		fi
	fi

	# Periodic stats summary (every 6h, independent of health state)
	_now_stats=${now:-$(date +%s)}
	if [ $((_now_stats - ${_stats_last_report:-0})) -ge "$STATS_REPORT_INTERVAL" ]; then
		_report_stats
		_export_diag_state "${health:-unknown}"
	fi

	# Deferred diag state export (SIGUSR1 sets flag; nft may block in trap)
	if [ "${_export_diag_pending:-0}" -eq 1 ]; then
		_export_diag_state "${health:-unknown}"
		_export_diag_pending=0
	fi

	# Periodic fw4/masquerade health check. LAN-client CN-direct traffic
	# depends on it (see _check_fw4_health); fw4 restarts happen from
	# hotplug events this watchdog has no other visibility into.
	_now_fw4=$(date +%s)
	if [ $((_now_fw4 - ${_fw4_last_check:-0})) -ge "$FW4_CHECK_INTERVAL" ]; then
		_fw4_last_check=$_now_fw4
		_check_fw4_health || _recover_fw4
	fi

	_manage_trace "$health"
	_check_trace_alive
	_run_observability_probes

	# -- Shared reconnect path -----------------------------------------------
	# Triggered by: LOCAL_FAIL (immediate), CN failure, or transient escalation
	if [ "$fail_count" -ge "$FAIL_THRESHOLD" ]; then
		# Sliding window rate limiter: count all reconnects (success or
		# failure) in a 10-min window.  >3 = cycling, cool down.
		# Complements STORM_MAX (which only counts consecutive failures).
		_now_rc=$(date +%s)
		if [ "$_reconnect_window_start" -eq 0 ] || \
		   [ $((_now_rc - _reconnect_window_start)) -ge "$RECONNECT_RATE_WINDOW" ]; then
			_reconnect_window_start=$_now_rc
			_reconnect_window_count=0
		fi
		# Count ALL reconnects (successful or failed).  The primary target
		# is successful-but-short-lived reconnects: CGNAT kills relay 30-60s
		# after connect, health fails, reconnect again.  STORM_MAX only
		# counts consecutive failures and misses this pattern.
		_reconnect_window_count=$((_reconnect_window_count + 1))
		if [ "$_reconnect_window_count" -gt "$RECONNECT_RATE_MAX" ]; then
			log "Reconnect rate exceeded (${_reconnect_window_count}/${RECONNECT_RATE_MAX} in ${RECONNECT_RATE_WINDOW}s)"
			_enter_storm_cooldown "reconnect-rate-limit"
			_reconnect_window_start=0
			_reconnect_window_count=0
		else
			_rotate_node
			# Adaptive backoff: double threshold after each reconnect so
			# relay-wide degradation does not churn through nodes every 2min.
			# Capped at FAIL_THRESHOLD_MAX; reset to base on healthy exit.
			if [ "$FAIL_THRESHOLD" -lt "$FAIL_THRESHOLD_MAX" ]; then
				FAIL_THRESHOLD=$((FAIL_THRESHOLD * 2))
				[ "$FAIL_THRESHOLD" -gt "$FAIL_THRESHOLD_MAX" ] && FAIL_THRESHOLD=$FAIL_THRESHOLD_MAX
				log "Backoff: next reconnect threshold raised to ${FAIL_THRESHOLD}"
			fi
			log "Consecutive failures: ${fail_count}, starting reconnect..."
			_send_alert "VPN reconnecting" "fail=${fail_count} node=${NODE} health=${health}"
			_stats_reconnects=$((_stats_reconnects + 1))
			date +%s > /run/surflare_last_reconnect 2>/dev/null || true
			rm -f /run/surflare_auth_fail_signal 2>/dev/null || true
			connect_vpn
			rc=$?
			_block_unreachable_doh
			# Collect auth-fail signal from connect_vpn subshell (its variables are lost)
			if [ -f /run/surflare_auth_fail_signal ]; then
				_signal_type=$(cat /run/surflare_auth_fail_signal 2>/dev/null)
				rm -f /run/surflare_auth_fail_signal
				if [ "$_signal_type" = "subscription" ]; then
					log "Subscription expired, entering 1h cooldown (reconnect will not help)"
					sleep 3600 &
					storm_sleep_pid=$!; wait "$storm_sleep_pid" || true; storm_sleep_pid=""
					continue
				elif [ "$_signal_type" = "fatal" ]; then
					auth_fail_count=$AUTH_FAIL_THRESHOLD
					log "FATAL auth failure from connect_vpn subshell"
				else
					auth_fail_count=$((auth_fail_count + 1))
					log "Auth failure from connect_vpn subshell (${auth_fail_count}/${AUTH_FAIL_THRESHOLD})"
				fi
				if [ "$auth_fail_count" -ge "$AUTH_FAIL_THRESHOLD" ]; then
					log "Auth failure threshold reached (${auth_fail_count}/${AUTH_FAIL_THRESHOLD}), forcing reconnect"
					fail_count=$FAIL_THRESHOLD
				fi
			fi
			if [ "$rc" -eq 2 ]; then
				# connect_vpn was skipped (another instance holds flock).
				# Reset fail_count to FAIL_THRESHOLD-1 so we retry once next cycle
				# instead of re-triggering every 30s and spamming the log.
				log "Reconnect skipped (flock held), will retry next cycle"
				_healthy_consecutive=0
				fail_count=$((FAIL_THRESHOLD - 1))
			elif [ "$rc" -eq 0 ]; then
				new_health=$(check_vpn_health)
				log "Post-reconnect health: ${new_health:-failed}"
				if [ "$new_health" = "OK" ] || \
				   { ! _health_is_failure "$new_health" && [ -n "$new_health" ]; }; then
					stop_packet_trace >/dev/null 2>&1
					fail_count=0
					reconnect_count=0
					transient_count=0
					auth_fail_count=0
					_cn_consecutive=0
					_transit_fail_count=0
					_transit_grace_ts=0
					_healthy_consecutive=0
					_remove_dns_fallback
					_update_server_endpoint
					if [ "$_killswitch_armed" -eq 0 ]; then
						if _install_killswitch; then
							_killswitch_armed=1
						else
							log "WARN: Kill switch failed to install -- IP leak protection inactive"
						fi
					fi
					_update_killswitch_server_ips
					# Restore LAN tproxy now that the new proxy is ready on :10800.
					_restore_tproxy
					_block_unreachable_doh
					if [ "$POST_RECONNECT_DNS_FLUSH" -eq 1 ] && [ "$PLATFORM" = "router" ]; then
						/etc/init.d/smartdns restart >/dev/null 2>&1 &&
							killall -HUP dnsmasq 2>/dev/null &&
							log "DNS cache flushed after reconnect" || true
					fi
					_update_bypass_devices
					_patch_surflare_icmp_lan
					_record_connect "${_active_node}" "${new_health}"
					_start_proxy_log_monitor
				else
					_healthy_consecutive=0
					reconnect_count=$((reconnect_count + 1))
					log "Post-reconnect health check anomalous (reconnect_count=${reconnect_count})"
					maybe_reprobe_transit
					if [ "$reconnect_count" -ge "$STORM_MAX" ]; then
						# _enter_storm_cooldown already resets all counters
						# (reconnect_count, fail_count, transient_count).
						_enter_storm_cooldown "reconnect-health-anomalous"
					fi
				fi
			else
				_healthy_consecutive=0
				reconnect_count=$((reconnect_count + 1))
				if [ "$rc" -gt 128 ]; then
					log "Reconnect killed by signal $((rc - 128)) (reconnect_count=${reconnect_count})"
				else
					log "Reconnect attempt failed (reconnect_count=${reconnect_count})"
				fi
				maybe_reprobe_transit
				if [ "$reconnect_count" -ge "$STORM_MAX" ]; then
					_enter_storm_cooldown "connect-failure"
					transient_count=0
				fi
			fi
		fi		# closes rate-check else
	fi

	# Sync auto_bypass IPs to dns_enforce (devices may appear/expire between reconnects)
	_sync_dns_enforce_bypass

	# Repopulate bypass_devices if hotplug or firewall restart emptied the set.
	# Cost: one nft list + grep per cycle (~1ms). Full refresh only when empty.
	if [ -s "$BYPASS_LAN_MACS_FILE" ] && \
	   nft list table inet sw_lan_tproxy >/dev/null 2>&1 && \
	   ! nft list set inet sw_lan_tproxy bypass_devices 2>/dev/null | grep -qE '[0-9]+\.[0-9]'; then
		log "bypass_devices empty (hotplug rebuild?), repopulating"
		_update_bypass_devices
	fi

	# Adaptive interval -- shorter poll when degraded for faster recovery.
	# 10s floor: probe overlap possible (7 x 12s max-time) but each cycle
	# uses independent temp files and PIDs -- no correctness issue.
	if [ "${transient_count:-0}" -gt 0 ] || [ "${fail_count:-0}" -gt 0 ]; then
		# DEGRADED: poll local state every 2s for fast failure detection.
		# Full check_vpn_health runs at loop top; this only cuts sleep short
		# when local state is definitively dead (process gone, socket closed).
		_dg_elapsed=0
		storm_sleep_pid=""
		while [ "$_dg_elapsed" -lt "$DEGRADED_INTERVAL" ]; do
			sleep 2 & storm_sleep_pid=$!
			wait "$storm_sleep_pid" || true
			storm_sleep_pid=""
			_dg_elapsed=$((_dg_elapsed + 2))
			if (( run_health_check_now )); then break; fi
			if ! check_vpn_local_state; then
				log "DEGRADED fast-path: local state failed, skipping remaining wait"
				break
			fi
		done
	else
		sleep "$CHECK_INTERVAL" & storm_sleep_pid=$!
		wait "$storm_sleep_pid" || true
		storm_sleep_pid=""
	fi
	if (( run_health_check_now )); then
		run_health_check_now=0
		log "EARLY_WARN: running immediate health check (detector USR1)"
	fi
done
