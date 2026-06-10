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
NODE_CANDIDATES=("Los Angeles" "Dallas" "Atlanta" "Seoul" "Chicago" "Miami" "New York")
MODE="global"                         # Connection mode: global, rule, direct
TRANSIT="auto"                            # Transit server for multi-hop: auto, or "" to disable
TRANSIT_CANDIDATES="Tokyo Seoul"            # Ordered probe list; connect_vpn picks lowest-latency
TRANSIT_CONNECT_TIMEOUT=12             # max seconds for surflare connect per candidate
TRANSIT_ROUTE_READY_TIMEOUT=15        # max seconds to poll for routing readiness after connect
TRANSIT_PROBE_SETTLE=20              # seconds of quiet time for tunnel handshake after routing ready
CHECK_INTERVAL=30                     # Exit IP check interval in seconds
FAIL_THRESHOLD=4                      # Consecutive failures before reconnect
LOCK_FILE=/run/surflare_watchdog.lock # Mutex lock to prevent concurrent reconnects
PIDFILE=/run/surflare_watchdog.pid    # PID file for reliable daemon shutdown
ROTATION_STATE=/var/tmp/surflare_rotation  # Persists active node across restarts
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
# Auto-detect WiFi interface; fallback to wlp9s0f0 if iw is unavailable
WIFI_INTERFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
[ -z "$WIFI_INTERFACE" ] && WIFI_INTERFACE="wlp9s0f0"
CRASH_COOLDOWN=60                     # seconds to wait after detecting firmware crash before reconnect
CRASH_MAX_PER_WINDOW=3                # max crashes in CRASH_WINDOW before extended cooldown
CRASH_WINDOW=600                      # seconds window for crash rate limiting
CRASH_EXTENDED_COOLDOWN=300           # seconds extended cooldown after cascade detected
CRASH_DEDUP_INTERVAL=121              # minimum seconds between counting two crashes as distinct (must exceed detection window)

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

# check_vpn_local_state: fast local-only check -- no network calls.
# Returns 0 if all three local VPN indicators are present, 1 if any is missing.
# Indicators: surflare-proxy process + nftables table + fwmark policy routing rule.
# A LOCAL_FAIL means the VPN is definitively down (not a transient network timeout).
check_vpn_local_state() {
	pgrep -x surflare-proxy >/dev/null 2>&1 || return 1
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
		| grep -E "ip daddr ${gw//./\\.} (tcp|udp) dport 53 accept" | grep -oP 'handle \K[0-9]+'); do
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
		| grep 'dport 53 meta mark set' | head -1 | grep -oP 'handle \K[0-9]+')
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
	# Upstream filter injects spoofed TCP FIN+ACK (win=78) and RST packets to
	# tear down tunnelled connections. Priority -300 drops them before conntrack.
	nft add table inet surflare_moat 2>/dev/null || true
	nft flush table inet surflare_moat 2>/dev/null || true
	if ! nft add chain inet surflare_moat prerouting '{ type filter hook prerouting priority -300; policy accept; }' 2>/dev/null; then
		log "WARN: Kernel moat chain creation failed"
		return 1
	fi
	local moat_ok=1
	# "flags & fin == fin" matches both pure FIN [F] and FIN+ACK [F.] -- upstream filter sends [F.]
	nft add rule inet surflare_moat prerouting \
		"tcp flags & fin == fin tcp window { 78, 88, 89 } drop" 2>/dev/null || moat_ok=0
	# RST injection
	nft add rule inet surflare_moat prerouting \
		"tcp flags & rst == rst tcp window { 78, 88, 89 } drop" 2>/dev/null || moat_ok=0
	if [ "$moat_ok" -eq 1 ]; then
		log "Kernel moat deployed: dropping injected FIN/RST packets"
	else
		log "WARN: Kernel moat rules failed to load; moat may be incomplete"
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
		if nft -f "$tmp_nft" 2>/dev/null; then
			nft insert rule inet surflare output ip daddr @cn_ipv4 accept 2>/dev/null || true
			log "Chnroute v4 applied: CN prefixes bypass proxy via output chain"
			bypass_applied=$((bypass_applied + 1))
		else
			log "WARN: Failed to load Chnroute v4 into nftables; CN bypass not active"
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
		if nft -f "$tmp_nft_v6" 2>/dev/null; then
			nft insert rule inet surflare output ip6 daddr @cn_ipv6 accept 2>/dev/null || true
			log "Chnroute v6 applied: CN v6 prefixes bypass proxy via output chain"
			bypass_applied=$((bypass_applied + 1))
		else
			log "WARN: Failed to load Chnroute v6 into nftables; CN bypass not active"
		fi
		rm -f "$tmp_nft_v6"
	fi

	if [ "$bypass_applied" -eq 0 ]; then
		log "WARN: no chnroute files; CN bypass disabled"
	fi
}

CONTROL_PROBE_TARGETS="114.114.114.114:53 223.5.5.5:53"
CONTROL_PROBE_TIMEOUT=3

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
	total=$(nproc --all)
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

	# Layer 2: parallel external probes -- six run concurrently, first success wins
	local tmp_g tmp_cf tmp_cf2 tmp_ifc tmp_ich tmp_myip
	local tmp_gt tmp_cft tmp_cf2t tmp_ifct tmp_icht tmp_myt
	local pid_g pid_cf pid_cf2 pid_ifc pid_ich pid_myip
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
	# Ensure temp files are removed even if this function is interrupted mid-wait.
	# Stored in a global so the main EXIT trap can also clean up on unclean exit.
	_hc_tmp="$tmp_g $tmp_cf $tmp_cf2 $tmp_ifc $tmp_ich $tmp_myip $tmp_gt $tmp_cft $tmp_cf2t $tmp_ifct $tmp_icht $tmp_myt"

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

	# --- Early-exit polling loop ---
	# Poll results every 1s. Return as soon as any probe produces a usable result.
	# Maximum wait = max-time (12s), but typically returns in 1-3s when tunnel is healthy.
	local all_pids="$pid_g $pid_cf $pid_cf2 $pid_ifc $pid_ich $pid_myip"
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
		          "$tmp_ifct:ifconfig" "$tmp_icht:icanhazip" "$tmp_myt:myip"; do
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

	rm -f "$tmp_g" "$tmp_cf" "$tmp_cf2" "$tmp_ifc" "$tmp_ich" "$tmp_myip" \
	      "$tmp_gt" "$tmp_cft" "$tmp_cf2t" "$tmp_ifct" "$tmp_icht" "$tmp_myt"
	_hc_tmp=""

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
# Retries LOGIN_RETRIES times with LOGIN_RETRY_DELAY between attempts -- surflare API is
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
			log "Auth credential file not found: ${CREDENTIALS_DIRECTORY}/surflare-password -- proactive refresh disabled"
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
		if timeout 15 surflare login -u "$email" -p "$password" >/dev/null 2>&1; then
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
	if [ -z "$TRANSIT_CANDIDATES" ]; then
		echo ""
		return
	fi
	local node best_node="" best_ms=999999
	for node in $TRANSIT_CANDIDATES; do
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
			pgrep -x surflare-proxy >/dev/null 2>&1 && \
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

_rotate_node() {
	local n=${#NODE_CANDIDATES[@]}
	if [ "$n" -le 1 ]; then
		return
	fi
	local prev="${_active_node}"
	_node_idx=$(( (_node_idx + 1) % n ))
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

		# Attempt auth refresh before connecting -- surflare API may still be
		# reachable briefly after nftables flush restores direct network access
		refresh_auth || true

		if [ -f "/sys/class/net/${WIFI_INTERFACE}/threaded" ] && \
		   [ "$(cat "/sys/class/net/${WIFI_INTERFACE}/threaded" 2>/dev/null)" != "1" ]; then
			echo 1 > "/sys/class/net/${WIFI_INTERFACE}/threaded" 2>/dev/null || true
		fi

		local effective_transit="$TRANSIT"
		if [ -n "$TRANSIT_CANDIDATES" ] && [ -z "$TRANSIT" ]; then
			effective_transit=$(get_cached_transit)
			[ -z "$effective_transit" ] && effective_transit="${TRANSIT_CANDIDATES%% *}"
			log "Using transit: ${effective_transit} (from cache or first candidate)"
		fi

		local use_node="${_active_node:-$NODE}"
		log "Connecting to ${use_node} mode=${MODE:-global} transit=${effective_transit:-off} (daemon mode)..."
		if ! surflare connect --node "$use_node" \
			${MODE:+--mode "$MODE"} \
			${effective_transit:+--transit "$effective_transit"} \
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

		compute_proxy_affinity
		_remove_dns_fallback
		local proxy_pid
		proxy_pid=$(pgrep -x surflare-proxy | head -1)
		if [ -n "$proxy_pid" ] && [ -n "$PROXY_CPU_SET" ]; then
			taskset -apc "$PROXY_CPU_SET" "$proxy_pid" >/dev/null 2>&1 &&
				log "Pinned surflare-proxy (PID ${proxy_pid}) to CPUs ${PROXY_CPU_SET}" || true
		fi

		if [ -n "$DESKTOP_CPU_SET" ]; then
			local irq pinned=0
			# shellcheck disable=SC2013  # word-split intentional: iterating over IRQ numbers
			for irq in $(grep iwlwifi /proc/interrupts | grep -oP '^\s*\K[0-9]+(?=:)'); do
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
		ips=$(getent ahosts "$host" 2>/dev/null | \
		      awk '{print $1}' | sort -u || true)
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
        ip daddr { $ip_set } tcp dport { 80, 443 } mark set mark | 0xface ct mark set ct mark | 0xface
        mark 0xface log prefix "WD_TRACE_OUT" group $_trace_group
    }
    chain input {
        type filter hook input priority mangle;
        ct mark 0xface log prefix "WD_TRACE_IN" group $_trace_group
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

	local ready=0
	for _ in $(seq 1 20); do
		if kill -0 "$_trace_tcpdump_pid" 2>/dev/null; then
			ready=1; break
		fi
		sleep 0.1
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
		while kill -0 "$_trace_tcpdump_pid" 2>/dev/null && [ $waited -lt 20 ]; do
			sleep 0.1; waited=$((waited + 1))
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
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
	echo "watchdog already running (PID $(cat "$PIDFILE"))" >&2
	exit 1
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
	nft delete table inet surflare_moat 2>/dev/null || true
	rm -f "$PIDFILE"
}
trap 'log "watchdog stopped"; cleanup; exit 0' INT TERM
trap 'cleanup' EXIT
echo $$ >"$PIDFILE"
taskset -pc 0 $$ >/dev/null 2>&1 || true

# Clean up orphaned trace table from previous SIGKILL
nft delete table inet watchdog_trace 2>/dev/null || true
_startup_cleanup_dns_fallback

fail_count=0
reconnect_count=0
transient_count=0
last_refresh=$(date +%s)
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
_setup_kernel_moat

while true; do
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
				stop_packet_trace >/dev/null 2>&1
				_remove_dns_fallback
				log "Storm protection triggered (post-crash): cooling for ${STORM_COOLING}s"
				sleep "$STORM_COOLING" &
				storm_sleep_pid=$!; wait "$storm_sleep_pid"; storm_sleep_pid=""
				reconnect_count=0
				fail_count=0
				transient_count=0
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
		# fresh for reconnects. Covers both Google-OK and country-probe-fallback paths.
		now=$(date +%s)
		if [ $((now - last_refresh)) -ge "$TOKEN_REFRESH_INTERVAL" ]; then
			refresh_auth
			refresh_rc=$?
			if [ "$refresh_rc" -eq 0 ] || [ "$refresh_rc" -eq 2 ]; then
				# rc=0: success; rc=2: no credentials -- both back off a full interval.
				# rc=1 (login failure) leaves last_refresh unchanged for prompt retry.
				last_refresh=$(date +%s)
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
			if _control_probe; then
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
			else
				reconnect_count=$((reconnect_count + 1))
				log "Post-reconnect health check anomalous (reconnect_count=${reconnect_count})"
				maybe_reprobe_transit
				if [ "$reconnect_count" -ge "$STORM_MAX" ]; then
					stop_packet_trace >/dev/null 2>&1
					_remove_dns_fallback
					log "Storm protection triggered: cooling for ${STORM_COOLING}s"
					sleep "$STORM_COOLING" & storm_sleep_pid=$!; wait "$storm_sleep_pid"; storm_sleep_pid=""
					reconnect_count=0
					fail_count=0
					transient_count=0
				fi
			fi
		else
			reconnect_count=$((reconnect_count + 1))
			log "Reconnect attempt failed (reconnect_count=${reconnect_count})"
			maybe_reprobe_transit
			if [ "$reconnect_count" -ge "$STORM_MAX" ]; then
				stop_packet_trace >/dev/null 2>&1
				_remove_dns_fallback
				log "Storm protection triggered (connect failure): cooling for ${STORM_COOLING}s"
				sleep "$STORM_COOLING" & storm_sleep_pid=$!; wait "$storm_sleep_pid"; storm_sleep_pid=""
				reconnect_count=0
				fail_count=0
				transient_count=0
			fi
		fi
	fi

	sleep "$CHECK_INTERVAL" & storm_sleep_pid=$!; wait "$storm_sleep_pid"; storm_sleep_pid=""
done
