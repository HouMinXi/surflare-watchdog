#!/bin/bash
# Exercise the real startup decision without touching host state or services.
set -u
cd "$(dirname "$0")/.." || exit 1
WD=${WD:-surflare_watchdog.sh}
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() {
	PASS=$((PASS + 1))
	printf 'PASS: %s\n' "$1"
}
bad() {
	FAIL=$((FAIL + 1))
	printf 'FAIL: %s\n' "$1"
}

# These functions have top-level closing braces. Keep their complete bodies,
# including the production call site, rather than duplicating the decision.
if ! python3 - "$WD" "$TMP/functions.sh" <<'PY'; then
import re
import sys
from pathlib import Path
src = Path(sys.argv[1]).read_text()
parts = []
for name in ('_inherited_proxy_responds', '_cleanup_on_startup'):
    match = re.search(r'^' + name + r'\(\) \{\n.*?^\}', src, re.M | re.S)
    if match is None:
        if name == '_inherited_proxy_responds':
            continue  # The baseline predates this helper.
        raise SystemExit('missing startup function')
    parts.append(match.group())
Path(sys.argv[2]).write_text('\n\n'.join(parts) + '\n')
PY
	bad 'production function extraction failed'
	exit 1
fi
if ! bash -n "$TMP/functions.sh"; then
	bad 'extracted production functions did not parse'
	exit 1
fi

cat >"$TMP/driver.sh" <<'DRIVER'
#!/bin/bash
set -u
source "$1"
export CALLS="$2"
: >"$CALLS"
PIDFILE="$2.pid"
RESTART_MARKER="$2.restart"
DWELL_HISTORY="$2.dwell"
TPROXY_NFT_STAMP="$2.stamp"
PROXY_LOG="$2.proxy-log"
PLATFORM=router
record() { printf '%s\n' "$*" >>"$CALLS"; }
log() { record "log $*"; }
_proc_alive() { [ "${ALIVE:-1}" = 1 ]; }
_pids_by_comm() { echo 424242; }
ss() {
	if [ -f "$CALLS.ss-seen" ]; then
		[ "${SS_LATER_RC:-0}" = 0 ] || return "$SS_LATER_RC"
	fi
	printf 'seen\n' >"$CALLS.ss-seen"
	[ "${SS_RC:-0}" = 0 ] || return "$SS_RC"
	[ "${TPROXY:-1}" = 0 ] || echo 'LISTEN 0 4096 *:10800 *:*'
	if [ "${DIAG:-1}" != 0 ]; then
		if [ "${SS_EOF:-0}" = 1 ]; then
			echo 'LISTEN 0 4096 127.0.0.1:10808'
		else
			echo 'LISTEN 0 4096 127.0.0.1:10808 0.0.0.0:*'
		fi
	fi
}
nft() {
	record "nft $*"
	case "$*" in
	'list table inet surflare') return "${TABLE_RC:-0}" ;;
	'list table inet killswitch') return 1 ;;
	'list table inet sw_lan_tproxy') return 1 ;;
	'delete table inet watchdog_trace') return 0 ;;
	*) echo "unexpected nft $*" >&2; return 90 ;;
	esac
}
curl() {
	local target="${*: -1}" item
	record "curl $*"
	[ "$1" = '-q' ] || return 90
	local -a args=("$@")
	local i found_proxy=0 found_noproxy=0 found_max=0
	for ((i = 0; i < ${#args[@]}; i++)); do
		item=${args[i]}
		case "$item" in
		--socks5-hostname)
			[ "${args[i + 1]}" = '127.0.0.1:10808' ] || return 90
			found_proxy=1
			;;
		--noproxy)
			[ "${args[i + 1]}" = '' ] || return 90
			found_noproxy=1
			;;
		--max-time)
			[ "${args[i + 1]}" = 8 ] || return 90
			found_max=1
			;;
		--insecure | -k | --location | -L) return 90 ;;
		esac
	done
	[ "$found_proxy$found_noproxy$found_max" = 111 ] || return 90
	case "$target" in
	https://www.gstatic.com/generate_204)
		printf '%s' "${HTTP1:-204}"; return "${CURL1_RC:-0}" ;;
	https://cp.cloudflare.com/generate_204)
		printf '%s' "${HTTP2:-204}"; return "${CURL2_RC:-0}" ;;
	*) return 90 ;;
	esac
}
surflare() {
	record "surflare $*"
	printf '%s\n' "${PING_OUT:-Loss: 0.0%}"
	return "${PING_RC:-1}"
}
timeout() {
	record "timeout $*"
	if [ "${1:-}" = '-k' ]; then shift 2; fi
	shift
	"$@"
}
# All mutating commands in startup are stubs. No real kill/nft/rm/touch runs.
touch() { record "touch $*"; }
rm() { record "rm $*"; }
kill() { record "kill $*"; return 1; }
killall() { record "killall $*"; }
fuser() { record "fuser $*"; }
sleep() { :; }
find() { :; }
ip() { record "ip $*"; return 1; }
_remove_surflare_table() { record remove-surflare-table; }
_stop_proxy_log_monitor() { record stop-monitor; }
_start_proxy_log_monitor() { record start-monitor; }
_reconcile_rotation_with_live_session() { :; }
_update_killswitch_server_ips() { :; }
_ensure_dns_enforce() { :; }
_ensure_gmail_smtp_ks() { :; }
_ensure_surflare_control_ks() { :; }
_load_tproxy_cn_direct() { record load-cn-direct; }
_restore_tproxy() { record restore-tproxy; }
_update_bypass_devices() { :; }
# A real host might have this file. Mask the existence test, not control flow:
# run the function in a private mount namespace supplied by the caller.
_cleanup_on_startup
DRIVER

# Mount namespaces keep absolute /run and /tmp reads private as well. The
# payload cannot write host files or reach a real network even if a stub drifts.
if ! command -v bwrap >/dev/null 2>&1; then
	bad 'bwrap is required for safe startup-path tests'
	exit 1
fi
run_case() {
	local name="$1" expect="$2" rc
	shift 2
	if timeout -k 2 20 bwrap --unshare-user --unshare-pid --unshare-net \
		--ro-bind / / --dev /dev --proc /proc --tmpfs /run \
		--tmpfs /tmp --bind "$TMP" "$TMP" \
		env -i PATH=/usr/local/bin:/usr/bin:/bin \
		"$@" bash "$TMP/driver.sh" "$TMP/functions.sh" "$TMP/$name.calls" \
		>"$TMP/$name.out" 2>&1; then
		rc=0
	else
		rc=$?
	fi
	if [ "$rc" -ne 0 ]; then
		bad "$name: driver exited $rc"
		cat "$TMP/$name.out"
		return
	fi
	if [ "$expect" = adopt ]; then
		if grep -q '^log Startup: adopting running proxy ' "$TMP/$name.calls" &&
			! grep -qE '^killall surflare-proxy|^fuser |^remove-surflare-table$|^ip rule del' "$TMP/$name.calls" &&
			grep -qx start-monitor "$TMP/$name.calls"; then
			ok "$name: adopted without destroying proxy or routes"
		else
			bad "$name: healthy inherited proxy was not preserved"
			cat "$TMP/$name.calls"
		fi
	else
		if ! grep -q '^log Startup: adopting running proxy ' "$TMP/$name.calls" &&
			grep -qx remove-surflare-table "$TMP/$name.calls"; then
			ok "$name: refused adoption"
		else
			bad "$name: unusable proxy was adopted"
			cat "$TMP/$name.calls"
		fi
	fi
}
run_case cli-fails-proxy-works adopt PING_RC=124
run_case listener-port-at-eol reject DIAG=1 SS_EOF=1 CURL1_RC=28 HTTP1=000 CURL2_RC=28 HTTP2=000 PING_RC=0
run_case first-target-down adopt CURL1_RC=28 HTTP1=000
run_case both-targets-down reject CURL1_RC=28 HTTP1=000 CURL2_RC=28 HTTP2=000 PING_RC=0
run_case http-error reject HTTP1=503 HTTP2=500 PING_RC=0
run_case other-2xx-rejected reject HTTP1=200 HTTP2=200 PING_RC=0
run_case redirect reject HTTP1=302 HTTP2=301
run_case truncated-transfer reject CURL1_RC=18 HTTP1=204 CURL2_RC=18 HTTP2=204
run_case missing-process reject ALIVE=0
run_case missing-tproxy reject TPROXY=0
run_case missing-table reject TABLE_RC=1
run_case failed-listing reject SS_RC=1
run_case diagnostic-listing-fails reject SS_LATER_RC=1 PING_RC=0
run_case old-install-ping-ok adopt DIAG=0 PING_RC=0
run_case old-install-ping-fails reject DIAG=0 PING_RC=1
run_case old-install-loss reject DIAG=0 PING_RC=0 PING_OUT='Loss: 100.0%'
run_case old-install-no-verdict reject DIAG=0 PING_RC=0 PING_OUT='connected'
run_case old-install-partial-loss reject DIAG=0 PING_RC=0 PING_OUT='Loss: 10.0%'
run_case proxy-environment adopt NO_PROXY='*' HTTPS_PROXY=http://unusable.invalid:1
printf 'RESULT: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
