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
# View logs    : sudo dmesg | grep surflare_watchdog

NODE="Los Angeles"                    # Set to your node tag (run: surflare nodes)
NODE_CANDIDATES=("Los Angeles" "Dallas" "Chicago" "New York")  # Atlanta/Miami excluded: Anthropic Cloudflare WAF hard-blocks their exit IPs (HTTP 403, not JS-challenge); verified 2026-06-17
MODE="global"                         # Connection mode: global, rule, direct
TRANSIT=""                                # Transit server: "" = use TRANSIT_CANDIDATES (logged), "auto" = surflare picks (opaque)
TRANSIT_CANDIDATES=("Dallas" "Chicago" "Atlanta" "Miami" "New York")  # US-only; KR/HK/TW exits trigger Bing cn redirect
TRANSIT_CONNECT_TIMEOUT=12             # max seconds for surflare connect per candidate
TRANSIT_ROUTE_READY_TIMEOUT=15        # max seconds to poll for routing readiness after connect
TRANSIT_PROBE_SETTLE=20              # seconds of quiet time for tunnel handshake after routing ready
CHECK_INTERVAL=30                     # Exit IP check interval in seconds
DEGRADED_INTERVAL=15                  # Shortened interval when degraded (transient/fail > 0)
FAIL_THRESHOLD=4                      # Consecutive failures before reconnect
LOCK_FILE=/run/surflare_watchdog.lock # Mutex lock to prevent concurrent reconnects
PIDFILE=/run/surflare_watchdog.pid    # PID file for reliable daemon shutdown
ROTATION_STATE=/var/tmp/surflare_rotation  # Persists active node across restarts
DIAG_SACK_THRESHOLD=20                # % of packets with SACK blocks to flag transit degradation
DISCONNECT_SETTLE=1                   # seconds after surflare disconnect before killing processes
CONNECT_SETTLE=20                     # seconds after surflare connect --daemon for VPN to establish
POST_READY_SETTLE=2                   # seconds after local routing ready before declaring VPN up
LAST_REFRESH_FILE="/run/surflare_last_refresh"  # cross-subshell token refresh timestamp
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
BYPASS_LAN_DEVICES=""                 # space-separated LAN IPs that skip tproxy (e.g. "192.168.100.147 192.168.100.148")
# One MAC per line; current IP resolved from /tmp/dhcp.leases at connect time
BYPASS_LAN_MACS_FILE="/etc/surflare/bypass-macs.conf"
_diag_server_ips=""                   # space-separated VPN server IPs captured after each successful connect
_diag_connect_time=0                  # epoch seconds of last successful connect
_sess_node=""                         # exit node of current VPN session
_sess_transit=""                      # transit node of current session
_sess_exit=""                         # exit country code of current session
_sess_connect_s=0                     # epoch of current session start
_sess_prev_node=""                    # previous session's exit node
_sess_prev_s=0                        # previous session's lifetime in seconds
_diag_conclusion=""                   # set by _diagnose_tunnel_failure for _record_disconnect
_diag_out=0                           # physical capture outbound packet count
_diag_in=0                            # physical capture inbound packet count
_diag_syn_out=0                       # SYN packets sent (new connection attempts)
_diag_syn_ack=0                       # SYN-ACK received (successful handshakes)
_diag_sack_pct=0                      # % of packets with SACK blocks
_diag_rst_in=0                        # RST packets received from server
EVENT_LOG="/var/log/surflare_events.jsonl"
# Auto-detect WiFi interface; fallback to wlp9s0f0 if iw is unavailable
WIFI_INTERFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
[ -z "$WIFI_INTERFACE" ] && WIFI_INTERFACE="wlp9s0f0"
CRASH_COOLDOWN=60                     # seconds to wait after detecting firmware crash before reconnect
CRASH_MAX_PER_WINDOW=3                # max crashes in CRASH_WINDOW before extended cooldown
CRASH_WINDOW=600                      # seconds window for crash rate limiting
CRASH_EXTENDED_COOLDOWN=300           # seconds extended cooldown after cascade detected
CRASH_DEDUP_INTERVAL=121              # minimum seconds between counting two crashes as distinct (must exceed detection window)

# Platform detection: router (procd/OpenWrt) vs laptop (systemd)
if [ -f /etc/openwrt_release ]; then
	PLATFORM="router"
else
	PLATFORM="laptop"
fi

# Validate NODE is configured (fail fast if placeholder is unchanged)
if [ "$NODE" = "your_node_tag" ]; then
	echo '<3>surflare_watchdog: NODE is not configured. Edit NODE= in the script first.' >/dev/kmsg
	echo "NODE is not configured. Edit NODE= in the script first." >&2
	exit 1
fi

# Must run as root (avoids sudo ticket expiry blocking in background)
if [ "$EUID" -ne 0 ]; then
	echo "Must run as root: sudo $0" >&2
	exit 1
fi

umask 0177
# Restrict new file permissions to 600 (root-only) -- prevents non-root users from
# opening the lock file for reading and holding flock to block reconnects

# Dependency check
# Package reference (if missing, install the corresponding package):
#   curl          -> curl         (all major distros)
#   killall       -> psmisc       (all major distros)
#   pgrep         -> procps-ng / procps
#   flock         -> util-linux   (all major distros)
#   surflare/surflare-proxy -> from surflare installation
# Note: nm-online is optional (NetworkManager package); falls back to sleep 15s.
for cmd in curl killall pgrep flock surflare surflare-proxy python3; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "<3>surflare_watchdog: missing dependency: ${cmd}, exiting" >/dev/kmsg
		exit 1
	fi
done
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

# _proc_alive: returns 0 if any process has /proc/<pid>/comm == _name.
# Replaces pgrep -f / pgrep -x which are unreliable on busybox (known
# -x bug) and pattern-based matching which false-positives on log files
# and monitoring scripts (e.g. "tail -f /var/log/surflare-proxy.log").
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
		[ "$_comm" = "$_name" ] && return 0
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
	for _pid in /proc/[0-9]*; do
		[ -r "$_pid/comm" ] || continue
		_comm=$(cat "$_pid/comm" 2>/dev/null) || continue
		[ "$_comm" = "$_name" ] && echo "${_pid##*/}"
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

PROXY_CPU_SET=""
DESKTOP_CPU_SET=""

_dns_fallback_active=0
_dns_fallback_gw=""
DNS_STUCK_FILE="/run/surflare_dns_stuck"

_cleanup_dns_fallback_rules() {
	local gw="${1:-}"
	[ -z "$gw" ] && return 0
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
	[[ "$gw" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
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
	# upstream filter sends [F.].
	# shellcheck disable=SC2086
	nft add rule inet surflare_moat prerouting \
		tcp flags \& fin == fin tcp window @win_sizes ${_moat_action} 2>/dev/null || \
		nft add rule inet surflare_moat prerouting \
			tcp flags \& fin == fin tcp window 78 ${_moat_action} 2>/dev/null || \
		nft add rule inet surflare_moat prerouting \
			tcp flags \& fin == fin ${_moat_action} 2>/dev/null || moat_rules_ok=0
	# RST injection
	# shellcheck disable=SC2086
	nft add rule inet surflare_moat prerouting \
		tcp flags \& rst == rst tcp window @win_sizes ${_moat_action} 2>/dev/null || \
		nft add rule inet surflare_moat prerouting \
			tcp flags \& rst == rst tcp window 78 ${_moat_action} 2>/dev/null || \
		nft add rule inet surflare_moat prerouting \
			tcp flags \& rst == rst ${_moat_action} 2>/dev/null || moat_rules_ok=0
	# F9: explicitly allow ICMPv6 packet-too-big so PMTUD continues to
	# work even when other ICMPv6 unreachables are being filtered.
	# Without this, IPv6 connections that need to discover a smaller
	# MTU hang indefinitely.
	nft add rule inet surflare_moat prerouting \
		ip6 nexthdr icmpv6 icmpv6 type packet-too-big accept 2>/dev/null || moat_rules_ok=0
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
	if [ "$MODE" != "global" ]; then
		return 0
	fi
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

	if ! nft list table inet surflare >/dev/null 2>&1; then
		log "WARN: inet surflare table not ready, skipping CN bypass"
		return 1
	fi

	local bypass_applied=0

	if [ -f "$cn_v4_file" ]; then
		local cn_count cn_date
		cn_count=$(grep -vc '^#' "$cn_v4_file" 2>/dev/null || echo 0)
		cn_date=$(stat -c '%y' "$cn_v4_file" 2>/dev/null | cut -d' ' -f1)
		log "Applying Chnroute v4: ${cn_count} prefixes (file date: ${cn_date})"

		nft add set inet surflare cn_ipv4 '{ type ipv4_addr; flags interval; }' 2>/dev/null || true
		nft flush set inet surflare cn_ipv4 2>/dev/null || true

		local tmp_nft="/tmp/cn_ipv4_$$.nft"
		{
			printf 'add element inet surflare cn_ipv4 { '
			grep -v '^#' "$cn_v4_file" | grep -v '^[[:space:]]*$' | paste -sd, -
			printf ' }\n'
		} > "$tmp_nft"
		local _v4_ok=0 _v4_try=0
		while [ "$_v4_try" -lt 3 ] && [ "$_v4_ok" -eq 0 ]; do
			if nft -f "$tmp_nft" 2>/dev/null; then _v4_ok=1
			else _v4_try=$((_v4_try+1)); [ "$_v4_try" -lt 3 ] && sleep 2; fi
		done
		if [ "$_v4_ok" -eq 1 ]; then
			nft insert rule inet surflare output ip daddr @cn_ipv4 accept 2>/dev/null || true
			log "Chnroute v4 applied: CN prefixes bypass proxy via output chain"
			bypass_applied=$((bypass_applied + 1))
			if nft list table inet killswitch >/dev/null 2>&1; then
				local tmp_ks_v4="/tmp/ks_bypass_v4_$$.nft"
				{
					printf 'flush set inet killswitch bypass_ipv4\n'
					printf 'add element inet killswitch bypass_ipv4 { '
					grep -v '^#' "$cn_v4_file" | grep -v '^[[:space:]]*$' | paste -sd, -
					printf ' }\n'
				} > "$tmp_ks_v4"
				nft -f "$tmp_ks_v4" 2>/dev/null || \
					log "WARN: kill switch bypass_ipv4 sync failed"
				rm -f "$tmp_ks_v4"
			fi
		else
			log "WARN: Failed to load Chnroute v4 into nftables after 3 attempts; CN bypass not active"
		fi
		rm -f "$tmp_nft"
	fi

	if [ -f "$cn_v6_file" ]; then
		local cn_count_v6 cn_date_v6
		cn_count_v6=$(grep -vc '^#' "$cn_v6_file" 2>/dev/null || echo 0)
		cn_date_v6=$(stat -c '%y' "$cn_v6_file" 2>/dev/null | cut -d' ' -f1)
		log "Applying Chnroute v6: ${cn_count_v6} prefixes (file date: ${cn_date_v6})"

		nft add set inet surflare cn_ipv6 '{ type ipv6_addr; flags interval; }' 2>/dev/null || true
		nft flush set inet surflare cn_ipv6 2>/dev/null || true

		local tmp_nft_v6="/tmp/cn_ipv6_$$.nft"
		{
			printf 'add element inet surflare cn_ipv6 { '
			grep -v '^#' "$cn_v6_file" | grep -v '^[[:space:]]*$' | paste -sd, -
			printf ' }\n'
		} > "$tmp_nft_v6"
		local _v6_ok=0 _v6_try=0
		while [ "$_v6_try" -lt 3 ] && [ "$_v6_ok" -eq 0 ]; do
			if nft -f "$tmp_nft_v6" 2>/dev/null; then _v6_ok=1
			else _v6_try=$((_v6_try+1)); [ "$_v6_try" -lt 3 ] && sleep 2; fi
		done
		if [ "$_v6_ok" -eq 1 ]; then
			nft insert rule inet surflare output ip6 daddr @cn_ipv6 accept 2>/dev/null || true
			log "Chnroute v6 applied: CN v6 prefixes bypass proxy via output chain"
			bypass_applied=$((bypass_applied + 1))
			if nft list table inet killswitch >/dev/null 2>&1; then
				local tmp_ks_v6="/tmp/ks_bypass_v6_$$.nft"
				{
					printf 'flush set inet killswitch bypass_ipv6\n'
					printf 'add element inet killswitch bypass_ipv6 { '
					grep -v '^#' "$cn_v6_file" | grep -v '^[[:space:]]*$' | paste -sd, -
					printf ' }\n'
				} > "$tmp_ks_v6"
				nft -f "$tmp_ks_v6" 2>/dev/null || \
					log "WARN: kill switch bypass_ipv6 sync failed"
				rm -f "$tmp_ks_v6"
			fi
		else
			log "WARN: Failed to load Chnroute v6 into nftables after 3 attempts; CN bypass not active"
		fi
		rm -f "$tmp_nft_v6"
	fi

	if [ "$bypass_applied" -eq 0 ]; then
		log "WARN: no chnroute files; CN bypass disabled"
	fi

	# Load cloud CDN extra bypass (Tencent/Alibaba international nodes).
	# This file is maintained separately from cn_ipv4.txt and never overwritten
	# by the main chnroute update -- it accumulates validated cloud CDN CIDRs.
	local cn_v4_extra_file="/etc/surflare/cn_ipv4_extra.txt"
	if [ -f "$cn_v4_extra_file" ] && \
	   nft list table inet surflare >/dev/null 2>&1; then
		local extra_count extra_date tmp_extra tmp_ks_extra
		extra_count=$(grep -vc '^#' "$cn_v4_extra_file" 2>/dev/null || echo 0)
		extra_date=$(stat -c '%y' "$cn_v4_extra_file" 2>/dev/null | cut -d' ' -f1)
		log "Applying cloud CDN extra bypass: ${extra_count} CIDRs (${extra_date})"
		tmp_extra="/tmp/cn_v4_extra_$$.nft"
		{
			printf 'add element inet surflare cn_ipv4 { '
			grep -v '^#' "$cn_v4_extra_file" | \
				grep -v '^[[:space:]]*$' | paste -sd, -
			printf ' }\n'
		} > "$tmp_extra"
		if nft -f "$tmp_extra" 2>/dev/null; then
			log "Cloud CDN extra bypass applied to surflare cn_ipv4"
		else
			log "WARN: cloud CDN extra bypass load failed (nft error)"
		fi
		rm -f "$tmp_extra"
		if nft list table inet killswitch >/dev/null 2>&1; then
			tmp_ks_extra="/tmp/ks_extra_$$.nft"
			{
				printf 'add element inet killswitch bypass_ipv4 { '
				grep -v '^#' "$cn_v4_extra_file" | \
					grep -v '^[[:space:]]*$' | paste -sd, -
				printf ' }\n'
			} > "$tmp_ks_extra"
			if nft -f "$tmp_ks_extra" 2>/dev/null; then
				log "Cloud CDN extra bypass applied to killswitch bypass_ipv4"
			else
				log "WARN: cloud CDN extra bypass killswitch sync failed"
			fi
			rm -f "$tmp_ks_extra"
		fi
	fi
}

# _cleanup_on_startup: called once at the top of the main loop.
# Unconditionally kill any inherited surflare-proxy and nuke stale
# watchdog-managed nftables state.  This prevents ghost rules from a
# crashed/killed watchdog, and stops orphan proxies from holding
# port 10800 and blocking a fresh connection cycle.
_cleanup_on_startup() {
	# Always kill any existing surflare-proxy: orphans from a previous
	# watchdog instance (crash or unclean restart) hold port 10800 and
	# block the new connection cycle.  The previous "keep healthy proxy"
	# shortcut caused orphans the new watchdog could not manage.
	if _proc_alive surflare-proxy >/dev/null 2>&1; then
		log "Startup: killing inherited surflare-proxy"
		killall surflare-proxy 2>/dev/null
		sleep 2
	fi
	# Port-based cleanup: ensure 10800 is free
	if ss -ltn 2>/dev/null | grep -qE ':10800(\s|$)'; then
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
	log "Startup cleanup: surflare-proxy not running, flushing stale watchdog state"
	nft delete table inet surflare 2>/dev/null || true
	nft delete table ip sw_lan_tproxy 2>/dev/null || true
	ip rule del fwmark 0x1 lookup 100 2>/dev/null || true
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
	# bypass_src: LAN device source IPs that skip tproxy (bypass_devices).
	# Their non-CN traffic is forwarded directly; no log noise needed.
	set bypass_src  { type ipv4_addr; }
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
		meta mark == 0xff accept
		meta mark == 0x1 accept
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
		limit rate 5/second burst 10 packets log prefix "ks-drop: "
		counter drop
	}

	# chain forward: block non-CN IPv6 from LAN devices.
	# surflare is IPv4-only tproxy; without this chain, LAN devices with IPv6
	# (e.g. systemd-resolved bypassing dnsmasq force-AAAA-SOA) reach non-CN
	# IPv6 destinations via CN ISP IPv6, bypassing the VPN entirely.
	# Non-CN IPv4 TCP from regular LAN devices is NOT dropped here: it is
	# intercepted by sw_lan_tproxy PREROUTING and delivered to INPUT (port 10800).
	# bypass_devices traffic (Thunder CN bypass) is intentionally allowed.
	chain forward {
		type filter hook forward priority filter - 10; policy accept;
		ct state established,related accept
		ct state invalid drop
		iifname "br-lan" oifname "br-lan" accept
		# Modem management: LAN devices (e.g. mesh APs) reach the modem
		# via eth0 (physical WAN port).  This traffic never traverses the
		# VPN tunnel and should not trigger ks-fwd-mon log noise.
		iifname "br-lan" oifname "eth0" ip daddr 192.168.1.0/24 accept
		iifname "br-lan" ip daddr @server_ips accept
		# server_ips6 always empty: surflare is IPv4-only; _update_server_endpoint
		# only extracts IPv4 addrs.  Kept as no-op for future IPv6 VPN support.
		iifname "br-lan" ip6 daddr @server_ips6 accept
		iifname "br-lan" ip daddr @bypass_ipv4 accept
		iifname "br-lan" ip6 daddr @bypass_ipv6 accept
		iifname "br-lan" ip saddr @bypass_src accept
		iifname "br-lan" meta nfproto ipv6 reject with icmpv6 addr-unreachable
		iifname "br-lan" limit rate 5/second burst 10 packets log prefix "ks-fwd-mon: "
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

	# Flush stale conntrack entries that predate the new killswitch rules.
	# Done AFTER the atomic nft -f load so the new rules are already
	# governing new connections while old entries are being flushed.
	# Prefer scoped flush (-D -m mark N) to only kill tproxy-marked flows,
	# leaving unrelated connections (LAN, monitoring) untouched.
	# Fall back to unscoped -F on older conntrack (<1.4.4) that lacks -m.
	if conntrack -D -m mark 1 2>/dev/null; then
		: # scoped flush ok
	elif conntrack -F 2>/dev/null; then
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
	# fib daddr type local covers all dnsmasq listen addresses (5+ IPv4,
	# 8+ IPv6) without hardcoding IPs.  Router-originated DNS is unaffected
	# (no iifname "br-lan" match on locally generated packets).
	# Devices in vpn_bypass (populated from auto_bypass + bypass_devices)
	# are exempted: they run their own VPN and use non-router DNS.
	if [ "$PLATFORM" = "router" ] && \
	   ! nft list table ip dns_enforce >/dev/null 2>&1; then
		if nft -f - <<'DNS_EOF'
table ip dns_enforce {
	set vpn_bypass { type ipv4_addr; }
	chain prerouting {
		type filter hook prerouting priority mangle - 20; policy accept;
		iifname "br-lan" meta l4proto { tcp, udp } th dport 53 ip saddr @vpn_bypass accept
		iifname "br-lan" meta l4proto { tcp, udp } th dport 53 fib daddr type local accept
		iifname "br-lan" meta l4proto { tcp, udp } th dport 53 log prefix "dns-bypass: " reject with icmp port-unreachable
	}
}
DNS_EOF
		then
			log "DNS enforcement armed: LAN bypass DNS rejected"
		else
			log "WARN: DNS enforcement table load failed"
		fi
	fi

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
		# Level 3: keep existing set unchanged
		[ -z "$_diag_server_ips" ] && {
			log "CRITICAL: no server IPs from socket or disk; keeping existing set"
			return
		}
	fi
	nft list table inet killswitch >/dev/null 2>&1 || return
	local ip_csv
	ip_csv=$(echo "$_diag_server_ips" | tr ' ' ',')
	# F7: best-effort near-atomic swap of server_ips. True atomic rename
	# is not available in nft (<1.1); the approach is: validate in a
	# scratch table, then flush+add in the production table, then verify.
	# If the add fails after flush (ENOMEM, transient nft error), re-try
	# once from the validated scratch data. If that also fails, log a
	# CRITICAL and leave the set empty (operator must intervene).
	local _ks_tmp="/tmp/ks_swap_$$.nft"
	cat > "$_ks_tmp" << NFTEOF
table inet killswitch_swap {
	set server_ips { type ipv4_addr; }
}
NFTEOF
	if nft -f "$_ks_tmp" 2>/dev/null \
		&& nft add element inet killswitch_swap server_ips "{ $ip_csv }" 2>/dev/null; then
		nft flush set inet killswitch server_ips 2>/dev/null || true
		if ! nft add element inet killswitch server_ips "{ $ip_csv }" 2>/dev/null; then
			log "WARN: server_ips swap-in failed on first attempt; retrying"
			if ! nft add element inet killswitch server_ips "{ $ip_csv }" 2>/dev/null; then
				# Phase 2B: emergency restore from disk (3rd fallback level)
				local _disk_ips=""
				[ -f /etc/surflare/server_ips ] && \
					_disk_ips=$(tr -s ' \t\n' ',' < /etc/surflare/server_ips)
				if [ -n "$_disk_ips" ] && \
				   nft add element inet killswitch server_ips "{ $_disk_ips }" 2>/dev/null; then
					log "WARN: server_ips swap-in failed; restored from disk backup"
				else
					log "CRITICAL: server_ips swap-in failed, disk restore failed; killswitch server_ips is EMPTY"
				fi
			fi
		fi
		nft delete table inet killswitch_swap 2>/dev/null || true
	else
		log "WARN: killswitch server_ips scratch build failed; keeping previous set"
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

_remove_killswitch() {
	nft delete table inet killswitch 2>/dev/null || true
}

# Enter storm-protection cooldown. Called from the three storm trigger
# sites (post-crash, post-reconnect, connect failure) which previously
# duplicated the same ~12 lines. The reason string is logged for forensic
# clarity -- it identifies which storm path actually triggered.
_enter_storm_cooldown() {
	local _reason="$1"
	stop_packet_trace >/dev/null 2>&1
	_remove_dns_fallback
	log "Storm protection triggered (${_reason}): cooling for ${STORM_COOLING}s"
	# Phase 2A: Tombstone mode -- keep killswitch alive (CN bypass stays),
	# replace tproxy with REJECT (no TCP black-hole, no IP leak), flush
	# server_ips so VPN server traffic is also blocked.
	#
	# Before v64: deleted tproxy + killswitch -> 600s IP leak window.
	# Tombstone: killswitch stays armed, overseas gets REJECT (fast fail).
	local _handle
	if nft list table ip sw_lan_tproxy >/dev/null 2>&1; then
		_handle=$(nft -a list chain ip sw_lan_tproxy prerouting 2>/dev/null | \
			awk '/tproxy.*10800/{print $NF; exit}')
		if [ -n "$_handle" ]; then
			if nft replace rule ip sw_lan_tproxy prerouting handle "$_handle" \
				iifname "br-lan" meta l4proto tcp reject with icmp host-unreachable \
				2>/dev/null; then
				log "Tombstone: tproxy replaced with REJECT"
			else
				log "WARN: tombstone tproxy replace failed"
			fi
		else
			# No tproxy rule found (already removed?) -- delete table to avoid stale state
			nft delete table ip sw_lan_tproxy 2>/dev/null || true
		fi
	fi
	# Flush server_ips so VPN server traffic is also blocked by killswitch
	nft flush set inet killswitch server_ips 2>/dev/null || true
	nft flush set inet killswitch server_ips6 2>/dev/null || true
	# Keep killswitch armed -- DO NOT call _remove_killswitch
	# F13: persist cool-until so a watchdog restart mid-cool respects
	# the remaining window.
	_cool_target=$(( $(date +%s) + STORM_COOLING ))
	echo "$_cool_target" > /run/surflare_watchdog.storm_cool_until
	sleep "$STORM_COOLING" &
	# STORM_COOLING is a recovery bound, not a forced pause. The
	# `wait` below returns early if the background sleep is killed
	# (e.g. cleanup() on SIGTERM). For an operator override during
	# a long cool window: `kill -USR1 <watchdog_pid>` will also kill
	# this sleep (cleanup trap only fires on SIGTERM/SIGINT; SIGUSR1
	# falls through to default action which is to terminate the
	# process -- but a foreground trap is not required for the
	# background sleep, which receives the signal directly).
	storm_sleep_pid=$!; wait "$storm_sleep_pid"; storm_sleep_pid=""
	reconnect_count=0
	fail_count=0
	transient_count=0
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
	nft list table ip sw_lan_tproxy >/dev/null 2>&1 || return 0
	nft flush set ip sw_lan_tproxy bypass_devices 2>/dev/null || true
	# Flush bypass_src unconditionally alongside bypass_devices so stale IPs
	# are cleared even when all bypass devices are removed from config.
	nft flush set inet killswitch bypass_src 2>/dev/null || true

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
	[ -z "$all_ips" ] && return 0
	# Deduplicate in case same IP appears in both BYPASS_LAN_DEVICES and MAC file
	all_ips=$(echo "$all_ips" | tr ',' '\n' | sort -u | paste -sd,)
	nft add element ip sw_lan_tproxy bypass_devices "{ $all_ips }" 2>/dev/null || \
		log "WARN: bypass_devices update failed (${all_ips})"
	# Sync bypass device IPs into killswitch bypass_src so their non-CN traffic
	# does not trigger ks-fwd-mon log noise (traffic is forwarded, just not logged).
	# bypass_src was already flushed at function entry; only add elements here.
	if nft list table inet killswitch >/dev/null 2>&1; then
		nft add element inet killswitch bypass_src "{ $all_ips }" 2>/dev/null || \
			log "WARN: kill switch bypass_src sync failed"
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
	nft list table ip dns_enforce >/dev/null 2>&1 || return 0
	local _dns_ips=""
	local _static
	_static=$(nft list set ip sw_lan_tproxy bypass_devices 2>/dev/null \
		| grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | paste -sd,)
	[ -n "$_static" ] && _dns_ips="$_static"
	local _auto
	_auto=$(nft list set ip sw_lan_tproxy auto_bypass 2>/dev/null \
		| grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | paste -sd,)
	[ -n "$_auto" ] && _dns_ips="${_dns_ips:+$_dns_ips,}$_auto"
	_dns_ips=$(echo "$_dns_ips" | tr ',' '\n' | sort -u | paste -sd,)
	nft flush set ip dns_enforce vpn_bypass 2>/dev/null
	if [ -n "$_dns_ips" ]; then
		nft add element ip dns_enforce vpn_bypass "{ $_dns_ips }" 2>/dev/null || \
			log "WARN: dns_enforce vpn_bypass sync failed"
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
	# shellcheck disable=SC2288  # false positive: awk closing brace in single-quoted string
	awk -v d="$dns" -v t="$tcp" -v l="$tls" -v f="$ttfb" \
	'BEGIN{exit !(t+0>0 && l+0<=0)}' && stuck="TCP"
	awk -v d="$dns" -v t="$tcp" -v l="$tls" -v f="$ttfb" \
	'BEGIN{exit !(d+0>0 && t+0<=0)}' && stuck="TCP"
	awk -v d="$dns" -v t="$tcp" -v l="$tls" -v f="$ttfb" \
	'BEGIN{exit !(l+0>0 && f+0<=0)}' && stuck="TLS"
	awk -v d="$dns" -v t="$tcp" -v l="$tls" -v f="$ttfb" \
	'BEGIN{exit !(f+0>0)}' && stuck="TTFB"
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

# check_vpn_health: two-layer check -- local state first, then parallel external probes.
# Returns:
#   "OK"         -- Google 200/30x (VPN is working, tunnel working)
#   "LOCAL_FAIL" -- local VPN state lost (process/nftables/routing gone)
#   <country>    -- country probe returned a country code (non-empty)
#   ""           -- all external probes timed out (but local state was OK = transient)
# "CN" is a valid country code return (VPN up but routing via China = broken exit).
#
# Architecture: "first success wins" -- probes run in parallel; results are polled
# every 1s. As soon as any probe produces a usable result, remaining probes are
# killed and the result is returned immediately. This avoids waiting the full
# max-time when at least one probe succeeds quickly.
check_vpn_health() {
	echo 0 > "$DNS_STUCK_FILE" 2>/dev/null || true
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
	) >"$tmp_g" 2>/dev/null &
	pid_g=$!

	# Probe 2: Cloudflare trace via domain (parse loc= field, no rate limit)
	(
		local _body
		_body=$(curl -s --connect-timeout 5 --max-time 12 \
		     -w '\n%{time_namelookup}:%{time_connect}:%{time_appconnect}:%{time_starttransfer}:%{time_total}' \
		     'https://cloudflare.com/cdn-cgi/trace' 2>/dev/null)
		echo "$_body" | tail -1 >"$tmp_cft"
		echo "$_body" | head -n -1 | awk -F= '/^loc=/{print $2}' | tr -d '[:space:]'
	) >"$tmp_cf" 2>/dev/null &
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
	) >"$tmp_cf2" 2>/dev/null &
	pid_cf2=$!

	# Probe 4: ifconfig.co ISO country code (degrades gracefully on rate limit)
	(
		local _body
		_body=$(curl -s --connect-timeout 5 --max-time 12 \
		     -w '\n%{time_namelookup}:%{time_connect}:%{time_appconnect}:%{time_starttransfer}:%{time_total}' \
		     'https://ifconfig.co/country-iso' 2>/dev/null)
		echo "$_body" | tail -1 >"$tmp_ifct"
		echo "$_body" | head -n -1 | tr -d '[:space:]'
	) >"$tmp_ifc" 2>/dev/null &
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
	) >"$tmp_ich" 2>/dev/null &
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
	) >"$tmp_myip" 2>/dev/null &
	pid_myip=$!

	# Probe 7: SOCKS5 proxy path -- detects G1 blindspot (tunnel dead but external
	# probes succeed because both endpoints exit in same country). Shorter timeout
	# since this is local (127.0.0.1 SOCKS5 -> tunnel -> destination).
	(
		local _raw
		_raw=$(curl -s --proxy socks5h://127.0.0.1:10800 \
		       --connect-timeout 5 --max-time 10 \
		       -o /dev/null \
		       -w '%{http_code}\n%{time_namelookup}:%{time_connect}:%{time_appconnect}:%{time_starttransfer}:%{time_total}' \
		       https://connectivitycheck.gstatic.com/generate_204 2>/dev/null)
		echo "$_raw" | tail -1 >"$tmp_proxyt"
		local code
		code=$(echo "$_raw" | head -1)
		case "$code" in 204|200) echo "OK" ;; esac
	) >"$tmp_proxy" 2>/dev/null &
	pid_proxy=$!

	# --- Early-exit polling loop ---
	# Poll results every 1s. Return as soon as any probe produces a usable result.
	# Maximum wait = max-time (12s), but typically returns in 1-3s when tunnel is healthy.
	local all_pids="$pid_g $pid_cf $pid_cf2 $pid_ifc $pid_ich $pid_myip $pid_proxy"
	local deadline=$((SECONDS + 13))  # 13s absolute deadline (max-time + 1s margin)
	local result=""

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
		# proves the tunnel works. We don't know the country, so return "TUNNEL_OK"
		# which the caller treats same as a non-CN country code (healthy).
		local r_ip
		for tmp_file in "$tmp_ich" "$tmp_myip"; do
			r_ip=$(cat "$tmp_file" 2>/dev/null)
			if [ -n "$r_ip" ]; then
				result="TUNNEL_OK"
				break 2
			fi
		done

		# Check if all probes have already exited (no point polling further)
		local still_running=0
		for pid in $all_pids; do
			if kill -0 "$pid" 2>/dev/null; then
				still_running=1
				break
			fi
		done
		[ "$still_running" -eq 0 ] && break

		# Sleep 1s before next poll (safer than 0.2s for POSIX/busybox compatibility)
		sleep 1
	done

	# Kill remaining probes (some may still be running if we got an early result)
	for pid in $all_pids; do
		kill "$pid" 2>/dev/null
	done
	# shellcheck disable=SC2086
	wait $all_pids 2>/dev/null || true

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
					result="TUNNEL_OK"
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
	# but the SOCKS5 proxy probe COMPLETED with a non-OK result -- tunnel is
	# dead, external probes succeeded because both exit in same country.
	# Only override when proxy probe actually finished (non-empty output).
	# An empty tmp_proxy means the probe was killed before completing (early
	# exit from polling loop) -- not evidence of tunnel failure.
	if [ -n "$result" ] && [ "$result" != "TCP_BLOCK" ] && [ "$result" != "LOCAL_FAIL" ]; then
		local r_proxy
		r_proxy=$(cat "$tmp_proxy" 2>/dev/null)
		if [ -n "$r_proxy" ] && [ "$r_proxy" != "OK" ]; then
			result="TCP_BLOCK"
		fi
	fi

	rm -f "$tmp_g" "$tmp_cf" "$tmp_cf2" "$tmp_ifc" "$tmp_ich" "$tmp_myip" "$tmp_proxy" \
	      "$tmp_gt" "$tmp_cft" "$tmp_cf2t" "$tmp_ifct" "$tmp_icht" "$tmp_myt" "$tmp_proxyt"
	_hc_tmp=""

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
		return 2
	fi

	local i=0 rc=1
	while [ "$i" -lt "$LOGIN_RETRIES" ]; do
		if command -v expect >/dev/null 2>&1; then
			# expect (laptop): PTY-based login via Tcl heredoc
			if timeout 30 expect <<EXPECT_EOF >/dev/null 2>&1
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
			trap 'rm -f "'"$_sock"'"' EXIT
			export _SURFLARE_AUTH_PW="$password"
			if timeout 30 sh -c "
				sexpect -s '$_sock' spawn -t 25 surflare login -u '$email' >/dev/null 2>&1
				sexpect -s '$_sock' expect -t 15 'Password:' >/dev/null 2>&1 || exit 1
				sexpect -s '$_sock' send -env _SURFLARE_AUTH_PW -enter >/dev/null 2>&1
				sexpect -s '$_sock' wait >/dev/null 2>&1
			"; then
				rc=0
			fi
			unset _SURFLARE_AUTH_PW
			rm -f "$_sock"
			trap - EXIT
		else
			log "WARN: neither expect nor sexpect installed; cannot refresh auth"
			unset password
			return 2
		fi
		if [ "$rc" -eq 0 ]; then
			log "Auth token refreshed (attempt $((i + 1))/${LOGIN_RETRIES})"
			break
		fi
		i=$((i + 1))
		[ "$i" -lt "$LOGIN_RETRIES" ] && sleep "$LOGIN_RETRY_DELAY"
	done
	unset password
	if [ "$rc" -ne 0 ]; then
		log "Auth token refresh failed after ${LOGIN_RETRIES} attempts"
	fi
	return "$rc"
}

# _update_server_endpoint: capture ALL public VPN server IPs from active
# surflare-proxy sockets. Stores space-separated list in _diag_server_ips.
# Called after every confirmed-healthy reconnect.
_update_server_endpoint() {
	local ips
	# ss -tnp format: Recv-Q Send-Q Local($3) Peer($4) Process
	# Exclude RFC1918 (10.x, 172.16-31.x, 192.168.x) to get only public server IPs.
	ips=$(ss -tnp state established 2>/dev/null \
		| awk '/surflare/{split($4,a,":");ip=a[1];
		        if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ &&
		            ip !~ /^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.)/) print ip}' \
		| sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
	# UDP fallback: Netid State Recv-Q Send-Q Local($5) Peer($6) Process
	if [ -z "$ips" ]; then
		ips=$(ss -unp 2>/dev/null \
			| awk '/surflare/{split($6,a,":");ip=a[1];
			        if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ &&
			            ip !~ /^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.)/) print ip}' \
			| sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
	fi
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
	tcpdump -i "$phys_if" -nn -w "$pcap" "$filter" 2>/dev/null &
	local td_pid=$!
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
}

# _record_connect: call after every confirmed-healthy reconnect.
# Captures the transit node that was actually used, updates session state.
_record_connect() {
	local node="$1" exit_country="$2" now
	# Normalize health-check codes that are not ISO country codes
	case "$exit_country" in
		OK|TUNNEL_OK) exit_country="?" ;;
	esac
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
}

# _record_disconnect: call after _diagnose_tunnel_failure when TCP_BLOCK fires.
# Appends one JSON line to EVENT_LOG for pattern analysis.
_record_disconnect() {
	[ "$_sess_connect_s" -eq 0 ] && return
	local now lifetime
	now=$(date +%s)
	lifetime=$(( now - _sess_connect_s ))
	[ ! -f "$EVENT_LOG" ] && install -m 644 /dev/null "$EVENT_LOG" 2>/dev/null || true
	printf '{"ts":"%s","node":"%s","lifetime_s":%d,"transit":"%s","exit":"%s","prev_node":"%s","prev_s":%d,"hour":%d,"diag":"%s","out":%d,"in":%d,"syn_out":%d,"syn_ack":%d,"sack_pct":%d,"rst_in":%d}\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"$_sess_node" "$lifetime" \
		"${_sess_transit:-unknown}" \
		"${_sess_exit:-?}" \
		"${_sess_prev_node:-none}" "$_sess_prev_s" \
		"$((10#$(date +%H)))" \
		"${_diag_conclusion:-no_diag}" \
		"$_diag_out" "$_diag_in" \
		"$_diag_syn_out" "$_diag_syn_ack" \
		"$_diag_sack_pct" "$_diag_rst_in" \
		>> "$EVENT_LOG" 2>/dev/null || true
	log "Event recorded: node=${_sess_node} lifetime=${lifetime}s transit=${_sess_transit:-?}"
}

TRANSIT_CACHE_FILE="/run/surflare_transit_cache"
TRANSIT_REPROBE_AFTER=3

_transit_fail_count=0

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
	_transit_fail_count=$((_transit_fail_count + 1))
	if [ "$_transit_fail_count" -ge "$TRANSIT_REPROBE_AFTER" ]; then
		log "Transit fail threshold reached, reprobing..."
		local new_transit
		new_transit=$(probe_best_transit)
		cleanup_probe_state
		if [ -n "$new_transit" ]; then
			save_transit_cache "$new_transit"
			log "Transit cache updated: ${new_transit}"
		fi
		_transit_fail_count=0
	fi
}

cleanup_probe_state() {
	surflare disconnect >/dev/null 2>&1
	killall surflare-proxy 2>/dev/null
	wait_for_exit surflare-proxy
	if nft list table inet surflare >/dev/null 2>&1; then
		nft flush table inet surflare 2>/dev/null || true
		nft delete table inet surflare 2>/dev/null || true
	fi
	while ip rule del fwmark 0x1 lookup 100 2>/dev/null; do :; done
	ip route flush table 100 2>/dev/null || true
}

probe_best_transit() {
	if [ ${#TRANSIT_CANDIDATES[@]} -eq 0 ]; then
		echo ""
		return
	fi
	local node best_node="" best_ms=999999
	for node in "${TRANSIT_CANDIDATES[@]}"; do
		if [ "${_active_node:-$NODE}" = "$node" ]; then
			log "Probing transit candidate: ${node} -- skipped (same as node)"
			continue
		fi
		log "Probing transit candidate: ${node}"
		if ! timeout "$TRANSIT_CONNECT_TIMEOUT" surflare connect \
			--node "${_active_node:-$NODE}" --mode "${MODE:-global}" \
			--transit "$node" --daemon >/dev/null 2>&1; then
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
		[ "$_killswitch_armed" -eq 1 ] && _update_killswitch_server_ips
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
	_active_node="${NODE_CANDIDATES[$_node_idx]}"
	log "Node rotation: ${prev} -> ${_active_node} ($((_node_idx + 1))/${n})"
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
		[ "$rule_count" -gt 0 ] && log "Removed ${rule_count} residual ip rule(s) fwmark 0x1 lookup 100"
		ip route flush table 100 2>/dev/null || true

		# Remove LAN tproxy to prevent black-holing LAN traffic while the proxy
		# is down. Without this, sw_lan_tproxy continues routing all LAN TCP to
		# :10800 which has no listener, silently dropping all packets for the
		# ~24s reconnect window. LAN devices fall through to direct fw4 routing
		# so CN ISP pages remain accessible during reconnect.
		if nft list table ip sw_lan_tproxy >/dev/null 2>&1; then
			nft delete table ip sw_lan_tproxy 2>/dev/null || true
			log "LAN tproxy removed: direct routing active during reconnect"
		fi

		# O3 (v3.2): token refresh gated by file timestamp. Runs in
		# direct-routing window (nft flushed, API reachable via ISP).
		# File-based because this subshell's variable updates are lost on exit.
		# Only writes timestamp on success; failure must not suppress retry.
		local _last_ref=0
		[ -f "$LAST_REFRESH_FILE" ] && _last_ref=$(cat "$LAST_REFRESH_FILE" 2>/dev/null)
		_last_ref=${_last_ref:-0}  # defense: empty/corrupt file -> 0
		if [ $(($(date +%s) - _last_ref)) -ge "$TOKEN_REFRESH_INTERVAL" ]; then
			if refresh_auth; then
				date +%s > "$LAST_REFRESH_FILE"
			else
				log "refresh_auth failed, will retry next cycle"
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
		log "Connecting to ${use_node} mode=${MODE:-global} transit=${effective_transit:-off} (daemon mode)..."
		if ! surflare connect --node "$use_node" \
			${MODE:+--mode "$MODE"} \
			${effective_transit:+--transit "$effective_transit"} \
			--daemon 9>&-; then
			log "Connection failed, will retry on next check cycle"
			exit 1
		fi
		# O1 (v3.2): poll-based readiness with handshake buffer.
		# _use_poll=0 (rollback flag) reverts to original fixed sleep.
		if [ "$_use_poll" -eq 1 ]; then
			local _ready_wait=0
			while [ "$_ready_wait" -lt "$CONNECT_SETTLE" ]; do
				if check_vpn_local_state; then
					sleep "$POST_READY_SETTLE"
					log "VPN routing ready: polled ${_ready_wait}s + buffer ${POST_READY_SETTLE}s"
					break
				fi
				sleep 1
				_ready_wait=$((_ready_wait + 1))
			done
			if [ "$_ready_wait" -ge "$CONNECT_SETTLE" ]; then
				log "VPN establishment timed out: not ready after ${CONNECT_SETTLE}s"
				exit 1
			fi
		else
			sleep "$CONNECT_SETTLE"
			if ! _proc_alive surflare-proxy >/dev/null 2>&1; then
				log "VPN establishment timed out: surflare-proxy not running after ${CONNECT_SETTLE}s"
				exit 1
			fi
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

	if [ "$health" = "LOCAL_FAIL" ] || [ "$health" = "TCP_BLOCK" ]; then
		[ "${_trace_active:-0}" -eq 0 ] && start_packet_trace
	fi
	# CN and "": caller handles fail_count logic, start on first failure
}

_check_trace_alive() {
	[ "${_trace_active:-0}" -eq 0 ] && return 0
	if ! kill -0 "$_trace_tcpdump_pid" 2>/dev/null; then
		log "WARNING: tcpdump died (PID $_trace_tcpdump_pid), cleaning up"
		nft delete table "$_trace_table" 2>/dev/null || true
		_trace_active=0
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
if [ -f "$PIDFILE" ]; then
	_old_pid=$(cat "$PIDFILE" 2>/dev/null)
	if [ -n "$_old_pid" ] && kill -0 "$_old_pid" 2>/dev/null; then
		if _pids_by_comm surflare_watchdog.sh | grep -qw "$_old_pid"; then
			echo "watchdog already running (PID $_old_pid)" >&2
			exit 1
		fi
		log "WARN: stale PID file ($PIDFILE) references non-watchdog PID $_old_pid; clearing"
	fi
	rm -f "$PIDFILE"
fi

# Set trap before writing PID to minimise stale-file window on early kill
# storm_sleep_pid: background sleep PID during storm cooling -- killed on SIGTERM
# _hc_tmp: health-check temp files -- cleaned on SIGTERM in case wait is interrupted
storm_sleep_pid=""
_hc_tmp=""
cleanup() {
	stop_packet_trace >/dev/null 2>&1
	[ -n "$storm_sleep_pid" ] && kill "$storm_sleep_pid" 2>/dev/null
	# shellcheck disable=SC2086
	[ -n "$_hc_tmp" ] && rm -f $_hc_tmp
	# Kill surflare-proxy before tearing down nft tables: it daemonizes
	# via setsid and survives watchdog exit, becoming an orphan that
	# holds port 10800 and blocks the next restart.  Fire-and-forget
	# (no wait): procd's term_timeout is only 5s, and _cleanup_on_startup
	# in the next instance handles any survivor.
	killall surflare-proxy 2>/dev/null
	nft delete table inet surflare_moat 2>/dev/null || true
	nft delete table ip sw_lan_tproxy 2>/dev/null || true
	nft delete table ip dns_enforce 2>/dev/null || true
	_remove_killswitch
	nft delete table inet surflare 2>/dev/null || true
	# Drop run-state sentinels so a future restart does not inherit
	# stale "ready" markers.
	# Forge finding #3: do NOT delete storm_cool_until here. On a graceful
	# exit followed by an immediate procd respawn, _cleanup_on_startup
	# reads storm_cool_until to sleep the remaining window. Deleting it
	# here would lose the cool state and allow immediate storm re-trigger.
	# _cleanup_on_startup deletes the file itself after consuming it.
	rm -f /run/surflare_watchdog.killswitch_ready
	# Preserve /run/surflare_watchdog.moat_strict as a user opt-in:
	# the user may want it to survive a watchdog restart, so we leave it
	# alone here.
	rm -f "$PIDFILE"
	rm -f "$WATCHDOG_ACK_FILE" 2>/dev/null || true
}
trap 'log "watchdog stopped"; cleanup; exit 0' INT TERM
trap 'cleanup' EXIT

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
    [[ -n "${storm_sleep_pid:-}" ]] && { kill "$storm_sleep_pid" 2>/dev/null || true; }
    touch "$WATCHDOG_ACK_FILE" 2>/dev/null || true
    log "EARLY_WARN_TRIGGERED: detector requested immediate health check"
' USR1

echo $$ >"$PIDFILE"
taskset -pc 0 $$ >/dev/null 2>&1 || true

# Clean up orphaned trace table from previous SIGKILL
nft delete table inet watchdog_trace 2>/dev/null || true
_startup_cleanup_dns_fallback

fail_count=0
reconnect_count=0
transient_count=0
last_heartbeat=$(date +%s)
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
log "watchdog started: node=${_active_node} candidates=${#NODE_CANDIDATES[@]} interval=${CHECK_INTERVAL}s threshold=${FAIL_THRESHOLD} transient=${TRANSIENT_THRESHOLD}"
_killswitch_armed=0
_setup_kernel_moat
_cleanup_on_startup

while true; do
	# Change 6: probe defer guard -- skip entire cycle when node_probe holds the session
	if _probe_active; then
		log "node_probe active; deferring health check + reactions this cycle"
		sleep "$CHECK_INTERVAL" & storm_sleep_pid=$!
		wait "$storm_sleep_pid" || true
		storm_sleep_pid=""
		continue
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
		if [ "$rc" -eq 2 ]; then
			log "Post-crash reconnect skipped (flock held), will retry next cycle"
		elif [ "$rc" -eq 0 ]; then
			fail_count=0
			reconnect_count=0
			transient_count=0
			_remove_dns_fallback
		else
			reconnect_count=$((reconnect_count + 1))
			log "Post-crash reconnect failed (reconnect_count=${reconnect_count})"
			if [ "$reconnect_count" -ge "$STORM_MAX" ]; then
				_enter_storm_cooldown "post-crash"
			fi
		fi
		sleep "$CHECK_INTERVAL" & storm_sleep_pid=$!; wait "$storm_sleep_pid"; storm_sleep_pid=""
		continue
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
			ip route flush table 100 2>/dev/null || true
			log "Flushed stale nftables/routing (${_stale} rule(s))"
		fi
		transient_count=0
		fail_count=$FAIL_THRESHOLD

	elif [ "$health" = "TCP_BLOCK" ]; then
		if _control_probe; then
			_diagnose_tunnel_failure
			_record_disconnect
			_rotate_node
			log "Health check TCP block (tunnel confirmed, local network OK), triggering reconnect"
			transient_count=0
			fail_count=$FAIL_THRESHOLD
		else
			transient_count=$((transient_count + 1))
			log "Health check TCP block but local network also down, treating as transient ${transient_count}/${TRANSIENT_THRESHOLD}"
		fi

	elif [ "$health" = "OK" ] || \
	     { [ "$health" != "CN" ] && [ "$health" != "LOCAL_FAIL" ] && [ "$health" != "TCP_BLOCK" ] && [ -n "$health" ]; }; then
		# VPN healthy -- Google 200/30x (tunnel working) OR country probe returned non-CN country
		fail_count=0
		reconnect_count=0
		transient_count=0
		_remove_dns_fallback

		# Proactive token refresh -- runs whenever VPN is confirmed healthy so tokens stay
		# fresh for reconnects. Uses same file as connect_vpn O3 for cross-subshell sync.
		now=$(date +%s)
		_last_ref=0
		[ -f "$LAST_REFRESH_FILE" ] && _last_ref=$(cat "$LAST_REFRESH_FILE" 2>/dev/null)
		_last_ref=${_last_ref:-0}
		if [ $((now - _last_ref)) -ge "$TOKEN_REFRESH_INTERVAL" ]; then
			if refresh_auth; then
				date +%s > "$LAST_REFRESH_FILE"
			fi
		fi

		# Periodic heartbeat -- confirms watchdog is alive during long healthy stretches
		if [ "${HEARTBEAT_INTERVAL:-0}" -gt 0 ] && [ $((now - last_heartbeat)) -ge "$HEARTBEAT_INTERVAL" ]; then
			log "VPN healthy: exit=${health}"
			last_heartbeat=$now
		fi

	elif [ "$health" = "CN" ]; then
		# External confirmed: traffic is exiting via China -- VPN is routing incorrectly
		transient_count=0
		fail_count=$((fail_count + 1))
		log "Health check failed (CN exit), consecutive count: ${fail_count}"

	else
		# health="" -- all external probes timed out; local state was OK (check_vpn_health
		# returns LOCAL_FAIL if local state is bad, so here local is confirmed healthy).
		# This is a transient network spike, not a definitive VPN failure.
		transient_count=$((transient_count + 1))
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

	_manage_trace "$health"
	_check_trace_alive

	# -- Shared reconnect path -----------------------------------------------
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
			   { [ "$new_health" != "CN" ] && [ "$new_health" != "LOCAL_FAIL" ] && [ "$new_health" != "TCP_BLOCK" ] && [ -n "$new_health" ]; }; then
				stop_packet_trace >/dev/null 2>&1
				fail_count=0
				reconnect_count=0
				transient_count=0
				_transit_fail_count=0
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
				_update_bypass_devices
				# Restore LAN tproxy now that the new proxy is ready on :10800.
				# Only restore if it was removed during this reconnect cycle.
				_lan_tproxy_nft="/etc/surflare-lan-tproxy.nft"
				if [ -f "$_lan_tproxy_nft" ] && \
				   ! nft list table ip sw_lan_tproxy >/dev/null 2>&1; then
					if nft -f "$_lan_tproxy_nft" 2>/dev/null; then
						log "LAN tproxy restored"
					else
						log "WARN: LAN tproxy restore failed"
					fi
					_update_bypass_devices
				fi
				_record_connect "${_active_node}" "${new_health}"
			else
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
			reconnect_count=$((reconnect_count + 1))
			log "Reconnect attempt failed (reconnect_count=${reconnect_count})"
			maybe_reprobe_transit
			if [ "$reconnect_count" -ge "$STORM_MAX" ]; then
				_enter_storm_cooldown "connect-failure"
				transient_count=0
			fi
		fi
	fi

	# Sync auto_bypass IPs to dns_enforce (devices may appear/expire between reconnects)
	_sync_dns_enforce_bypass

	# Adaptive interval -- shorter poll when degraded for faster recovery.
	# 15s floor (not lower): 7 probes x 12s max-time overlap at <14s interval.
	_interval="$CHECK_INTERVAL"
	if [ "${transient_count:-0}" -gt 0 ] || [ "${fail_count:-0}" -gt 0 ]; then
		_interval="$DEGRADED_INTERVAL"
	fi
	sleep "$_interval" & storm_sleep_pid=$!
	wait "$storm_sleep_pid" || true
	storm_sleep_pid=""
	if (( run_health_check_now )); then
		run_health_check_now=0
		log "EARLY_WARN: running immediate health check (detector USR1)"
	fi
done
