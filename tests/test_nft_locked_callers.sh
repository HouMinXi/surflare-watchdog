#!/bin/bash
# Exercise actual destructive callers; external interactions are local stubs.
# This suite writes subject scripts in bash syntax, so it needs bash itself.
[ -n "${BASH_VERSION:-}" ] || {
	echo "SKIP: tests/test_nft_locked_callers.sh requires bash (generates bash subject scripts)"
	exit 2
}
set -u
cd "$(dirname "$0")/.." || exit 1
WD=${WD:-surflare_watchdog.sh}
[ -f "$WD" ] || {
	echo "FAIL: cannot read $WD"
	exit 1
}
TMP=$(mktemp -d) || exit 1
HOLDER_PIDS=''
_killed=''
_cleanup_failed=''
# One EXIT trap, installed before anything that can fail. The reap list holds the
# pids this run started with $!, each dropped when its holder is released, and the
# kill checks liveness first. Membership is not proof of ownership: a pid recycled
# between a holder's exit and its removal would still be signalled.
holder_forget() {
	# Drop one pid from the reap list so a reaped process is never signalled twice.
	local keep='' pid
	for pid in ${HOLDER_PIDS:-}; do
		[ "$pid" = "$1" ] || keep="$keep $pid"
	done
	HOLDER_PIDS=$keep
}

reap_holders() {
	# A signal and the exit that follows it both reach this handler. The kill
	# runs once; the temp-dir removal is attempted every time because it is
	# idempotent and must not be skippable by a flag left set from outside.
	if [ -z "${_killed:-}" ]; then
		_killed=1
		local pid
		[ -n "${_watchdog:-}" ] && kill "$_watchdog" 2>/dev/null
		for pid in ${HOLDER_PIDS:-}; do
			[ -n "$pid" ] || continue
			[ "$pid" = "$$" ] && continue
			kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
		done
	fi
	[ -n "${TMP:-}" ] && rm -rf "$TMP"
	if [ -e "${TMP:-/nonexistent}" ]; then
		echo "WARN: ${TMP} could not be removed" >&2
		_cleanup_failed=1
	fi
	return 0
}
# An exit keeps its status unless the cleanup failed, which turns a green run
# red; a signal always exits 1.
trap 'rc=$?; reap_holders; [ -n "${_cleanup_failed:-}" ] && [ "$rc" -eq 0 ] && rc=1; exit "$rc"' EXIT
trap 'reap_holders; exit 1' INT TERM HUP
# A regression that turns the non-blocking lock into a blocking one hangs every
# case that holds the lock across a call. The watchdog turns that into a named
# failure instead of the runner's bare timeout; the deadline is overridable so
# the check itself can be exercised.
_deadline_raw=${_SUITE_DEADLINE_SECS:-}
case "$_deadline_raw" in
'' | *[!0-9]*) _deadline_secs=240 ;; # an unusable value must not abort the run
*) _deadline_secs=$_deadline_raw ;;
esac
_suite_deadline=$(($(date +%s) + _deadline_secs))
(
	while :; do
		sleep 5
		[ "$(date +%s)" -ge "$_suite_deadline" ] || continue
		printf 'FAIL: the suite exceeded its lock deadline\n' >&2
		# A trap cannot run while the shell waits on a foreground child, so the
		# polite signal is only a chance to clean up; the kill is what ends a
		# genuinely blocked lock.
		kill -TERM $$
		sleep 5
		pkill -9 -P $$ 2>/dev/null
		[ -n "${TMP:-}" ] && rm -rf "$TMP"
		kill -9 $$
		exit 0
	done
) &
_watchdog=$!
pass=0
fail=0
ok() {
	printf 'PASS: %s\n' "$*"
	pass=$((pass + 1))
}
bad() {
	printf 'FAIL: %s\n' "$*"
	fail=$((fail + 1))
}
mkdir "$TMP/bin"
if ! python3 - "$WD" "$TMP/functions" <<'PY'; then
import json
import os
from pathlib import Path
import subprocess
import sys

source = Path(sys.argv[1]).read_bytes()
ast = json.loads(subprocess.check_output(
    [os.environ.get('SHFMT', 'shfmt'), '-ln=bash', '--to-json'], input=source))
names = {
    'nft_apply_locked', '_install_killswitch', '_unarm_killswitch_output',
    '_reinstall_killswitch_output', '_remove_surflare_table', '_restore_tproxy',
    '_cleanup_dns_fallback_rules', '_remove_dns_fallback',
    '_insert_dns_fallback', '_exemption_present', '_dns_gw_port_lines',
    '_dns_fallback_body',
    '_dns_defer_read', '_dns_defer_record', '_dns_defer_clear',
    '_startup_cleanup_dns_fallback',
}
found = {}
def walk(node):
    if isinstance(node, dict):
        if node.get('Type') == 'FuncDecl' and node['Name']['Value'] in names:
            found[node['Name']['Value']] = source[
                node['Pos']['Offset']:node['End']['Offset']]
        for item in node.values():
            walk(item)
    elif isinstance(node, list):
        for item in node:
            walk(item)
walk(ast)
assert set(found) == names, found.keys()
# Extract the actual success consumer branch from connect_vpn, preserving
# return checks and log text. No other connect lifecycle code is executed.
start = source.index(b'\nconnect_vpn() {')
log = source.index(b'log "connect_vpn: killswitch output reinstalled after connect"', start)
branch = source.rfind(b'\n\t\tif [ "$_ks_was_armed" -eq 1 ]; then', start, log)
end = source.index(b'\n\t\tfi', log) + len(b'\n\t\tfi')
assert branch >= start
Path(sys.argv[2] + '.consumer').write_bytes(
    b'connect_consumer() {\n_ks_was_armed=1\n' + source[branch:end] +
    b'\nprintf "consumer-continued\\n"\n}\nconnect_consumer\n')
# Preserve the complete final table-install consumer through its actual exit.
start = source.index(b'\n\t\t# Load sw_lan_tproxy and killswitch tables immediately after connect.', start)
end = source.index(b'\n\t\texit 0', start) + len(b'\n\t\texit 0')
Path(sys.argv[2] + '.tail').write_bytes(
    b'connect_tail() {\n' + source[start:end] + b'\n}\nconnect_tail\n')
Path(sys.argv[2]).write_bytes(
    b'NFT_LOCK_FILE=$SURFLARE_NFT_LOCK\n' + b'\n'.join(found.values()) + b'\n')
PY
	bad 'the fixture could not extract the subject functions it needs, so a rename or a signature change stopped it'
	printf 'RESULT: %s passed, %s failed\n' "$pass" "$fail"
	exit 1
fi
bash -n "$TMP/functions" || exit 1

# Lock holders are signalled with marker files, never fifos: a fifo read blocks
# forever when its writer never writes, and the run has to fail, not hang.
holder_start() {
	local name="$1" i=0
	rm -f "$TMP/$name.ready" "$TMP/$name.done"
	(
		exec 7>>"$SURFLARE_NFT_LOCK" || exit 1
		flock 7 || exit 1
		: >"$TMP/$name.ready"
		# The only child of this subshell is a 0.05 s sleep, so killing the
		# subshell cannot leave a long-lived grandchild behind.
		while [ ! -e "$TMP/$name.done" ]; do sleep 0.05; done
	) >/dev/null 2>&1 &
	HOLDER_PID=$!
	# $! is the subshell's pid. Inside the subshell $$ is this script's own pid, so
	# the pid to reap can only be recorded out here.
	HOLDER_PIDS="$HOLDER_PIDS $HOLDER_PID"
	eval "HOLDER_OF_${name}=$HOLDER_PID"
	while [ ! -e "$TMP/$name.ready" ]; do
		i=$((i + 1))
		if [ "$i" -gt 100 ]; then
			kill -9 "$HOLDER_PID" 2>/dev/null || true
			holder_forget "$HOLDER_PID"
			bad "lock holder ${name} never started"
			return 1
		fi
		sleep 0.05
	done
	return 0
}

holder_stop() {
	local name="$1" i=0 pid
	eval "pid=\${HOLDER_OF_${name}:-}"
	[ -n "$pid" ] || {
		bad "no holder recorded for ${name}"
		return 1
	}
	: >"$TMP/$name.done"
	while kill -0 "$pid" 2>/dev/null; do
		i=$((i + 1))
		if [ "$i" -gt 100 ]; then
			kill -9 "$pid" 2>/dev/null || true
			holder_forget "$pid"
			bad "lock holder ${name} did not exit"
			return 1
		fi
		sleep 0.05
	done
	wait "$pid" 2>/dev/null || true
	rm -f "$TMP/$name.ready"
	holder_forget "$pid"
	eval "HOLDER_OF_${name}="
	return 0
}

# The nft calls in this surface must go through the stub's `nft` on PATH; an
# absolute path would reach the real binary and escape both the lock audit and
# this fixture.
for slice in "$TMP/functions" "$TMP/functions.tail" "$TMP/functions.consumer"; do
	if grep -Eq '(^|[^[:alnum:]_/])/(usr/)?(local/)?s?bin/nft([[:space:]]|$)' "$slice"; then
		printf 'FAIL: absolute-path nft invocation bypasses the stub\n' >&2
		exit 1
	fi
done
# Redirect only hardcoded file I/O, never the subject's branch/call structure.
sed "s|/tmp/|$TMP/|g; s|/etc/surflare-lan-tproxy.nft|$TMP/template|g; \
	s|/etc/surflare/server_ips|$TMP/server_ips|g" \
	"$TMP/functions" >"$TMP/subject"
printf 'table inet sw_lan_tproxy {\n\tset probe_sentinel { type ipv4_addr; }\n}\n' \
	>"$TMP/template"
cat >"$TMP/bin/nft" <<'EOF'
#!/bin/sh
if [ "$1 $2" = 'list table' ] && [ "${FAKE_LIST_FAIL:-}" = "$4" ]; then
	# Read-back fails even though the load happened: proves the success
	# message is emitted only after verification.
	exit 1
fi
case " ${MISSING_TABLE:-} " in
*" $4 "*) if [ "$1 $2" = 'list table' ]; then
	# Presence is table-specific: only a batch that declares this very table
	# makes it appear, so the fixture can tell the two installs apart.
	grep -q "table inet $4" "$NFT_BATCH" 2>/dev/null || exit 1
fi ;;
esac
if [ "$1" = -a ] && [ "$2" = list ] && [ "$3" = chain ] &&
	[ "${FAKE_LIST_FAIL:-0}" = 1 ]; then
	exit 9
fi
if [ "$1" = -a ] && [ "$2" = list ] && [ "$3" = chain ]; then
	# Only the chain that exists answers; reading another chain has to fail the way
	# nft fails, or a subject that reads the wrong chain looks correct.
	[ "${6:-}" = output ] || exit 1
	[ "${5:-}" = surflare ] || exit 1
	# The two listings are independent: a chain can hold the mark rule with no
	# exemption yet, which is exactly the state the install path starts from.
	for h in ${FAKE_DNS_HANDLES:-}; do
		# Either transport can be withheld, so neither leg of the exemption
		# check can be the only one tested.
		# nft prints counters in the middle of the rule when the rule has them,
		# so the verdict is not the word next to the port.
		_cn="${FAKE_DNS_COUNTER:+counter packets 0 bytes 0 }"
		# The udp line can be replaced by a verdict that is not accept, which keeps
		# the rule count at two and still changes what the kernel does.
		[ "${FAKE_DNS_UDP_QUEUE:-0}" = 1 ] &&
			printf 'ip daddr %s udp dport 53 queue # handle %s\n' \
				"${FAKE_DNS_GW:-192.0.2.1}" "$h"
		# Set form and `meta l4proto` form name the same traffic without the scalar
	# spelling, and this repository writes both elsewhere.
	[ "${FAKE_DNS_SETFORM:-0}" = 1 ] &&
		printf 'ip daddr { %s, 203.0.113.9 } udp dport 53 redirect to :53 # handle 5\n' \
			"${FAKE_DNS_GW:-192.0.2.1}"
	# A different address that merely starts with the gateway's digits is somebody
	# else's rule; reading it as ours would make the chain look wrong forever.
	[ "${FAKE_DNS_SIBLING:-0}" = 1 ] &&
		printf 'ip daddr 192.0.2.10 udp dport 53 accept # handle 80\nip daddr 192.0.2.10 tcp dport 53 accept # handle 81\n'
	# A port range still covers port 53, and the repair has to be able to remove it.
	# Shapes that name the same traffic without the scalar spelling the daemon
	# writes: a port set, a prefix, an address range, and a rule with no port at all.
	[ "${FAKE_DNS_PORTSET:-0}" = 1 ] &&
		printf 'ip daddr %s udp dport { 53, 853 } drop # handle 90\n' "${FAKE_DNS_GW:-192.0.2.1}"
	[ "${FAKE_DNS_NEIGHBOURPORT:-0}" = 1 ] &&
		printf 'ip daddr %s udp dport 53 drop # handle 91\n' "${FAKE_DNS_GW:-192.0.2.1}"
	[ "${FAKE_DNS_ADDRRANGE:-0}" = 1 ] &&
		printf 'ip daddr %s-192.0.2.9 udp dport 53 drop # handle 92\n' "${FAKE_DNS_GW:-192.0.2.1}"
	[ "${FAKE_DNS_PORTLESS:-0}" = 1 ] &&
		printf 'ip daddr %s drop # handle 93\n' "${FAKE_DNS_GW:-192.0.2.1}"
	# A port range that contains 53 without starting at it, a port that merely
	# begins with the same digits, and a rule that marks and negates at once.
	[ "${FAKE_DNS_SETRANGE:-0}" = 1 ] &&
		printf 'ip daddr %s udp dport { 50-53, 853 } drop # handle 101\n' "${FAKE_DNS_GW:-192.0.2.1}"
	# A rule that marks the query and then accepts it sits ahead of the pair and
	# fires first, and the counter nft renders in the middle of the line breaks any
	# match that expects the verdict next to the mark.
	[ "${FAKE_DNS_MARK_ACCEPT:-0}" = 1 ] &&
		printf 'ip daddr %s udp dport 53 counter packets 0 bytes 0 meta mark set 0x00000002 accept # handle 102\n' \
		"${FAKE_DNS_GW:-192.0.2.1}"
	[ "${FAKE_DNS_RANGE53:-0}" = 1 ] &&
		printf 'ip daddr %s udp dport 50-53 drop # handle 95\n' "${FAKE_DNS_GW:-192.0.2.1}"
	[ "${FAKE_DNS_MARK_VERDICT:-}" != "" ] &&
		printf 'ip daddr %s udp dport 53 meta mark set 0x2 %s # handle 104\n' \
		"${FAKE_DNS_GW:-192.0.2.1}" "$FAKE_DNS_MARK_VERDICT"
	[ "${FAKE_DNS_MARK_DROP:-0}" = 1 ] &&
		printf 'ip daddr %s udp dport 53 meta mark set 0x2 drop # handle 98\n' "${FAKE_DNS_GW:-192.0.2.1}"
	[ "${FAKE_DNS_OTHERPORT:-0}" = 1 ] &&
		printf 'ip daddr %s udp dport 5353 drop # handle 96\n' "${FAKE_DNS_GW:-192.0.2.1}"
	# A gateway-scoped mark rule: the insert anchors on it, so it is neither
	# interference nor something the cleanup may remove.
	[ "${FAKE_DNS_GW_MARK:-0}" = 1 ] &&
		printf 'ip daddr %s udp dport 53 meta mark set 0x2 # handle 94\n' "${FAKE_DNS_GW:-192.0.2.1}"
	[ "${FAKE_DNS_RANGEOTHER:-0}" = 1 ] &&
		printf 'ip daddr %s udp dport 80-90 drop # handle 103\n' "${FAKE_DNS_GW:-192.0.2.1}"
	[ "${FAKE_DNS_PORTRANGE:-0}" = 1 ] &&
		printf 'ip daddr %s udp dport 53-54 redirect to :53 # handle 3\n' "${FAKE_DNS_GW:-192.0.2.1}"
	[ "${FAKE_DNS_METAFORM:-0}" = 1 ] &&
		printf 'meta l4proto { tcp, udp } ip daddr %s th dport 53 redirect to :53 # handle 4\n' \
			"${FAKE_DNS_GW:-192.0.2.1}"
	# A rule scoped to one interface exempts that interface, not the board.
		[ "${FAKE_DNS_SCOPED:-0}" = 1 ] &&
			printf 'iifname "br-lan" ip daddr %s udp dport 53 accept # handle %s\n' \
				"${FAKE_DNS_GW:-192.0.2.1}" "$h"
		# A comment can carry the word accept on a rule that drops.
		[ "${FAKE_DNS_COMMENT_ACCEPT:-0}" = 1 ] &&
			printf 'ip daddr %s udp dport 53 drop comment "accept" # handle %s\n' \
				"${FAKE_DNS_GW:-192.0.2.1}" "$h"
		[ "${FAKE_DNS_UDP_QUEUE:-0}" = 1 ] || [ "${FAKE_DNS_UDP:-1}" = 1 ] &&
			printf 'ip daddr %s udp dport 53 %saccept # handle %s\n' \
				"${FAKE_DNS_GW:-192.0.2.1}" "$_cn" "$h"
		# The tcp line can carry a verdict that is not accept, which keeps the rule
		# count at two and still leaves tcp queries going through tproxy.
		[ "${FAKE_DNS_TCP_DROP:-0}" = 1 ] &&
			printf 'ip daddr %s tcp dport 53 drop # handle %s\n' \
				"${FAKE_DNS_GW:-192.0.2.1}" "$h"
		[ "${FAKE_DNS_TCP:-0}" = 1 ] &&
			printf 'ip daddr %s tcp dport 53 %saccept # handle %s\n' \
				"${FAKE_DNS_GW:-192.0.2.1}" "$_cn" "$h"
	done
	[ "${FAKE_DNS_SADDR:-0}" = 1 ] &&
		printf 'ip saddr %s udp dport 53 drop # handle 108\n' "${FAKE_DNS_GW:-192.0.2.1}"
	[ "${FAKE_DNS_PROTO:-0}" = 1 ] &&
		printf 'meta l4proto %s ip daddr %s drop # handle 109\n' \
		"${FAKE_DNS_PROTO_NAME:-icmp}" "${FAKE_DNS_GW:-192.0.2.1}"
	[ "${FAKE_DNS_IPPROTO:-0}" = 1 ] &&
		printf 'ip protocol icmp ip daddr %s drop # handle 110\n' "${FAKE_DNS_GW:-192.0.2.1}"
	[ "${FAKE_DNS_SPORT:-0}" = 1 ] &&
		printf 'ip daddr %s udp sport 53 drop # handle 107\n' "${FAKE_DNS_GW:-192.0.2.1}"
	[ "${FAKE_DNS_SETRANGE_MISS:-0}" = 1 ] &&
		printf 'ip daddr %s udp dport { 80-90, 853 } drop # handle 106\n' "${FAKE_DNS_GW:-192.0.2.1}"
	[ "${FAKE_DNS_RANGESTART:-0}" = 1 ] &&
		printf 'ip daddr %s udp dport 53-55 drop # handle 105\n' "${FAKE_DNS_GW:-192.0.2.1}"
	# A rule that drops the same traffic is not an exemption, so the fixture can
	# put one in the chain and let the verdict word decide.
	[ "${FAKE_DNS_DROP:-0}" = 1 ] &&
		printf 'ip daddr %s udp dport 53 %scounter packets 0 bytes 0 drop # handle 9\n' \
			"${FAKE_DNS_GW:-192.0.2.1}" "$_cn"
	# A redirect is neither an exemption nor a drop, so a check that only looks
	# for the address and the port would call this traffic covered.
	[ "${FAKE_DNS_REDIRECT:-0}" = 1 ] &&
		printf 'ip daddr %s udp dport 53 redirect to :53 # handle 7\n' "${FAKE_DNS_GW:-192.0.2.1}"
	# A verdict that is neither accept nor any of the harmful ones: a blocklist
	# would let this through, so the fixture has to be able to produce it.
	[ "${FAKE_DNS_QUEUE:-0}" = 1 ] &&
		printf 'ip daddr %s udp dport 53 queue # handle 6\n' "${FAKE_DNS_GW:-192.0.2.1}"
	[ "${FAKE_DNS_DROP_OTHER:-0}" = 1 ] &&
		printf 'ip daddr 203.0.113.5 udp dport 53 drop # handle 8\n' 
	[ -n "${FAKE_MARK_HANDLE:-}" ] &&
		printf 'udp dport 53 meta mark set 0x2 # handle %s\n' "$FAKE_MARK_HANDLE"
	# A second mark rule, always later, so choosing the last match instead of the
	# first one is visible.
	[ -n "${FAKE_MARK_HANDLE2:-}" ] &&
		printf 'ip6 dport 53 meta mark set 0x2 # handle %s\n' "$FAKE_MARK_HANDLE2"
	exit 0
fi
if [ "$1" = delete ] && [ "${NFT_DELETE_FAIL:-0}" = 1 ]; then exit 1; fi
if [ "$1" = list ]; then
	printf '%s %s\n' "${NFT_READ_STATE:-read}" "$*" >> "$NFT_TRACE"
	exit 0
fi
if [ "${BOOTLOCK_DESTROY_FAIL:-0}" = 1 ] &&
	[ "$*" = 'destroy table inet surflare_boot_lock' ]; then
	exit 1
fi
if [ "${ADD_ELEMENT_FAIL:-0}" = 1 ] && [ "$1" = add ] && [ "$2" = element ]; then
	exit 1
fi
if [ "${INSERT_RULE_FAIL:-0}" = 1 ] && [ "$1" = insert ] && [ "$2" = rule ]; then
	exit 1
fi
exec 7>>"$SURFLARE_NFT_LOCK"
if flock -n 7; then state=free; else state=held; fi
printf '%s %s\n' "$state" "$*" >> "$NFT_CALLS"
printf '%s %s\n' "$state" "$*" >> "$NFT_TRACE"
# Also preserve batch text so generated writes, not just argv, are inspectable.
if [ "$1" = -f ]; then
	# Per-call failure lets one install succeed and the next one fail.
	n=$(cat "$NFT_CALLCOUNT" 2>/dev/null || echo 0)
	n=$((n + 1))
	printf '%s\n' "$n" > "$NFT_CALLCOUNT"
	if [ "${NFT_FAIL_CALL:-}" = "$n" ]; then
		printf 'caller-nft-error\n' >&2
		exit "${NFT_FAIL_CODE:-23}"
	fi
	# Only a call that reached the kernel contributes batch text, so a failed
	# install can never satisfy the "installed" assertion.
	if [ "$2" = - ]; then cat >> "$NFT_BATCH"; else cat "$2" >> "$NFT_BATCH"; fi
fi
printf 'caller-nft-error\n' >&2
exit "${NFT_FAIL:-0}"
EOF
cat >"$TMP/bin/conntrack" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CONNTRACK_CALLS"
exit 0
EOF
cat >"$TMP/bin/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$IP_CALLS"
case "$*" in
'route show default') printf 'default via 192.0.2.1 dev eth0\n' ;;
esac
exit 0
EOF
mkdir "$TMP/noflock"
cat >"$TMP/noflock/nft" <<EOF2
#!/bin/sh
exec "$TMP/bin/nft" "\$@"
EOF2
chmod +x "$TMP/bin/"* "$TMP/noflock/nft"
for t in awk grep printf; do
	bin=$(command -v "$t") && ln -sf "$bin" "$TMP/noflock/$t"
done
export PATH="$TMP/bin:$PATH" NFT_CALLS="$TMP/calls" NFT_BATCH="$TMP/batch" CONNTRACK_CALLS="$TMP/conntrack" IP_CALLS="$TMP/ipcalls"
export DNS_CLEANUP_DEFER_FILE="$TMP/defer.state" DNS_STUCK_FILE="$TMP/dns_stuck"
HOLDER_PID=''
export NFT_CALLCOUNT="$TMP/callcount" NFT_TRACE="$TMP/trace"
export SURFLARE_NFT_LOCK="$TMP/lock"
. "$TMP/subject"
log() { printf '%s\n' "$*" >>"$TMP/log"; }
all_table_writes_locked() {
	# Scope: the five extracted helpers and the connect tail, which is what this
	# fixture traces. Within that region a table/chain write or a batch load must
	# hold the lock, including an unlocked `-f` (its table is inside the file, not
	# in argv, so a table-name match would miss exactly the spelling the daemon
	# uses). Element and rule writes run unlocked by design and are allowed; so is
	# the one named boot-lock teardown. Writes elsewhere in the daemon are outside
	# this fixture, and README states what the lock actually covers.
	local odd
	odd=$(grep -v '^held ' "$NFT_CALLS" 2>/dev/null |
		grep -Ev '^free (add|delete|replace|insert) (element|rule) ' |
		grep -v '^free destroy table inet surflare_boot_lock$')
	[ -z "$odd" ]
}
bootlock_position_ok() {
	# The teardown must not sit between an install batch and the read-back that
	# verifies it. The boot-lock presence check is itself a read, so it cannot
	# count as the verifying read.
	local batch destroy verify
	batch=$(grep -n -- ' -f ' "$NFT_TRACE" | tail -1 | cut -d: -f1)
	destroy=$(grep -n 'destroy table inet surflare_boot_lock' "$NFT_TRACE" |
		head -1 | cut -d: -f1)
	[ -z "$destroy" ] && return 0
	[ -n "$batch" ] && [ "$destroy" -lt "$batch" ] && return 1
	verify=$(awk -v from="${batch:-0}" 'NR > from && / list table inet / &&
		$0 !~ /surflare_boot_lock/ {print NR}' "$NFT_TRACE" | tail -1)
	# With a batch and a teardown both present, a verifying read must exist,
	# otherwise the ordering claim cannot be checked at all.
	[ -z "$verify" ] && return 1
	[ "$destroy" -gt "$verify" ]
}
_ensure_dns_enforce() { :; }
_load_tproxy_cn_direct() { :; }
_zoro_mode_loss_alert() { printf 'ensure-called\n' >>"$TMP/hooks"; }
_scoped_conntrack_flush() { :; }
_update_bypass_devices() { printf 'bypass\n' >>"$TMP/followups"; }
_ensure_gmail_smtp_ks() { printf 'gmail\n' >>"$TMP/followups"; }
_ensure_surflare_control_ks() { printf 'control\n' >>"$TMP/followups"; }
_install_cn_dns_direct() { printf 'cn\n' >>"$TMP/followups"; }
export BYPASS_LAN_DEVICES='' _diag_server_ips=127.0.0.1
export TPROXY_NFT_STAMP="$TMP/stamp"

for fn in _install_killswitch _unarm_killswitch_output _reinstall_killswitch_output _remove_surflare_table _restore_tproxy; do
	: >"$NFT_CALLS"
	: >"$NFT_BATCH"
	: >"$TMP/hooks"
	"$fn" >"$TMP/out" 2>"$TMP/err"
	rc=$?
	if [ "$rc" -eq 0 ] && grep -q '^held -f ' "$NFT_CALLS" &&
		! grep -q '^free -f ' "$NFT_CALLS" && all_table_writes_locked &&
		[ -s "$NFT_BATCH" ]; then
		ok "$fn executes a real batch only while holding the lock"
	else bad "$fn failed or ran an unlocked batch [rc=$rc]"; fi
done

holder_start first
for fn in _install_killswitch _unarm_killswitch_output _reinstall_killswitch_output _remove_surflare_table _restore_tproxy; do
	: >"$NFT_CALLS"
	: >"$NFT_BATCH"
	: >"$TMP/hooks"
	"$fn" >"$TMP/out" 2>"$TMP/err"
	rc=$?
	# 75 is the contention refusal. _install_killswitch reports it as a plain
	# failure after logging, so its expected code is pinned separately rather than
	# accepting any non-zero.
	case "$fn" in _install_killswitch) want=1 ;; *) want=75 ;; esac
	if [ "$rc" -eq "$want" ] && [ ! -s "$NFT_CALLS" ] &&
		[ ! -s "$TMP/hooks" ]; then
		ok "$fn refuses contention without an unlocked retry or repair"
	else bad "$fn certified a skipped write or ran after it [rc=$rc want=$want]"; fi
done
# A helper's correct return code is not enough: its real consumer must
# abort before any success log or continuation if no re-arm occurred.
: >"$TMP/log"
: >"$NFT_CALLS"
(. "$TMP/functions.consumer") >"$TMP/consumer.out" 2>"$TMP/consumer.err"
rc=$?
if [ "$rc" -eq 75 ] && [ ! -s "$NFT_CALLS" ] &&
	! grep -q 'consumer-continued' "$TMP/consumer.out" &&
	! grep -q 'output reinstalled after connect' "$TMP/log"; then
	ok 'connect consumer propagates a held-lock rearm without success'
else bad "connect consumer swallowed rearm failure [rc=$rc]"; fi
for table in sw_lan_tproxy killswitch; do
	: >"$NFT_CALLS"
	: >"$NFT_BATCH"
	: >"$TMP/followups"
	: >"$NFT_TRACE"
	MISSING_TABLE="$table" export MISSING_TABLE
	# sw_lan_tproxy returns the contention code directly; the killswitch tail reports
	# it as a plain failure after logging.
	case "$table" in killswitch) want=1 ;; *) want=75 ;; esac
	(. "$TMP/functions.tail") >"$TMP/tail.out" 2>"$TMP/tail.err"
	rc=$?
	if [ "$rc" -eq "$want" ] && [ ! -s "$NFT_CALLS" ] &&
		[ ! -s "$TMP/followups" ]; then
		ok "connect completion refuses contended $table without continuation"
	else bad "connect completion swallowed $table contention [rc=$rc want=$want]"; fi
done
unset MISSING_TABLE
holder_stop first

: >"$TMP/log"
: >"$NFT_CALLS"
NFT_FAIL=23 _install_killswitch >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -ne 0 ] && [ "$(grep -c -- ' -f ' "$NFT_CALLS")" -eq 1 ] &&
	grep -q caller-nft-error "$TMP/log"; then
	ok 'install failure runs once and preserves original diagnostics'
else bad 'install failure retried or discarded stderr'; fi
# Successful re-arm still allows the exact same consumer continuation.
: >"$TMP/log"
: >"$NFT_CALLS"
(. "$TMP/functions.consumer") >"$TMP/consumer.out" 2>"$TMP/consumer.err"
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'consumer-continued' "$TMP/consumer.out" &&
	grep -q 'output reinstalled after connect' "$TMP/log"; then
	ok 'connect consumer continues after a successful rearm'
else bad "connect consumer rejected a successful rearm [rc=$rc]"; fi
for table in sw_lan_tproxy killswitch; do
	body='probe_sentinel'
	wording='LAN tproxy restored'
	[ "$table" = killswitch ] && body='set server_ips'
	[ "$table" = killswitch ] && wording='Kill switch installed'
	for failing in 23 0; do
		: >"$NFT_CALLS"
		: >"$NFT_BATCH"
		: >"$TMP/followups"
		: >"$NFT_CALLCOUNT"
		: >"$NFT_TRACE"
		: >"$TMP/log"
		export MISSING_TABLE="$table" NFT_FAIL="$failing"
		(. "$TMP/functions.tail") >"$TMP/tail.out" 2>"$TMP/tail.err"
		rc=$?
		if [ "$failing" -ne 0 ]; then
			if [ "$rc" -ne 0 ] && [ ! -s "$TMP/followups" ] &&
				grep -q '^held -f ' "$NFT_CALLS" &&
				all_table_writes_locked; then
				ok "connect completion rejects failed $table installation"
			else bad "connect completion swallowed $table execution failure [rc=$rc]"; fi
		elif [ "$rc" -eq 0 ] && grep -q '^held -f ' "$NFT_CALLS" &&
			all_table_writes_locked && bootlock_position_ok &&
			grep -q "table inet $table" "$NFT_BATCH" &&
			grep -q "$body" "$NFT_BATCH" &&
			grep -q "$wording" "$TMP/log" &&
			grep -q '^cn$' "$TMP/followups" &&
			grep -q '^gmail$' "$TMP/followups" &&
			grep -q '^control$' "$TMP/followups"; then
			ok "connect completion installs $table then continues"
		else bad "connect completion rejected successful $table [rc=$rc]"; fi
	done
done
# Both tables absent, first install succeeds and the second fails: the tail
# must abort without reaching the DNS/control completion.
: >"$NFT_CALLS"
: >"$NFT_BATCH"
: >"$TMP/followups"
: >"$NFT_CALLCOUNT"
export MISSING_TABLE='sw_lan_tproxy killswitch' NFT_FAIL=0 NFT_FAIL_CALL=2
(. "$TMP/functions.tail") >"$TMP/tail.out" 2>"$TMP/tail.err"
rc=$?
if [ "$rc" -ne 0 ] && all_table_writes_locked &&
	! grep -q -E '^(cn|gmail|control)$' "$TMP/followups" &&
	[ "$(grep -c -- ' -f ' "$NFT_CALLS")" -eq 2 ] &&
	grep -q 'probe_sentinel' "$NFT_BATCH" &&
	! grep -q 'set server_ips' "$NFT_BATCH"; then
	ok 'connect completion aborts when the second install fails'
else bad "connect completion continued after the second failure [rc=$rc]"; fi
unset MISSING_TABLE NFT_FAIL NFT_FAIL_CALL

# Documented bypass pre-population is not a defect: with devices configured the
# tail issues one unlocked add element and must still pass.
: >"$NFT_CALLS"
: >"$NFT_BATCH"
: >"$TMP/followups"
: >"$NFT_CALLCOUNT"
: >"$TMP/log"
export MISSING_TABLE=killswitch BYPASS_LAN_DEVICES=192.0.2.10
(. "$TMP/functions.tail") >"$TMP/tail.out" 2>"$TMP/tail.err"
rc=$?
if [ "$rc" -eq 0 ] && all_table_writes_locked &&
	grep -q '^free add element inet killswitch bypass_src ' "$NFT_CALLS"; then
	ok 'configured bypass pre-population is an accepted unlocked write'
else bad "documented bypass write was rejected [rc=$rc]"; fi
unset MISSING_TABLE BYPASS_LAN_DEVICES
export BYPASS_LAN_DEVICES=''

# A lock that never frees must not disable the fallback forever: after the
# configured number of deferrals the cleanup runs anyway, out loud.
holder_start esc
: >"$TMP/log"
: >"$NFT_CALLS"
export FAKE_DNS_HANDLES='21'
export _DNS_CLEANUP_MAX_DEFERRALS=1 _DNS_CLEANUP_MIN_DEFER_SECS=0 _dns_cleanup_deferrals=0
rm -f "$DNS_CLEANUP_DEFER_FILE"
_cleanup_dns_fallback_rules 192.0.2.1 >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'cleaning without it' "$TMP/log" &&
	grep -q 'delete rule' "$NFT_CALLS"; then
	ok 'a permanently unavailable lock escalates instead of disabling the fallback'
else bad "lock starvation left the fallback disabled [rc=$rc]"; fi
unset FAKE_DNS_HANDLES _DNS_CLEANUP_MAX_DEFERRALS _dns_cleanup_deferrals
holder_stop esc

# Deferrals must accumulate: with the default budget, two contended ticks leave
# the counter at two and still do not escalate.
holder_start c
: >"$TMP/log"
export _dns_cleanup_deferrals=0 _DNS_CLEANUP_MAX_DEFERRALS=3 _DNS_CLEANUP_MIN_DEFER_SECS=0
rm -f "$DNS_CLEANUP_DEFER_FILE"
_cleanup_dns_fallback_rules 192.0.2.1 >/dev/null 2>&1
_cleanup_dns_fallback_rules 192.0.2.1 >/dev/null 2>&1
if [ "$_dns_cleanup_deferrals" -eq 2 ] && ! grep -q 'cleaning without it' "$TMP/log"; then
	ok 'each deferred cleanup increments the counter without escalating early'
else bad "deferral counter did not accumulate [n=$_dns_cleanup_deferrals]"; fi
holder_stop c
# A successful cleanup clears the backlog.
: >"$TMP/log"
: >"$NFT_CALLS"
export FAKE_DNS_HANDLES='24' _dns_cleanup_deferrals=2
_cleanup_dns_fallback_rules 192.0.2.1 >/dev/null 2>&1
if [ "$_dns_cleanup_deferrals" -eq 0 ] && grep -q 'delete rule' "$NFT_CALLS"; then
	ok 'a successful cleanup resets the deferral counter'
else bad "deferral counter survived a success [n=$_dns_cleanup_deferrals]"; fi
unset FAKE_DNS_HANDLES _dns_cleanup_deferrals _DNS_CLEANUP_MAX_DEFERRALS _DNS_CLEANUP_MIN_DEFER_SECS
# A host without flock must not fail closed forever: the tick counts, and the
# budget escalates like any other deferral.
: >"$TMP/log"
: >"$NFT_CALLS"
export FAKE_DNS_HANDLES='25'
export _dns_cleanup_deferrals=0 _DNS_CLEANUP_MAX_DEFERRALS=2 _DNS_CLEANUP_MIN_DEFER_SECS=0
rm -f "$DNS_CLEANUP_DEFER_FILE"
export _SAVED_PATH="$PATH"
# shellcheck disable=SC2123  # deliberate: this tick must see no flock
PATH="$TMP/noflock"
_cleanup_dns_fallback_rules 192.0.2.1 >/dev/null 2>&1
first=$?
PATH="$_SAVED_PATH"
if [ "$first" -ne 0 ] && [ "$_dns_cleanup_deferrals" -eq 1 ] &&
	grep -q 'flock unavailable or not executable (verdict 127); cleanup deferred' "$TMP/log"; then
	ok 'a host without flock counts the deferral instead of failing closed'
else bad "missing flock did not count [rc=$first n=$_dns_cleanup_deferrals]"; fi
# shellcheck disable=SC2123  # same tick environment, second deferral
PATH="$TMP/noflock"
_cleanup_dns_fallback_rules 192.0.2.1 >/dev/null 2>&1
second=$?
PATH="$_SAVED_PATH"
if [ "$second" -eq 0 ] && grep -q 'delete rule' "$NFT_CALLS"; then
	ok 'the deferral budget still escalates when flock is missing'
else
	bad "missing flock never escalated [rc=$second n=$_dns_cleanup_deferrals]"
	cat "$TMP/log" >&2
fi
unset FAKE_DNS_HANDLES _dns_cleanup_deferrals _DNS_CLEANUP_MAX_DEFERRALS _DNS_CLEANUP_MIN_DEFER_SECS _SAVED_PATH

# A failed insert whose cleanup also fails must stay tracked so a later tick
# can remove the partial rule.
export _dns_fallback_active=0 _dns_fallback_gw='' INSERT_RULE_FAIL=1 NFT_DELETE_FAIL=1 \
	FAKE_DNS_HANDLES='23' FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] && [ "$_dns_fallback_active" -eq 1 ] &&
	[ "$_dns_fallback_gw" = 192.0.2.1 ] &&
	grep -q 'nft insert failed and cleanup is incomplete' "$TMP/log"; then
	ok 'a failed insert stays tracked for a later cleanup'
else bad "failed insert left an untracked rule [rc=$rc gw=$_dns_fallback_gw]"; fi
unset INSERT_RULE_FAIL NFT_DELETE_FAIL FAKE_DNS_HANDLES FAKE_MARK_HANDLE \
	_dns_fallback_active _dns_fallback_gw

# The exemption's success path. Nothing else here asserts that the install runs at
# all, so an insert that never executes, or one that lands in the wrong chain,
# would leave the suite green.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
unset FAKE_DNS_HANDLES FAKE_DNS_GW
export _dns_fallback_active=0 _dns_fallback_gw='' FAKE_MARK_HANDLE=31 FAKE_MARK_HANDLE2=77
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] &&
	grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 udp dport 53 accept$' "$NFT_CALLS" &&
	grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 tcp dport 53 accept$' "$NFT_CALLS" &&
	[ "$(grep -c 'insert rule' "$NFT_CALLS")" -eq 2 ] &&
	! grep -q 'delete rule' "$NFT_CALLS" &&
	grep -q 'exempted gateway 192.0.2.1:53' "$TMP/log"; then
	ok 'the exemption inserts both rules under the lock and deletes nothing'
else
	bad "the exemption did not install as claimed [rc=$rc]"
	cat "$NFT_CALLS" >&2
	cat "$TMP/log" >&2
fi
unset FAKE_MARK_HANDLE FAKE_MARK_HANDLE2 _dns_fallback_active _dns_fallback_gw

# An exemption that is already in place must be left alone: this branch has no
# other positive case, so per-tick rule churn would go unnoticed.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='51' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
_insert_dns_fallback >"$TMP/out2" 2>"$TMP/err2"
rc2=$?
if [ "$rc" -eq 0 ] && [ "$rc2" -eq 0 ] && [ ! -s "$NFT_CALLS" ] &&
	[ ! -s "$CONNTRACK_CALLS" ] && ! grep -qvE '^route show default$' "$IP_CALLS" &&
	! grep -qvE '^read ' "$NFT_TRACE" &&
	[ "$_dns_fallback_gw" = 192.0.2.1 ] && ! grep -q 'WARN' "$TMP/log"; then
	ok 'an exemption that already covers the gateway is left alone, tick after tick'
else
	bad "an existing exemption was rewritten [rc=$rc/$rc2]"
	cat "$NFT_CALLS" >&2
	cat "$TMP/log" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP _dns_fallback_active _dns_fallback_gw

# A half exemption sends the other transport through tproxy, so it has to be
# repaired instead of trusted.
: >"$TMP/log"
: >"$NFT_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='52' FAKE_DNS_GW=192.0.2.1 FAKE_MARK_HANDLE=31
unset FAKE_DNS_TCP
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] &&
	grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 udp dport 53 accept$' "$NFT_CALLS" &&
	grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 tcp dport 53 accept$' "$NFT_CALLS"; then
	ok 'a half exemption is repaired instead of trusted'
else
	bad "a half exemption was treated as complete [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_MARK_HANDLE _dns_fallback_active _dns_fallback_gw

# The transport that is missing decides whether the exemption is trustworthy; a
# check that only looks at one of them would pass this state.
: >"$TMP/log"
: >"$NFT_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='53' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_DNS_UDP=0 FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] &&
	grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 udp dport 53 accept$' "$NFT_CALLS" &&
	grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 tcp dport 53 accept$' "$NFT_CALLS"; then
	ok 'an exemption missing its udp rule is repaired'
else
	bad "an exemption missing its udp rule was trusted [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_DNS_UDP FAKE_MARK_HANDLE \
	_dns_fallback_active _dns_fallback_gw

# The decision follows the gateway the function was asked about, not the one the
# daemon happens to have recorded.
: >"$TMP/log"
: >"$NFT_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=198.51.100.7 \
	FAKE_DNS_HANDLES='54' FAKE_DNS_GW=198.51.100.7 FAKE_DNS_TCP=1 FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] &&
	grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 udp dport 53 accept$' "$NFT_CALLS" &&
	grep -q ' delete rule inet surflare output handle 54' "$NFT_CALLS"; then
	ok 'the exemption decision follows the current gateway, not the recorded one'
else
	bad "the exemption decision ignored the current gateway [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_MARK_HANDLE _dns_fallback_active _dns_fallback_gw

# A drop rule for the same traffic is not an exemption, so the check has to read
# the verdict and not just the addresses.
: >"$TMP/log"
: >"$NFT_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='55' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_DNS_UDP=0 FAKE_DNS_DROP=1 \
	FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] &&
	grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 udp dport 53 accept$' "$NFT_CALLS"; then
	ok 'a drop rule for the same traffic is not read as an exemption'
else
	bad "a drop rule was read as an exemption [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_DNS_UDP FAKE_DNS_DROP FAKE_MARK_HANDLE \
	_dns_fallback_active _dns_fallback_gw

# A drop rule for a different address is none of this gateway's business; the
# exemption still stands and nothing is rewritten.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='56' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_DNS_DROP_OTHER=1
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$NFT_CALLS" ] && [ "$_dns_fallback_gw" = 192.0.2.1 ]; then
	ok 'a drop rule for another address does not invalidate the exemption'
else
	bad "a drop rule for another address forced a rewrite [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_DNS_DROP_OTHER \
	_dns_fallback_active _dns_fallback_gw

# A drop rule for this gateway on port 53 sits next to the accepts and changes
# what the kernel does, so the chain is repaired rather than called correct.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='57' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_DNS_DROP=1 FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] &&
	grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 udp dport 53 accept$' "$NFT_CALLS"; then
	ok 'a drop rule next to the accepts makes the chain due for repair'
else
	bad "a drop rule next to the accepts was left alone [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_DNS_DROP FAKE_MARK_HANDLE \
	_dns_fallback_active _dns_fallback_gw

# A redirect for the same traffic is not an exemption: the verdict decides.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='58' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_DNS_UDP=0 FAKE_DNS_REDIRECT=1 \
	FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] &&
	grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 udp dport 53 accept$' "$NFT_CALLS"; then
	ok 'a redirect for the same traffic is not read as an exemption'
else
	bad "a redirect was read as an exemption [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_DNS_UDP FAKE_DNS_REDIRECT FAKE_MARK_HANDLE \
	_dns_fallback_active _dns_fallback_gw

# Two rules for the gateway, one of which queues instead of accepting: the count
# is right and the transport is right, so only the verdict can tell.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='64' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_DNS_UDP_QUEUE=1 FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] &&
	grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 udp dport 53 accept$' "$NFT_CALLS"; then
	ok 'a queued udp rule is not read as an exemption'
else
	bad "a queued udp rule was accepted as an exemption [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_DNS_UDP_QUEUE FAKE_MARK_HANDLE \
	_dns_fallback_active _dns_fallback_gw

# A rule for this gateway that no longer accepts is still the daemon's own: the
# repair removes it rather than installing a pair beside it.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='63' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_DNS_QUEUE=1 FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] &&
	grep -q ' delete rule inet surflare output handle 6' "$NFT_CALLS" &&
	grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 udp dport 53 accept$' "$NFT_CALLS"; then
	ok 'a rule that no longer accepts is removed, not left beside the pair'
else
	bad "a queued rule for the gateway survived the repair [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_DNS_QUEUE FAKE_MARK_HANDLE \
	_dns_fallback_active _dns_fallback_gw

# udp accepts and tcp drops: the rule count is right, so only the per-transport
# verdicts can tell that tcp queries are still going through tproxy.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='65' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP_DROP=1 FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] &&
	grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 tcp dport 53 accept$' "$NFT_CALLS"; then
	ok 'a dropping tcp rule is not read as an exemption'
else
	bad "a dropping tcp rule was accepted as an exemption [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP_DROP FAKE_MARK_HANDLE \
	_dns_fallback_active _dns_fallback_gw

# Two rules for the same transport and none for the other: the count is two and
# both say accept, so only the per-transport requirement can tell.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='68 69' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=0 FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] &&
	grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 tcp dport 53 accept$' "$NFT_CALLS"; then
	ok 'two udp rules and no tcp rule is not an exemption'
else
	bad "two udp rules were accepted as an exemption [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_MARK_HANDLE _dns_fallback_active _dns_fallback_gw

# The mirror image, so neither transport can quietly stop being required.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='70 71' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_DNS_UDP=0 FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] &&
	grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 udp dport 53 accept$' "$NFT_CALLS"; then
	ok 'two tcp rules and no udp rule is not an exemption'
else
	bad "two tcp rules were accepted as an exemption [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_DNS_UDP FAKE_MARK_HANDLE \
	_dns_fallback_active _dns_fallback_gw

# The same traffic in four other spellings: each one is interference, and each is
# something the repair must be able to remove.
for _shape in PORTSET NEIGHBOURPORT ADDRRANGE PORTLESS; do
	: >"$TMP/log"
	: >"$NFT_CALLS"
	: >"$NFT_TRACE"
	: >"$CONNTRACK_CALLS"
	: >"$IP_CALLS"
	export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
		FAKE_DNS_HANDLES='95' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_MARK_HANDLE=31
	eval "export FAKE_DNS_$_shape=1"
	_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
	rc=$?
	if [ "$rc" -eq 0 ] &&
		grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 udp dport 53 accept$' "$NFT_CALLS"; then
		ok "a $_shape rule for the same traffic makes the chain due for repair"
	else
		bad "$_shape was ignored [rc=$rc]"
		cat "$NFT_CALLS" >&2
	fi
	unset "FAKE_DNS_$_shape"
	unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_MARK_HANDLE _dns_fallback_active _dns_fallback_gw
done

# A range that contains 53 without starting at it is the same traffic.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='97' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_MARK_HANDLE=31 FAKE_DNS_RANGE53=1
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'insert rule inet surflare output position 31 ip daddr 192.0.2.1 udp dport 53 accept$' "$NFT_CALLS"; then
	ok 'a port range that contains 53 makes the chain due for repair'
else
	bad "a range covering 53 was ignored [rc=$rc]"
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_MARK_HANDLE FAKE_DNS_RANGE53 _dns_fallback_active _dns_fallback_gw

# A set whose member is a range covers port 53 too: `{ 50-53, 853 }` is what real
# nft prints, and neither a scalar set test nor a range test on the token after
# `dport` sees it.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='97' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_MARK_HANDLE=31 FAKE_DNS_SETRANGE=1
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'delete rule inet surflare output handle 101$' "$NFT_CALLS"; then
	ok 'a set containing a range that covers 53 is repaired'
else
	bad "a set containing a range was ignored [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_MARK_HANDLE FAKE_DNS_SETRANGE _dns_fallback_active _dns_fallback_gw

# A set whose ranges all miss port 53 is somebody else's traffic, even though
# the braces contain a range. Real nft prints `{ 80-90, 853 }` exactly so.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_GW=192.0.2.1 FAKE_DNS_SETRANGE_MISS=1 FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'handle 106' "$NFT_CALLS"; then
	ok 'a set whose ranges miss 53 is left alone'
else
	bad "a set whose ranges miss 53 was treated as ours [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_GW FAKE_DNS_SETRANGE_MISS FAKE_MARK_HANDLE _dns_fallback_active _dns_fallback_gw

# A source port of 53 does not decide where the query goes. `sport` contains
# the letters of `dport`, so a match on that substring would delete it.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_GW=192.0.2.1 FAKE_DNS_SPORT=1 FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'handle 107' "$NFT_CALLS"; then
	ok 'a source port of 53 is left alone'
else
	bad "a source port of 53 was treated as ours [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_GW FAKE_DNS_SPORT FAKE_MARK_HANDLE _dns_fallback_active _dns_fallback_gw

# A source address equal to the gateway is traffic the gateway sent, not a
# query to it. Matching on the address alone deletes it.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_GW=192.0.2.1 FAKE_DNS_SADDR=1 FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'handle 108' "$NFT_CALLS"; then
	ok 'a source address equal to the gateway is left alone'
else
	bad "a source address was treated as ours [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_GW FAKE_DNS_SADDR FAKE_MARK_HANDLE _dns_fallback_active _dns_fallback_gw

# A portless rule scoped to one protocol covers one transport, not the query.
for _proto in icmp tcp; do
	: >"$TMP/log"
	: >"$NFT_CALLS"
	: >"$NFT_TRACE"
	: >"$CONNTRACK_CALLS"
	: >"$IP_CALLS"
	export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
		FAKE_DNS_GW=192.0.2.1 FAKE_DNS_PROTO=1 FAKE_DNS_PROTO_NAME="$_proto" FAKE_MARK_HANDLE=31
	_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
	rc=$?
	if [ "$rc" -eq 0 ] && ! grep -q 'handle 109' "$NFT_CALLS"; then
		ok "a portless $_proto rule is left alone"
	else
		bad "a portless $_proto rule was treated as ours [rc=$rc]"
		cat "$NFT_CALLS" >&2
	fi
	unset FAKE_DNS_GW FAKE_DNS_PROTO FAKE_DNS_PROTO_NAME FAKE_MARK_HANDLE \
		_dns_fallback_active _dns_fallback_gw

done

# `ip protocol icmp` names the protocol without the word `l4proto`, so a
# filter that only looks for that word still deletes it.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_GW=192.0.2.1 FAKE_DNS_IPPROTO=1 FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'handle 110' "$NFT_CALLS"; then
	ok 'an ip-protocol rule is left alone'
else
	bad "an ip-protocol rule was treated as ours [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_GW FAKE_DNS_IPPROTO FAKE_MARK_HANDLE _dns_fallback_active _dns_fallback_gw

# Marking a query and then accepting it is an exemption that fires ahead of the
# pair. The counter nft prints between the port and the mark breaks any match
# that expects the verdict beside the mark.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='97' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_MARK_HANDLE=31 FAKE_DNS_MARK_ACCEPT=1
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'delete rule inet surflare output handle 102$' "$NFT_CALLS"; then
	ok 'a rule that marks and accepts is repaired, not hidden behind the anchor rule'
else
	bad "a mark-and-accept rule was left in place [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_MARK_HANDLE FAKE_DNS_MARK_ACCEPT _dns_fallback_active _dns_fallback_gw

# Marking a query and then dropping it is interference, even though the same
# rule without the verdict is the anchor the insert uses.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='99' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_MARK_HANDLE=31 FAKE_DNS_MARK_DROP=1
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'delete rule inet surflare output handle 98$' "$NFT_CALLS"; then
	ok 'a rule that marks and drops is repaired, not hidden behind the anchor rule'
else
	bad "a mark-and-drop rule was left in place [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_MARK_HANDLE FAKE_DNS_MARK_DROP _dns_fallback_active _dns_fallback_gw

# The mark branch lists five verdicts. Drop is pinned above; each of the other
# four has to be pinned on its own, because a list that loses one word still
# passes every case that uses a different word.
for _verdict in reject redirect queue tproxy; do
	: >"$TMP/log"
	: >"$NFT_CALLS"
	: >"$NFT_TRACE"
	: >"$CONNTRACK_CALLS"
	: >"$IP_CALLS"
	export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
		FAKE_DNS_HANDLES='99' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_MARK_HANDLE=31 \
		FAKE_DNS_MARK_VERDICT="$_verdict"
	_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
	rc=$?
	if [ "$rc" -eq 0 ] && grep -q 'delete rule inet surflare output handle 104$' "$NFT_CALLS"; then
		ok "a rule that marks and then $_verdict is repaired"
	else
		bad "a mark-and-$_verdict rule was left in place [rc=$rc]"
		cat "$NFT_CALLS" >&2
	fi
	unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_MARK_HANDLE FAKE_DNS_MARK_VERDICT \
		_dns_fallback_active _dns_fallback_gw
done

# A different port that merely begins with the same digits is somebody else's
# traffic: counting it would rewrite the pair on every tick.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='98' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_MARK_HANDLE=31 FAKE_DNS_OTHERPORT=1
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$NFT_CALLS" ]; then
	ok 'a neighbouring port number is not mistaken for port 53'
else
	bad "a rule for port 5353 disturbed the exemption [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_MARK_HANDLE FAKE_DNS_OTHERPORT _dns_fallback_active _dns_fallback_gw

# A mark rule for the gateway is the anchor the insert uses. It decides nothing
# about the query, so the chain stays exempt and the rule is not deleted.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='96' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_DNS_GW_MARK=1
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$NFT_CALLS" ]; then
	ok 'a gateway mark rule neither disturbs the exemption nor gets deleted'
else
	bad "a gateway mark rule caused a rewrite [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_DNS_GW_MARK _dns_fallback_active _dns_fallback_gw

# A rule scoped to one interface exempts that interface only, so the chain is not
# covered even though the address, the port and the verdict all read right.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='66' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_DNS_UDP=0 FAKE_DNS_SCOPED=1 \
	FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] &&
	grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 udp dport 53 accept$' "$NFT_CALLS"; then
	ok 'an exemption scoped to one interface does not count as covering the board'
else
	bad "an interface-scoped exemption was trusted [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_DNS_UDP FAKE_DNS_SCOPED FAKE_MARK_HANDLE \
	_dns_fallback_active _dns_fallback_gw

# A comment saying accept on a rule that drops is not an exemption; the verdict is
# what the kernel acts on.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='67' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_DNS_UDP=0 \
	FAKE_DNS_COMMENT_ACCEPT=1 FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] &&
	grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 udp dport 53 accept$' "$NFT_CALLS"; then
	ok 'the word accept inside a comment does not make a drop rule an exemption'
else
	bad "a comment carrying accept was read as an exemption [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_DNS_UDP FAKE_DNS_COMMENT_ACCEPT \
	FAKE_MARK_HANDLE _dns_fallback_active _dns_fallback_gw

# The same traffic can be named in set form or through meta l4proto; either way a
# redirect sits in front of the two accepts and the chain does not simply accept.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='72' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_DNS_SETFORM=1 FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] &&
	grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 udp dport 53 accept$' "$NFT_CALLS"; then
	ok 'a set-form rule for the gateway makes the chain due for repair'
else
	bad "a set-form rule was ignored [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_DNS_SETFORM FAKE_MARK_HANDLE \
	_dns_fallback_active _dns_fallback_gw

: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='73' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_DNS_METAFORM=1 FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] &&
	grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 udp dport 53 accept$' "$NFT_CALLS"; then
	ok 'a meta l4proto rule for the gateway makes the chain due for repair'
else
	bad "a meta l4proto rule was ignored [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_DNS_METAFORM FAKE_MARK_HANDLE \
	_dns_fallback_active _dns_fallback_gw

# A neighbouring address that shares the gateway's leading digits is not this
# gateway: the chain is still exempt, and nothing is rewritten.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='74' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_DNS_SIBLING=1
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$NFT_CALLS" ]; then
	ok 'a neighbouring address sharing the gateway digits does not disturb the exemption'
else
	bad "a neighbouring address forced a rewrite [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_DNS_SIBLING _dns_fallback_active _dns_fallback_gw

# A port range covers port 53, so it is neither an exemption nor something the
# repair may leave behind.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='75' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_DNS_PORTRANGE=1 FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] &&
	grep -q ' delete rule inet surflare output handle 3' "$NFT_CALLS" &&
	grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 udp dport 53 accept$' "$NFT_CALLS"; then
	ok 'a port range over port 53 is removed rather than repaired around'
else
	bad "a port range survived the repair [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_DNS_PORTRANGE FAKE_MARK_HANDLE \
	_dns_fallback_active _dns_fallback_gw
# A range that does not contain 53 is somebody else's traffic even though it
# names this gateway: counting it would rewrite the pair on every tick.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='75' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_DNS_RANGEOTHER=1 FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'handle 103' "$NFT_CALLS"; then
	ok 'a port range that misses 53 is left alone'
else
	bad "a range that misses 53 was treated as ours [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_DNS_RANGEOTHER FAKE_MARK_HANDLE \
	_dns_fallback_active _dns_fallback_gw
# A range that starts at 53 matches the scalar spelling as well as the range
# spelling. Counting it twice deletes the handle twice, and the second
# delete fails.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_GW=192.0.2.1 FAKE_DNS_RANGESTART=1 FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
_deletes=$(grep -c 'delete rule inet surflare output handle 105$' "$NFT_CALLS")
if [ "$rc" -eq 0 ] && [ "$_deletes" -ge 1 ]; then
	ok 'a range that starts at 53 is removed'
else
	bad "a range starting at 53 was left in place [rc=$rc deletes=$_deletes]"
	cat "$NFT_CALLS" >&2
fi

# The selector itself must emit a range that starts at 53 exactly once. The
# repair calls the cleanup more than once, so the call log cannot show this.
_once=$(_dns_gw_port_lines 'ip daddr 192.0.2.1 udp dport 53-55 drop # handle 105' 192.0.2.1 | grep -c .)
if [ "$_once" -eq 1 ]; then
	ok 'a range that starts at 53 is counted once'
else
	bad "a range starting at 53 was counted $_once times"
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_DNS_RANGESTART FAKE_MARK_HANDLE \
	_dns_fallback_active _dns_fallback_gw

# Cleanup has to find its own rules when they carry counters, or an old gateway's
# exemption stays in the chain and nothing removes it.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=198.51.100.7 \
	FAKE_DNS_HANDLES='62' FAKE_DNS_GW=198.51.100.7 FAKE_DNS_TCP=1 FAKE_DNS_COUNTER=1 FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] &&
	grep -q ' delete rule inet surflare output handle 62' "$NFT_CALLS" &&
	grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 udp dport 53 accept$' "$NFT_CALLS"; then
	ok 'the previous gateway is removed even when its rules carry counters'
else
	bad "a countered exemption for the old gateway was not removed [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_DNS_COUNTER FAKE_MARK_HANDLE \
	_dns_fallback_active _dns_fallback_gw

# nft prints counters in the middle of a rule, so a verdict check that expects the
# word next to the port silently misses a real exemption.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='59' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_DNS_COUNTER=1
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$NFT_CALLS" ]; then
	ok 'an exemption whose rules carry counters is still recognised'
else
	bad "counters in the rendered rule hid an existing exemption [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_DNS_COUNTER _dns_fallback_active _dns_fallback_gw

# A drop rendered with counters ends up three words away from the port; the
# verdict still decides, so this chain is due for repair.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='60' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_DNS_UDP=0 \
	FAKE_DNS_COUNTER=1 FAKE_DNS_DROP=1 FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] &&
	grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 udp dport 53 accept$' "$NFT_CALLS"; then
	ok 'a drop rule carrying counters is not read as an exemption'
else
	bad "a countered drop rule was trusted [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_DNS_UDP FAKE_DNS_COUNTER FAKE_DNS_DROP \
	FAKE_MARK_HANDLE _dns_fallback_active _dns_fallback_gw

# Accepts plus a redirect for the same traffic: the chain does not simply accept,
# so it is repaired rather than called correct.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
: >"$CONNTRACK_CALLS"
: >"$IP_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 \
	FAKE_DNS_HANDLES='61' FAKE_DNS_GW=192.0.2.1 FAKE_DNS_TCP=1 FAKE_DNS_REDIRECT=1 FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] &&
	grep -q ' insert rule inet surflare output position 31 ip daddr 192.0.2.1 udp dport 53 accept$' "$NFT_CALLS"; then
	ok 'a redirect next to the accepts makes the chain due for repair'
else
	bad "a redirect next to the accepts was left alone [rc=$rc]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_DNS_TCP FAKE_DNS_REDIRECT FAKE_MARK_HANDLE \
	_dns_fallback_active _dns_fallback_gw

# The deferral records the gateway it was asked about, not the default route,
# which happen to be the same address unless the fixture separates them.
holder_start dgw
: >"$TMP/log"
rm -f "$DNS_CLEANUP_DEFER_FILE"
export _dns_cleanup_deferrals=0
_cleanup_dns_fallback_rules 198.51.100.7 >/dev/null 2>&1
holder_stop dgw
_recorded=$(cat "$DNS_CLEANUP_DEFER_FILE" 2>/dev/null)
if [ "$(printf '%s\n' "$_recorded" | awk '{print $3}')" = 198.51.100.7 ]; then
	ok 'the deferral records the gateway it was asked about'
else
	bad "the deferral recorded the wrong gateway [$_recorded]"
fi
rm -f "$DNS_CLEANUP_DEFER_FILE"
export _dns_cleanup_deferrals=0

# A gateway change must remove the old exemption before installing the new one,
# or the chain carries both until the next tick retries.
: >"$TMP/log"
: >"$NFT_CALLS"
export _dns_fallback_active=1 _dns_fallback_gw=198.51.100.7 \
	FAKE_DNS_HANDLES='41' FAKE_DNS_GW=198.51.100.7 FAKE_MARK_HANDLE=31
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
_gone=$(grep -n 'delete rule inet surflare output handle 41' "$NFT_CALLS" | head -1 | cut -d: -f1)
_added=$(grep -n 'insert rule' "$NFT_CALLS" | head -1 | cut -d: -f1)
if [ "$rc" -eq 0 ] && [ -n "$_gone" ] && [ -n "$_added" ] && [ "$_gone" -lt "$_added" ] &&
	[ "$_dns_fallback_gw" = 192.0.2.1 ]; then
	ok 'the old gateway is removed before the new exemption is installed'
else
	bad "the gateway change reordered its writes [rc=$rc gone=$_gone added=$_added]"
	cat "$NFT_CALLS" >&2
fi
unset FAKE_DNS_HANDLES FAKE_DNS_GW FAKE_MARK_HANDLE _dns_fallback_active _dns_fallback_gw

# The deferral log has to name the verdict, so a setup failure cannot look like
# contention in the log the daemon leaves behind.
holder_start v75
: >"$TMP/log"
export FAKE_DNS_HANDLES='44'
_cleanup_dns_fallback_rules 192.0.2.1 >/dev/null 2>&1
holder_stop v75
if grep -q 'nft lock busy (verdict 75)' "$TMP/log"; then
	ok 'contention is logged with its verdict code'
else
	bad 'contention was logged without its verdict'
	cat "$TMP/log" >&2
fi
rm -f "$DNS_CLEANUP_DEFER_FILE"
export _dns_cleanup_deferrals=0
unset FAKE_DNS_HANDLES

# A lock that cannot even be opened is a setup error, not contention; the two have
# to stay distinguishable in the log.
: >"$TMP/log"
rm -f "$DNS_CLEANUP_DEFER_FILE"
export _dns_cleanup_deferrals=0
NFT_LOCK_FILE="$TMP/no-such-directory/lock" \
	_cleanup_dns_fallback_rules 192.0.2.1 >/dev/null 2>&1
rc=$?
if grep -q 'cannot open the nft lock (verdict 70)' "$TMP/log"; then
	ok 'a lock that cannot be opened is reported as a setup error, not as contention'
else
	bad "the setup-error verdict was lost [rc=$rc]"
	cat "$TMP/log" >&2
fi
rm -f "$DNS_CLEANUP_DEFER_FILE"
export _dns_cleanup_deferrals=0

# A blocking lock would hang this suite instead of failing it, so the contention
# path runs against a deadline of its own.
_start=$(date +%s)
(
	exec 8>>"$SURFLARE_NFT_LOCK"
	flock -n 8 || exit 1
	_cleanup_dns_fallback_rules 192.0.2.1 >/dev/null 2>&1
) >/dev/null 2>&1 &
_bounded_pid=$!
(
	sleep 15
	kill -9 "$_bounded_pid" 2>/dev/null
) >/dev/null 2>&1 &
_bounded_watch=$!
wait "$_bounded_pid" 2>/dev/null
kill "$_bounded_watch" 2>/dev/null
wait "$_bounded_watch" 2>/dev/null || true
_elapsed=$(($(date +%s) - _start))
if [ "$_elapsed" -lt 15 ]; then
	ok 'a held lock is refused without blocking'
else
	bad "the cleanup blocked on a held lock for ${_elapsed}s"
fi
unset _bounded_pid _bounded_watch _elapsed _start

# The budget also needs a minimum age, so a burst inside one tick cannot
# escalate; and the count survives the process, because it lives in a file.
holder_start win
: >"$TMP/log"
: >"$NFT_CALLS"
export FAKE_DNS_HANDLES='28'
export _DNS_CLEANUP_MAX_DEFERRALS=2 _DNS_CLEANUP_MIN_DEFER_SECS=3600 _dns_cleanup_deferrals=0
rm -f "$DNS_CLEANUP_DEFER_FILE"
_cleanup_dns_fallback_rules 192.0.2.1 >/dev/null 2>&1
_cleanup_dns_fallback_rules 192.0.2.1 >/dev/null 2>&1
_state=$(cat "$DNS_CLEANUP_DEFER_FILE" 2>/dev/null)
holder_stop win
_count=''
set -- $_state
[ $# -ge 2 ] && _count=$2
if [ -n "$_state" ] && [ "$_count" = 2 ] && ! grep -q 'cleaning without it' "$TMP/log"; then
	ok 'the deferral count reaches its budget but waits for the minimum age'
else bad "the budget escalated inside one tick or lost its count [$_state]"; fi
# A count recorded well in the past escalates on the next single call, which is
# what proves the file -- not a shell variable -- is the source of truth.
printf '%s 2 192.0.2.1\n' "$(($(date +%s) - 7200))" >"$DNS_CLEANUP_DEFER_FILE"
: >"$TMP/log"
: >"$NFT_CALLS"
export _dns_cleanup_deferrals=0
holder_start win2
_cleanup_dns_fallback_rules 192.0.2.1 >/dev/null 2>&1
rc=$?
holder_stop win2
if [ "$rc" -eq 0 ] && grep -q 'cleaning without it' "$TMP/log" &&
	grep -q 'delete rule' "$NFT_CALLS"; then
	ok 'a deferral recorded earlier escalates without any in-process state'
else bad "an old deferral did not escalate [rc=$rc]"; fi
unset FAKE_DNS_HANDLES _dns_cleanup_deferrals _DNS_CLEANUP_MAX_DEFERRALS _DNS_CLEANUP_MIN_DEFER_SECS

# A record left by another gateway, or one that a backwards clock step made
# future-dated, must not escalate this episode.
printf '%s 9 198.51.100.7\n' "$(($(date +%s) - 7200))" >"$DNS_CLEANUP_DEFER_FILE"
: >"$TMP/log"
: >"$NFT_CALLS"
export FAKE_DNS_HANDLES='29'
export _dns_cleanup_deferrals=0 _DNS_CLEANUP_MAX_DEFERRALS=2 _DNS_CLEANUP_MIN_DEFER_SECS=0
holder_start gw
_cleanup_dns_fallback_rules 192.0.2.1 >/dev/null 2>&1
rc=$?
holder_stop gw
if [ "$rc" -ne 0 ] && ! grep -q 'cleaning without it' "$TMP/log"; then
	ok 'a deferral recorded for another gateway does not escalate'
else bad "another gateway's record escalated [rc=$rc]"; fi
# the same record for this gateway must still escalate, or the binding is a mute
printf '%s 9 192.0.2.1\n' "$(($(date +%s) - 7200))" >"$DNS_CLEANUP_DEFER_FILE"
: >"$TMP/log"
holder_start same
_cleanup_dns_fallback_rules 192.0.2.1 >/dev/null 2>&1
rc=$?
holder_stop same
if [ "$rc" -eq 0 ] && grep -q 'cleaning without it' "$TMP/log"; then
	ok 'a deferral recorded for this gateway still escalates'
else bad "the gateway binding muted a real deferral [rc=$rc]"; fi
printf '%s 9 192.0.2.1\n' "$(($(date +%s) + 7200))" >"$DNS_CLEANUP_DEFER_FILE"
: >"$TMP/log"
holder_start clk
_cleanup_dns_fallback_rules 192.0.2.1 >/dev/null 2>&1
rc=$?
holder_stop clk
if [ "$rc" -eq 0 ] && grep -qE 'cleaning without it' "$TMP/log" &&
	grep -qE 'over [0-9]+s' "$TMP/log"; then
	ok 'a future-dated stamp rebases instead of freezing the age gate'
else bad "a backwards clock step froze the age gate [rc=$rc]"; fi
unset FAKE_DNS_HANDLES _dns_cleanup_deferrals _DNS_CLEANUP_MAX_DEFERRALS _DNS_CLEANUP_MIN_DEFER_SECS

# A read-only state file must not disable the escalation: the count still has to
# advance within the process.
: >"$TMP/log"
: >"$NFT_CALLS"
export FAKE_DNS_HANDLES='30'
export _dns_cleanup_deferrals=0 _DNS_CLEANUP_MAX_DEFERRALS=2 _DNS_CLEANUP_MIN_DEFER_SECS=0
_SAVED_DEFER="$DNS_CLEANUP_DEFER_FILE"
DNS_CLEANUP_DEFER_FILE="$TMP/no_such_dir/defer"
holder_start ro
_cleanup_dns_fallback_rules 192.0.2.1 >/dev/null 2>&1
one=$?
_cleanup_dns_fallback_rules 192.0.2.1 >/dev/null 2>&1
two=$?
holder_stop ro
DNS_CLEANUP_DEFER_FILE="$_SAVED_DEFER"
if [ "$one" -ne 0 ] && [ "$two" -eq 0 ] && grep -q 'delete rule' "$NFT_CALLS"; then
	ok 'an unwritable state file still escalates within the process'
else bad "unwritable state file froze the count [rc=$one/$two]"; fi
unset FAKE_DNS_HANDLES _dns_cleanup_deferrals _DNS_CLEANUP_MAX_DEFERRALS _DNS_CLEANUP_MIN_DEFER_SECS _SAVED_DEFER

# A corrupted stamp starts a new episode instead of escalating.
printf 'abc 9 192.0.2.1\n' >"$DNS_CLEANUP_DEFER_FILE"
: >"$TMP/log"
export FAKE_DNS_HANDLES='31'
export _dns_cleanup_deferrals=0 _DNS_CLEANUP_MAX_DEFERRALS=2 _DNS_CLEANUP_MIN_DEFER_SECS=0
holder_start st
_cleanup_dns_fallback_rules 192.0.2.1 >/dev/null 2>&1
rc=$?
holder_stop st
_state=$(cat "$DNS_CLEANUP_DEFER_FILE" 2>/dev/null)
set -- $_state
if [ "$rc" -ne 0 ] && [ "${2:-}" = 1 ]; then
	ok 'a corrupted deferral stamp restarts the episode'
else bad "a corrupted stamp escalated [rc=$rc state=$_state]"; fi
unset FAKE_DNS_HANDLES _dns_cleanup_deferrals _DNS_CLEANUP_MAX_DEFERRALS _DNS_CLEANUP_MIN_DEFER_SECS

# The startup path must clear a record left by a previous run.
printf '%s 3 192.0.2.1\n' "$(($(date +%s) - 7200))" >"$DNS_CLEANUP_DEFER_FILE"
: >"$TMP/log"
export FAKE_DNS_HANDLES='32' NFT_DELETE_FAIL=1
_startup_cleanup_dns_fallback >/dev/null 2>&1
if [ ! -e "$DNS_CLEANUP_DEFER_FILE" ]; then
	ok 'startup clears a stale deferral record'
else bad 'startup left a stale deferral record behind'; fi
unset FAKE_DNS_HANDLES NFT_DELETE_FAIL

# A caller that holds the lock is not detected. Two ticks defer, the third runs
# the body while the lock is still held -- README says so, and this pins it.
holder_start re2
: >"$TMP/log"
: >"$NFT_CALLS"
export FAKE_DNS_HANDLES='27'
export _dns_cleanup_deferrals=0 _DNS_CLEANUP_MAX_DEFERRALS=3 _DNS_CLEANUP_MIN_DEFER_SECS=0
rm -f "$DNS_CLEANUP_DEFER_FILE"
_cleanup_dns_fallback_rules 192.0.2.1 >/dev/null 2>&1
one=$?
_cleanup_dns_fallback_rules 192.0.2.1 >/dev/null 2>&1
two=$?
_cleanup_dns_fallback_rules 192.0.2.1 >/dev/null 2>&1
three=$?
holder_stop re2
if [ "$one" -ne 0 ] && [ "$two" -ne 0 ] && [ "$three" -eq 0 ] &&
	grep -q '^held delete rule' "$NFT_CALLS"; then
	ok 'a caller-held lock defers twice and then deletes while still held'
else bad "caller-held lock behaviour differs from README [rc=$one/$two/$three]"; fi
unset FAKE_DNS_HANDLES _dns_cleanup_deferrals _DNS_CLEANUP_MAX_DEFERRALS _DNS_CLEANUP_MIN_DEFER_SECS

# An unopenable lock file is a deferral too, not a silent give-up.
: >"$TMP/log"
: >"$NFT_CALLS"
export FAKE_DNS_HANDLES='26'
export _dns_cleanup_deferrals=0 _DNS_CLEANUP_MAX_DEFERRALS=2 _DNS_CLEANUP_MIN_DEFER_SECS=0
rm -f "$DNS_CLEANUP_DEFER_FILE"
export _SAVED_LOCK="$NFT_LOCK_FILE"
NFT_LOCK_FILE="$TMP/no_such_dir/lock"
_cleanup_dns_fallback_rules 192.0.2.1 >/dev/null 2>&1
first=$?
if [ "$first" -ne 0 ] && [ "$_dns_cleanup_deferrals" -eq 1 ]; then
	ok 'an unopenable lock file counts as a deferral'
else bad "unopenable lock was not counted [rc=$first n=$_dns_cleanup_deferrals]"; fi
_cleanup_dns_fallback_rules 192.0.2.1 >/dev/null 2>&1
second=$?
NFT_LOCK_FILE="$_SAVED_LOCK"
if [ "$second" -eq 0 ] && grep -q 'delete rule' "$NFT_CALLS"; then
	ok 'an unopenable lock still escalates after the budget'
else bad "unopenable lock never escalated [rc=$second]"; fi
unset FAKE_DNS_HANDLES _dns_cleanup_deferrals _DNS_CLEANUP_MAX_DEFERRALS _DNS_CLEANUP_MIN_DEFER_SECS _SAVED_LOCK

# A gateway change must clean the old exemption first; when that cannot be done
# now, the recorded gateway is kept so a later tick retries.
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.9
: >"$TMP/log"
export FAKE_DNS_HANDLES='11' NFT_DELETE_FAIL=1 FAKE_DNS_GW=192.0.2.9
_insert_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] && [ "$_dns_fallback_active" -eq 1 ] &&
	[ "$_dns_fallback_gw" = 192.0.2.9 ] &&
	grep -q 'old gateway exemption not removable yet' "$TMP/log"; then
	ok 'gateway change is deferred while the old exemption cannot be removed'
else bad "gateway change orphaned the old exemption [rc=$rc gw=$_dns_fallback_gw]"; fi
unset FAKE_DNS_HANDLES NFT_DELETE_FAIL FAKE_DNS_GW _dns_fallback_active _dns_fallback_gw

# Cleanup must not run unlocked: with the lock held elsewhere it defers.
holder_start dns
: >"$TMP/log"
export FAKE_DNS_HANDLES='12'
_cleanup_dns_fallback_rules 192.0.2.1 >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'cleanup deferred' "$TMP/log"; then
	ok 'cleanup defers instead of deleting handles unlocked'
else bad "cleanup ran without the lock [rc=$rc]"; fi
unset FAKE_DNS_HANDLES
holder_stop dns

# A teardown that follows a batch with no verifying read is not "after the
# read-back": the rule must be false rather than vacuously true.
: >"$NFT_CALLS"
: >"$NFT_TRACE"
printf 'held -f %s\nfree destroy table inet surflare_boot_lock\n' "$TMP/batch.nft" \
	>"$NFT_TRACE"
if bootlock_position_ok; then
	bad 'ordering rule certified a teardown with no verifying read'
else ok 'ordering rule rejects a teardown with no verifying read'; fi

# The DNS fallback cleanup reports success only when every handle was removed.
: >"$TMP/log"
: >"$NFT_CALLS"
: >"$NFT_TRACE"
export FAKE_DNS_HANDLES='7 8' NFT_DELETE_FAIL=1
_cleanup_dns_fallback_rules 192.0.2.1 >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'failed to delete handle' "$TMP/log" &&
	all_table_writes_locked; then
	ok 'failed DNS fallback delete is reported as an incomplete cleanup'
else bad "DNS fallback cleanup claimed success [rc=$rc]"; fi
export NFT_DELETE_FAIL=0
_cleanup_dns_fallback_rules 192.0.2.1 >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] && all_table_writes_locked &&
	[ "$(grep -c -- ' delete rule ' "$NFT_CALLS" 2>/dev/null || true)" -eq 2 ]; then
	ok 'DNS fallback cleanup reports success when every handle is removed'
else bad "DNS fallback cleanup failed on a clean run [rc=$rc]"; fi
unset FAKE_DNS_HANDLES NFT_DELETE_FAIL

# An unreadable chain cannot certify a clean cleanup.
: >"$TMP/log"
export FAKE_LIST_FAIL=1
_cleanup_dns_fallback_rules 192.0.2.1 >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'cannot read the output chain' "$TMP/log"; then
	ok 'an unreadable chain is not reported as a clean cleanup'
else bad "unreadable chain certified a clean cleanup [rc=$rc]"; fi
unset FAKE_LIST_FAIL

# The removal path must not claim recovery when the cleanup was incomplete.
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1
: >"$TMP/log"
export FAKE_DNS_HANDLES='9' NFT_DELETE_FAIL=1
_remove_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
retained=$_dns_fallback_active
# Kept so a later removal path retries the operation that just failed.
if [ "$retained" -eq 1 ] && ! grep -q 'restored tunnel DNS' "$TMP/log" &&
	grep -q 'cleanup incomplete' "$TMP/log"; then
	ok 'incomplete DNS fallback cleanup is not reported as restored'
else bad "DNS fallback removal claimed recovery [rc=$rc retained=$retained]"; fi
export _dns_fallback_active=1 _dns_fallback_gw=192.0.2.1 NFT_DELETE_FAIL=0
: >"$TMP/log"
_remove_dns_fallback >"$TMP/out" 2>"$TMP/err"
rc=$?
if grep -q 'restored tunnel DNS' "$TMP/log"; then
	ok 'complete DNS fallback cleanup is reported as restored'
else bad "DNS fallback removal did not report recovery [rc=$rc]"; fi
unset FAKE_DNS_HANDLES NFT_DELETE_FAIL FAKE_DNS_GW _dns_fallback_active _dns_fallback_gw

# A failed destroy must not be reported as "boot lock removed".
: >"$NFT_CALLS"
: >"$NFT_BATCH"
: >"$TMP/followups"
: >"$NFT_CALLCOUNT"
: >"$TMP/log"
export MISSING_TABLE=killswitch BOOTLOCK_DESTROY_FAIL=1 NFT_FAIL=0
(. "$TMP/functions.tail") >"$TMP/tail.out" 2>"$TMP/tail.err"
rc=$?
if ! grep -q 'Boot lock removed' "$TMP/log" &&
	grep -q 'boot lock still present after destroy attempt' "$TMP/log"; then
	ok 'failed boot-lock destroy is not reported as removed'
else bad 'failed boot-lock destroy was reported as removed'; fi
unset MISSING_TABLE BOOTLOCK_DESTROY_FAIL

# A failed server_ips repopulation must not be reported as restored.
printf '198.51.100.7 198.51.100.8\n' >"$TMP/server_ips"
: >"$NFT_CALLS"
: >"$NFT_BATCH"
: >"$TMP/followups"
: >"$NFT_CALLCOUNT"
: >"$TMP/log"
export MISSING_TABLE=killswitch ADD_ELEMENT_FAIL=1 NFT_FAIL=0 _diag_server_ips=''
(. "$TMP/functions.tail") >"$TMP/tail.out" 2>"$TMP/tail.err"
rc=$?
if ! grep -q 'server_ips restored from disk' "$TMP/log" &&
	grep -q 'failed to repopulate server_ips' "$TMP/log"; then
	ok 'failed server_ips repopulation is not reported as restored'
else bad 'failed server_ips repopulation was reported as restored'; fi
unset MISSING_TABLE ADD_ELEMENT_FAIL
export _diag_server_ips=127.0.0.1

# The reinstall path has its own boot-lock removal; a failed destroy there must
# not be reported as removed either.
: >"$NFT_CALLS"
: >"$NFT_BATCH"
: >"$NFT_TRACE"
: >"$TMP/log"
export BOOTLOCK_DESTROY_FAIL=1
_reinstall_killswitch_output >"$TMP/out" 2>"$TMP/err"
rc=$?
if ! grep -q 'Boot lock removed: killswitch output reinstalled' "$TMP/log" &&
	grep -q 'boot lock still present after destroy attempt' "$TMP/log"; then
	ok 'reinstall path does not claim a failed boot-lock removal'
else bad "reinstall path claimed a failed boot-lock removal [rc=$rc]"; fi
unset BOOTLOCK_DESTROY_FAIL

# Positive arms: the two documented unlocked writes are reported when they do
# succeed, and correct code passes the table-write auditor.
printf '198.51.100.7 198.51.100.8\n' >"$TMP/server_ips"
: >"$NFT_CALLS"
: >"$NFT_BATCH"
: >"$NFT_TRACE"
: >"$TMP/followups"
: >"$TMP/log"
export MISSING_TABLE=killswitch NFT_FAIL=0 _diag_server_ips=''
(. "$TMP/functions.tail") >"$TMP/tail.out" 2>"$TMP/tail.err"
rc=$?
if [ "$rc" -eq 0 ] && all_table_writes_locked &&
	grep -q 'server_ips restored from disk' "$TMP/log" &&
	grep -q 'Boot lock removed: killswitch now armed' "$TMP/log"; then
	ok 'documented unlocked writes succeed and are reported'
else bad "documented unlocked writes misreported [rc=$rc]"; fi
unset MISSING_TABLE
export _diag_server_ips=127.0.0.1

# The bypass pre-population must come after the killswitch batch, not before it.
: >"$NFT_CALLS"
: >"$NFT_BATCH"
: >"$NFT_TRACE"
: >"$TMP/followups"
: >"$TMP/log"
export MISSING_TABLE=killswitch BYPASS_LAN_DEVICES=192.0.2.10
(. "$TMP/functions.tail") >"$TMP/tail.out" 2>"$TMP/tail.err"
rc=$?
batch_line=$(grep -n -- ' -f ' "$NFT_TRACE" | head -1 | cut -d: -f1)
bypass_line=$(grep -n 'add element inet killswitch bypass_src' "$NFT_TRACE" | head -1 | cut -d: -f1)
if [ "$rc" -eq 0 ] && [ -n "$batch_line" ] && [ -n "$bypass_line" ] &&
	[ "$bypass_line" -gt "$batch_line" ]; then
	ok 'bypass pre-population follows the killswitch batch'
else bad "bypass pre-population ordering wrong [rc=$rc batch=$batch_line bypass=$bypass_line]"; fi
unset MISSING_TABLE BYPASS_LAN_DEVICES
export BYPASS_LAN_DEVICES=''
for pair in 'sw_lan_tproxy:LAN tproxy restored' 'killswitch:Kill switch installed'; do
	table=${pair%%:*}
	wording=${pair#*:}
	: >"$NFT_CALLS"
	: >"$NFT_BATCH"
	: >"$TMP/followups"
	: >"$NFT_CALLCOUNT"
	: >"$TMP/log"
	export MISSING_TABLE="$table" FAKE_LIST_FAIL="$table" NFT_FAIL=0
	(. "$TMP/functions.tail") >"$TMP/tail.out" 2>"$TMP/tail.err"
	rc=$?
	if [ "$rc" -ne 0 ] && ! grep -q "$wording" "$TMP/log" &&
		! grep -q -E '^(cn|gmail|control)$' "$TMP/followups"; then
		ok "failed $table read-back is never reported as installed"
	else bad "unverified $table install was reported successful [rc=$rc]"; fi
done
unset FAKE_LIST_FAIL
printf 'RESULT: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
if [ "$pass" -ne 105 ]; then
	printf 'FAIL: expected 105 cases, ran %s\n' "$pass"
	exit 1
fi
