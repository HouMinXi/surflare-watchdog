#!/bin/sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT=${ZORO_TEST_SCRIPT:-"$ROOT/router/zoro-exit"}
[ -f "$SCRIPT" ] || {
	echo "FAIL: cannot read $SCRIPT"
	exit 1
}
TMP=$(mktemp -d) || exit 1
_holder_pid=''
_killed=''
_cleanup_failed=''
# One EXIT trap, installed before anything that can fail: kill the holder this run
# started -- the pid in _holder_pid, which only this script records -- then remove
# the temp dir.
reap_and_cleanup() {
	# A signal and the exit that follows it both reach this handler. The kill
	# runs once; the temp-dir removal is attempted every time because it is
	# idempotent and must not be skippable by a flag left set from outside.
	if [ -z "${_killed:-}" ]; then
		_killed=1
		if [ -n "${_holder_pid:-}" ] && [ "$_holder_pid" != "$$" ]; then
			kill -0 "$_holder_pid" 2>/dev/null && kill -9 "$_holder_pid" 2>/dev/null
		fi
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
trap 'rc=$?; reap_and_cleanup; [ -n "${_cleanup_failed:-}" ] && [ "$rc" -eq 0 ] && rc=1; exit "$rc"' EXIT
trap 'reap_and_cleanup; exit 1' INT TERM HUP
BIN="$TMP/bin"
STATE="$TMP/nft.state"
IPDIR="$TMP/ip"
mkdir -p "$BIN" "$IPDIR"
MUT="$TMP/mutations.log"
CURL_LOG="$TMP/curl.log"
SERVICE_LOG="$TMP/service.log"
: >"$MUT"
: >"$CURL_LOG"
: >"$SERVICE_LOG"

cat >"$BIN/logger" <<'EOF'
#!/bin/sh
exit 0
EOF

cat >"$BIN/ss" <<'EOF'
#!/bin/sh
case "${FAKE_LISTEN:-public}" in
	public) echo 'LISTEN 0 4096 *:7895 *:*' ;;
	loopback) echo 'LISTEN 0 4096 127.0.0.1:7895 0.0.0.0:*' ;;
	auto) [ -f "${FAKE_LISTEN_FLAG:?}" ] && echo 'LISTEN 0 4096 *:7895 *:*' ;;
esac
exit 0
EOF

cat >"$BIN/nft" <<'EOF'
#!/bin/sh
# Multi-chain fake. Each chain has independent state and allocated handles
# increase monotonically so replacing a live rule cannot delete the new one.
chain_file() {
	case "$1 $2" in
	"sw_lan_tproxy prerouting") printf '%s\n' "${FAKE_NFT_STATE:?}" ;;
	"surflare prerouting") printf '%s\n' "${FAKE_SF_PRE_STATE:?}" ;;
	"surflare output") printf '%s\n' "${FAKE_SF_OUT_STATE:?}" ;;
	"killswitch output") printf '%s\n' "${FAKE_KS_OUT_STATE:?}" ;;
	*) exit 1 ;;
	esac
}

_show_handles=0
if [ "${1:-}" = "-a" ]; then
	shift
	_show_handles=1
fi

case "$1 $2" in
"list tables")
	[ "${FAKE_NFT_TABLE_RC:-0}" = 0 ] || exit "$FAKE_NFT_TABLE_RC"
	for t in sw_lan_tproxy surflare killswitch; do
		[ "${FAKE_ABSENT_TABLE:-}" != "$t" ] || continue
		printf 'table inet %s\n' "$t"
	done
	exit 0
	;;
"list table")
	[ "${FAKE_ABSENT_TABLE:-}" != "$4" ] || exit 1
	[ "${FAKE_NFT_TABLE_RC:-0}" = 0 ] || exit "$FAKE_NFT_TABLE_RC"
	case "$4" in
	sw_lan_tproxy) printf 'chain prerouting {\n' ;;
	surflare) printf 'chain prerouting {\n'
		[ "${FAKE_ABSENT_SF_OUTPUT:-0}" = 1 ] || printf 'chain output {\n' ;;
	killswitch) printf 'chain output {\n' ;;
	*) exit 1 ;;
	esac
	exit 0
	;;
"list chain")
	[ "${FAKE_ABSENT_TABLE:-}" != "$4" ] || exit 1
	if [ -n "${FAKE_POST_DELETE_FAIL:-}" ] &&
		[ -f "$FAKE_POST_DELETE_FAIL" ]; then exit 1; fi
	[ "$4 $5" != "surflare output" ] || \
		[ "${FAKE_SF_CHAIN_RC:-0}" = 0 ] || exit 1
	# argv: list chain inet TABLE CHAIN
	_file=$(chain_file "$4" "$5") || exit 1
	[ -f "$_file" ] || exit 1
	rc=${FAKE_NFT_CHAIN_RC:-0}
	[ "$rc" -eq 0 ] || exit "$rc"
	while IFS= read -r line; do
		if [ "$_show_handles" -eq 1 ]; then
			printf '%s\n' "$line"
		else
			printf '%s\n' "${line%% # handle*}"
		fi
	done < "$_file"
	exit 0
	;;
"add rule"|"insert rule")
	_cmd="$1 $2"
	[ -n "${FAKE_NFT_SLEEP:-}" ] && sleep "$FAKE_NFT_SLEEP"
	if [ -n "${FAKE_NFT_INSERT_FAIL_ON:-}" ]; then
		case "$*" in
		*"$FAKE_NFT_INSERT_FAIL_ON"*) exit 1 ;;
		esac
	fi
	_file=$(chain_file "$4" "$5") || exit 1
	[ "${FAKE_NFT_INSERT_RC:-0}" = 0 ] || exit 1
	printf '%s\n' "$*" >> "${FAKE_INSERT_LOG:?}"
	if [ -n "${FAKE_RECYCLE_ON_INSERT:-}" ] && [ -f "$_file" ]; then
		# Simulate another writer taking over the first DNS handle.
		# Another writer adds its own rule with a fresh handle mid-flight.
		_next2=$(awk '/# handle [0-9]+/ {if ($NF > n) n=$NF} END {print n+1}' "$_file")
		printf '%s\n' "meta nfproto ipv4 udp dport 53 meta mark set 0x00000063 accept comment \"someone-else\" # handle $_next2" >> "$_file"
		mv "$_file.new" "$_file"
	fi
	printf 'nft %s\n' "$*" >> "${FAKE_MUTATION_LOG:?}"
	# drop argv through the chain name; what remains is [position H] RULE
	shift 5
	_pos=""
	if [ "${1:-}" = position ]; then
		_pos=$2
		shift 2
	fi
	line=$(printf '%s' "$*" | sed 's/\( \|^\)iifname \([^ ]*\)/\1iifname "\2"/; s/ comment \([^ ]*\)$/ comment "\1"/')
	_next=$(awk '/# handle [0-9]+/ {if ($NF > n) n=$NF} END {print n+1}' "$_file")
	if [ "$_cmd" = "insert rule" ] && [ -n "$_pos" ]; then
		ln=$(grep -n "# handle ${_pos}\$" "$_file" | head -1 | cut -d: -f1)
		# Real nft refuses an insert at a handle that is not there; the fake
		# used to prepend instead, which hid a rebuild anchored on a rule it
		# had just deleted.
		[ -n "$ln" ] || exit 1
		if [ -n "$ln" ]; then
			head -n "$((ln - 1))" "$_file" > "$_file.new"
			printf '%s # handle %s\n' "$line" "$_next" >> "$_file.new"
			tail -n "+$ln" "$_file" >> "$_file.new"
		else
			printf '%s # handle %s\n' "$line" "$_next" > "$_file.new"
			cat "$_file" >> "$_file.new"
		fi
	elif [ "$_cmd" = "insert rule" ]; then
		printf '%s # handle %s\n' "$line" "$_next" > "$_file.new"
		cat "$_file" >> "$_file.new"
	else
		cat "$_file" > "$_file.new"
		printf '%s # handle %s\n' "$line" "$_next" >> "$_file.new"
	fi
	mv "$_file.new" "$_file"
	exit 0
	;;
"delete rule")
	if [ -n "${FAKE_POST_DELETE_FAIL:-}" ]; then
		: > "$FAKE_POST_DELETE_FAIL"; exit 1
	fi
	[ "${FAKE_DELETE_FAIL:-0}" = 0 ] || exit 1
	printf 'nft %s\n' "$*" >> "${FAKE_MUTATION_LOG:?}"
	_file=$(chain_file "$4" "$5") || exit 1
	handle=""
	shift 5
	while [ $# -gt 0 ]; do
		if [ "$1" = handle ]; then
			handle=$2
			break
		fi
		shift
	done
	[ -n "$handle" ] || exit 1
	grep -v "# handle ${handle}$" "$_file" > "$_file.rem"
	mv "$_file.rem" "$_file"
	exit 0
	;;
esac
printf '%s\n' "$*" >> "${FAKE_MUTATION_LOG:?}"
exit 1
EOF

cat >"$BIN/ip" <<'EOF'
#!/bin/sh
case "$*" in
	rule) [ "${FAKE_IP_RULE_READ_FAIL:-${FAKE_IP_READ_FAIL:-0}}" = 0 ] || exit 1 ;;
	'route show '*) [ "${FAKE_IP_ROUTE_READ_FAIL:-${FAKE_IP_READ_FAIL:-0}}" = 0 ] || exit 1 ;;
esac
case " $* " in
	*" rule add "*)
		printf 'ip %s\n' "$*" >> "${FAKE_MUTATION_LOG:?}"
		: > "${FAKE_IPDIR:?}/rule"
		exit 0
		;;
	*" route add "*)
		printf 'ip %s\n' "$*" >> "${FAKE_MUTATION_LOG:?}"
		: > "${FAKE_IPDIR:?}/route"
		exit 0
		;;
	*" rule del "*)
		[ "${FAKE_RULE_DELETE_FAIL:-${FAKE_ROUTE_DELETE_FAIL:-0}}" = 0 ] || exit 1
		printf 'ip %s\n' "$*" >> "${FAKE_MUTATION_LOG:?}"
		rm -f "${FAKE_IPDIR:?}/rule"
		exit 0
		;;
	*" route del "*)
		[ "${FAKE_LOCAL_DELETE_FAIL:-${FAKE_ROUTE_DELETE_FAIL:-0}}" = 0 ] || exit 1
		printf 'ip %s\n' "$*" >> "${FAKE_MUTATION_LOG:?}"
		rm -f "${FAKE_IPDIR:?}/route"
		exit 0
		;;
	*" rule "*)
		[ -f "${FAKE_IPDIR:?}/rule" ] && echo '1000: from all fwmark 0x2 lookup 101'
		exit 0
		;;
	*" route show table all "*)
		[ -f "${FAKE_IPDIR:?}/route" ] && echo 'local default dev lo table 101 scope host'
		exit 0 ;;
	*" route show table 101 "*)
		[ -f "${FAKE_IPDIR:?}/route" ] && echo 'local default dev lo scope host'
		exit 0
		;;
esac
exit 0
EOF

cat >"$BIN/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${FAKE_CURL_LOG:?}"
printf '%s' "${FAKE_HTTP:-204}"
exit "${FAKE_CURL_RC:-0}"
EOF

cat >"$BIN/dnspy" <<'EOF'
#!/bin/sh
cat > /dev/null
exit "${FAKE_DNS_RC:-0}"
EOF

cat >"$BIN/service" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${FAKE_SERVICE_LOG:?}"
[ "$1" = start ] && : > "${FAKE_LISTEN_FLAG:?}"
if [ "$1" = stop ]; then
	[ "${FAKE_SERVICE_STOP_RC:-0}" = 0 ] || exit "$FAKE_SERVICE_STOP_RC"
	rm -f "${FAKE_LISTEN_FLAG:?}"
fi
exit 0
EOF

chmod 755 "$BIN"/*
: >"$TMP/xray.json"
export ZORO_TEST_MODE=1
export ZORO_NFT="$BIN/nft" ZORO_IP="$BIN/ip" ZORO_SS="$BIN/ss"
export ZORO_CURL="$BIN/curl" ZORO_LOGGER="$BIN/logger"
export ZORO_SERVICE="$BIN/service" ZORO_DNSPY="$BIN/dnspy" ZORO_PROBE_URL="https://probe.invalid/generate_204" ZORO_STATE_FILE="$TMP/requested" ZORO_CONFIG="$TMP/xray.json" ZORO_LOCK_FILE="$TMP/lock"
export FAKE_NFT_STATE="$STATE" FAKE_IPDIR="$IPDIR" FAKE_LISTEN_FLAG="$TMP/listening"
export FAKE_SF_PRE_STATE="$TMP/sf_pre.state" FAKE_SF_OUT_STATE="$TMP/sf_out.state" FAKE_KS_OUT_STATE="$TMP/ks_out.state"
export FAKE_MUTATION_LOG="$MUT" FAKE_CURL_LOG="$CURL_LOG" FAKE_SERVICE_LOG="$SERVICE_LOG"
export FAKE_INSERT_LOG="$TMP/insert.log"

hold_lock() { # background: hold the lock until killed
	# Readiness is a marker the holder writes once flock succeeds, so the caller
	# never races a fixed sleep. The recorded pid ends up being the exec'd sleep.
	rm -f "$TMP/lock.ready"
	(
		exec 9>>"$TMP/lock"
		flock 9 || exit 1
		: >"$TMP/lock.ready"
		# Release is by signal, never by a marker, so exec'ing the final command is
		# safe here and makes the recorded pid the sleeping process itself: a command
		# appended after this line would be unreachable, and the reap leaves no
		# grandchild because there is none.
		exec sleep 300
	) >/dev/null 2>&1 &
	_holder_pid=$!
	_i=0
	while [ ! -e "$TMP/lock.ready" ]; do
		_i=$((_i + 1))
		if [ "$_i" -gt 200 ]; then
			bad 'lock holder never became ready'
			return 1
		fi
		sleep 0.05
	done
	return 0
}

# Bounded release of the fixture's lock holder: a SIGTERM it ignores, or a wait on
# a pid that never dies, must not block the run.
release_lock_holder() {
	[ -n "${_holder_pid:-}" ] || return 0
	kill "$_holder_pid" 2>/dev/null || true
	_i=0
	while kill -0 "$_holder_pid" 2>/dev/null; do
		_i=$((_i + 1))
		if [ "$_i" -gt 200 ]; then
			kill -9 "$_holder_pid" 2>/dev/null || true
			bad 'lock holder did not stop'
			break
		fi
		sleep 0.05
	done
	wait "$_holder_pid" 2>/dev/null || true
	rm -f "$TMP/lock.ready"
	_holder_pid=''
	return 0
}

run_exec() {
	FAKE_DNS_RC="${FAKE_DNS_RC:-0}" FAKE_LISTEN="${FAKE_LISTEN:-public}" \
		FAKE_HTTP="${FAKE_HTTP:-204}" FAKE_CURL_RC="${FAKE_CURL_RC:-0}" \
		FAKE_NFT_TABLE_RC="${FAKE_NFT_TABLE_RC:-0}" FAKE_NFT_CHAIN_RC="${FAKE_NFT_CHAIN_RC:-0}" \
		FAKE_NFT_SLEEP="${FAKE_NFT_SLEEP:-}" \
		exec "$SCRIPT" "$@"
}

pass=0
fail=0
ok() {
	printf 'PASS %s\n' "$1"
	pass=$((pass + 1))
}
bad() {
	printf 'FAIL %s\n' "$1"
	fail=$((fail + 1))
}
has() { # literal match: an expected value with a dot must not become a wildcard
	printf '%s\n' "$1" | grep -qxF -- "$2"
}
# The matcher is only literal while it is pinned: an expected value containing a dot
# must not match a different string, so restoring a regex match fails here.
if has 'mode=off' 'mode.off'; then
	bad 'the output matcher treats a dot as a wildcard'
else
	ok 'the output matcher compares expected values literally'
fi

reset_state() {
	rm -f "$TMP/requested"
	: >"$FAKE_SF_PRE_STATE"
	printf '%s\n' \
		'oifname "lo" tcp dport 10800 counter drop comment "watchdog-tproxy-self-dial" # handle 2' \
		'tcp sport @server_ports accept # handle 3' \
		'udp sport @server_ports accept # handle 4' \
		'tcp dport 53 meta mark set 0x00000001 accept # handle 6' \
		'udp dport 53 meta mark set 0x00000001 accept # handle 7' \
		'meta l4proto { tcp, udp } meta mark set 0x00000001 accept # handle 9' \
		>"$FAKE_SF_OUT_STATE"
	printf '%s\n' \
		'ct state invalid drop # handle 1' \
		'oif "lo" accept # handle 2' \
		'meta mark 0x00000001 accept # handle 3' \
		'meta mark 0x000000ff accept # handle 4' \
		>"$FAKE_KS_OUT_STATE"
	printf 'iifname "br-lan" meta nfproto ipv4 meta l4proto tcp tproxy ip to :10800 meta mark set 0x00000001 ct mark set 0x00000100 accept # handle 38\n' >"$STATE"
	rm -f "$IPDIR/rule" "$IPDIR/route"
	: >"$MUT"
	: >"$CURL_LOG"
	: >"$SERVICE_LOG"
	: >"$FAKE_INSERT_LOG"
}

add_zoro() {
	printf 'iifname "br-lan" meta nfproto ipv4 meta l4proto tcp tproxy ip to :7895 meta mark set 0x00000002 ct mark set 0x00000200 accept comment "zoro-exit" # handle 37\n' >"$STATE.new"
	cat "$STATE" >>"$STATE.new"
	mv "$STATE.new" "$STATE"
}

add_dns() {
	printf '%s\n' \
		'meta nfproto ipv4 meta l4proto udp meta mark 0x00000002 tproxy ip to :7895 meta mark set 0x00000002 accept comment "zoro-exit" # handle 31' \
		'meta nfproto ipv4 meta l4proto tcp meta mark 0x00000002 tproxy ip to :7895 meta mark set 0x00000002 accept comment "zoro-exit" # handle 32' \
		>"$FAKE_SF_PRE_STATE"
	printf '%s\n' \
		'meta nfproto ipv4 udp dport 53 meta mark set 0x00000002 accept comment "zoro-exit" # handle 33' \
		'meta nfproto ipv4 tcp dport 53 meta mark set 0x00000002 accept comment "zoro-exit" # handle 34' \
		>"$FAKE_SF_OUT_STATE"
	printf '%s\n' \
		'meta mark 0x00000002 accept comment "zoro-exit" # handle 35' \
		>"$FAKE_KS_OUT_STATE"
}

run() {
	FAKE_DNS_RC="${FAKE_DNS_RC:-0}" \
		FAKE_LISTEN="${FAKE_LISTEN:-public}" FAKE_HTTP="${FAKE_HTTP:-204}" \
		FAKE_CURL_RC="${FAKE_CURL_RC:-0}" FAKE_NFT_TABLE_RC="${FAKE_NFT_TABLE_RC:-0}" \
		FAKE_NFT_SLEEP="${FAKE_NFT_SLEEP:-}" \
		FAKE_NFT_CHAIN_RC="${FAKE_NFT_CHAIN_RC:-0}" \
		"$SCRIPT" "$@"
}

reset_state
out=$(FAKE_LISTEN=none run check)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'mode=off' && has "$out" 'route=missing' &&
	has "$out" 'xray_listening=no' && has "$out" 'probe=skipped' &&
	[ ! -s "$MUT" ] && [ ! -s "$SERVICE_LOG" ]
if [ $? -eq 0 ]; then ok 'off state is measured and read-only'; else bad 'off state is measured and read-only'; fi

reset_state
add_zoro
add_dns
: >"$IPDIR/rule"
: >"$IPDIR/route"
out=$(run check)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'mode=on' && has "$out" 'route=ok' &&
	has "$out" 'xray_listening=yes' && has "$out" 'order=ok' &&
	has "$out" 'probe=ok' && [ ! -s "$MUT" ] && [ ! -s "$SERVICE_LOG" ] &&
	grep -q -- '--socks5-hostname 127.0.0.1:7890' "$CURL_LOG"
if [ $? -eq 0 ]; then ok 'healthy on path is measured and read-only'; else bad 'healthy on path is measured and read-only'; fi

reset_state
out=$(FAKE_HTTP=000 FAKE_CURL_RC=7 run on 2>&1)
rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'comment "zoro-exit"' "$STATE" && [ ! -f "$IPDIR/route" ] && [ ! -e "$TMP/requested" ]
if [ $? -eq 0 ]; then ok 'on preflight failure changes nothing'; else bad 'on preflight failure changes nothing'; fi

reset_state
add_zoro
: >"$IPDIR/rule"
: >"$IPDIR/route"
out=$(FAKE_HTTP=000 FAKE_CURL_RC=7 run check)
rc=$?
[ "$rc" -eq 1 ] && has "$out" 'probe=fail'
if [ $? -eq 0 ]; then ok 'probe failure exits 1'; else bad 'probe failure exits 1'; fi

reset_state
add_zoro
: >"$IPDIR/rule"
out=$(run check)
rc=$?
[ "$rc" -eq 1 ] && has "$out" 'route=missing'
if [ $? -eq 0 ]; then ok 'missing table-101 route exits 1'; else bad 'missing table-101 route exits 1'; fi

reset_state
add_zoro
: >"$IPDIR/rule"
: >"$IPDIR/route"
out=$(FAKE_LISTEN=none run check)
rc=$?
[ "$rc" -eq 1 ] && has "$out" 'xray_listening=no'
if [ $? -eq 0 ]; then ok 'listener down exits 1'; else bad 'listener down exits 1'; fi

reset_state
add_zoro
: >"$IPDIR/rule"
: >"$IPDIR/route"
out=$(FAKE_LISTEN=loopback run check)
rc=$?
[ "$rc" -eq 1 ] && has "$out" 'xray_listening=no'
if [ $? -eq 0 ]; then ok 'loopback-only listener is rejected'; else bad 'loopback-only listener is rejected'; fi

reset_state
printf 'iifname "br-lan" meta nfproto ipv4 meta l4proto tcp tproxy ip to :7895 meta mark set 0x00000002 ct mark set 0x00000200 accept comment "zoro-exit" # handle 39\n' >"$STATE"
printf 'iifname "br-lan" ip daddr @bypass_devices return # handle 15\n' >>"$STATE"
printf 'iifname "br-lan" meta nfproto ipv4 meta l4proto tcp tproxy ip to :10800 meta mark set 0x00000001 ct mark set 0x00000100 accept # handle 38\n' >>"$STATE"
: >"$IPDIR/rule"
: >"$IPDIR/route"
out=$(run check)
rc=$?
[ "$rc" -eq 1 ] && has "$out" 'order=misplaced'
if [ $? -eq 0 ]; then ok 'rule above bypass returns is misplaced'; else bad 'rule above bypass returns is misplaced'; fi

reset_state
# Real misplaced shape: zoro, bypass return, then :10800 (adjacency broken).
printf 'iifname "br-lan" meta nfproto ipv4 meta l4proto tcp tproxy ip to :7895 meta mark set 0x00000002 ct mark set 0x00000200 accept comment "zoro-exit" # handle 37\n' >"$STATE"
printf 'iifname "br-lan" ip daddr @bypass_devices return # handle 15\n' >>"$STATE"
printf 'iifname "br-lan" meta nfproto ipv4 meta l4proto tcp tproxy ip to :10800 meta mark set 0x00000001 ct mark set 0x00000100 accept # handle 38\n' >>"$STATE"
out=$(run on 2>&1)
rc=$?
_z=$(grep -n 'comment "zoro-exit"' "$STATE" | cut -d: -f1)
_s=$(grep -n 'tproxy ip to :10800' "$STATE" | cut -d: -f1)
if [ "$rc" -eq 0 ] && [ -n "$_z" ] && [ "$_z" -eq "$((_s - 1))" ]; then
	ok 'on repairs a misplaced rule'
else
	bad 'on repairs a misplaced rule'
fi

reset_state
: >"$IPDIR/rule"
: >"$IPDIR/route"
printf 'on\n' >"$TMP/requested"
out=$(run status)
rc=$?
[ "$rc" -eq 1 ] && has "$out" 'mode=lost'
if [ $? -eq 0 ]; then ok 'status exits 1 for mode=lost'; else bad 'status exits 1 for mode=lost'; fi

reset_state
printf 'on\n' >"$TMP/requested"
# The table is missing while the request says on. The CLI owns this distinction
# and the daemon keys its repair path on the status it returns, so the exit code
# is the contract here, not only the words.
out=$(FAKE_ABSENT_SF_OUTPUT=1 run status 2>&1)
rc=$?
if [ "$rc" -eq 4 ] && has "$out" 'mode=lost' && has "$out" 'nft=missing' &&
	has "$out" 'reason=no-table'; then
	ok 'status exits 4 when the table is absent while the request says on'
else
	bad "status did not report the absent table as its own verdict [rc=$rc] $out"
fi

reset_state
out=$(FAKE_NFT_TABLE_RC=1 run check)
rc=$?
[ "$rc" -eq 3 ] && has "$out" 'mode=unknown' && has "$out" 'xray_listening=yes' &&
	[ ! -s "$MUT" ] && [ ! -s "$SERVICE_LOG" ]
if [ $? -eq 0 ]; then ok 'unreadable table is unknown'; else bad 'unreadable table is unknown'; fi

reset_state
printf 'on\n' >"$TMP/requested"
out=$(run check)
rc=$?
[ "$rc" -eq 1 ] && has "$out" 'mode=lost'
if [ $? -eq 0 ]; then ok 'requested on but rule gone is mode=lost'; else bad 'requested on but rule gone is mode=lost'; fi

reset_state
: >"$TMP/requested"
out=$(run status)
rc=$?
[ "$rc" -eq 3 ] && has "$out" 'mode=unknown'
if [ $? -eq 0 ]; then ok 'status exits 3 for an unreadable requested state'; else bad 'status exits 3 for an unreadable requested state'; fi

reset_state
sed -i '/:10800/d' "$STATE"
out=$(run on --force 2>&1)
rc=$?
grep -q 'comment "zoro-exit"' "$STATE" && [ "$rc" -eq 0 ] && ! head -1 "$FAKE_INSERT_LOG" | grep -q 'position'
if [ $? -eq 0 ]; then ok 'on --force works without a Surflare fallback'; else bad 'on --force works without a Surflare fallback'; fi

reset_state
add_zoro
sed -i 's/0x00000002/0x00000009/' "$STATE"
: >"$IPDIR/rule"
: >"$IPDIR/route"
out=$(run on 2>&1)
rc=$?
grep -q 'meta mark set 0x00000002' "$STATE" && [ "$rc" -eq 0 ] && [ "$(grep -c 'comment "zoro-exit"' "$STATE")" -eq 1 ]
if [ $? -eq 0 ]; then ok 'on replaces a stale rule with the correct mark'; else bad 'on replaces a stale rule with the correct mark'; fi

reset_state
add_zoro
: >"$IPDIR/rule"
: >"$IPDIR/route"
out=$(FAKE_NFT_TABLE_RC=1 run off --force 2>&1)
rc=$?
[ "$rc" -ne 0 ] && [ -f "$IPDIR/route" ] && ! grep -q '^stop$' "$SERVICE_LOG"
if [ $? -eq 0 ]; then ok 'off refuses while nft is unreadable'; else bad 'off refuses while nft is unreadable'; fi

reset_state
printf 'iifname "br-lan" meta nfproto ipv4 meta l4proto tcp reject with tcp reset # handle 38\n' >"$STATE"
: >"$IPDIR/rule"
: >"$IPDIR/route"
out=$(run on --force 2>&1)
rc=$?
_z=$(grep -n 'comment "zoro-exit"' "$STATE" | cut -d: -f1)
_t=$(grep -n 'l4proto tcp reject' "$STATE" | cut -d: -f1)
if [ "$rc" -eq 0 ] && [ -n "$_z" ] && [ -n "$_t" ] && [ "$_z" -lt "$_t" ]; then
	ok 'on --force inserts above the Surflare tombstone reject'
else
	bad 'on --force inserts above the Surflare tombstone reject'
fi

reset_state
printf 'iifname "br-lan" meta nfproto ipv4 meta l4proto tcp reject with tcp reset # handle 38\n' >"$STATE"
printf 'iifname "br-lan" meta nfproto ipv4 meta l4proto tcp tproxy ip to :7895 meta mark set 0x00000002 ct mark set 0x00000200 accept comment "zoro-exit" # handle 39\n' >>"$STATE"
: >"$IPDIR/rule"
: >"$IPDIR/route"
out=$(run check)
rc=$?
[ "$rc" -eq 1 ] && has "$out" 'order=misplaced'
if [ $? -eq 0 ]; then ok 'rule behind a tombstone is misplaced'; else bad 'rule behind a tombstone is misplaced'; fi

reset_state
: >"$IPDIR/rule"
: >"$IPDIR/route"
out=$(FAKE_LISTEN=none run check)
rc=$?
[ "$rc" -eq 1 ] && has "$out" 'mode=off' && has "$out" 'route=ok' &&
	has "$out" 'dns=residue'
if [ $? -eq 0 ]; then ok 'off rejects a leftover policy route'; else bad 'off certified a leftover policy route'; fi

reset_state
add_zoro
: >"$IPDIR/rule"
: >"$IPDIR/route"
out=$(run status)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'mode=on' && has "$out" 'route=ok' &&
	has "$out" 'surflare_10800=yes'
if [ $? -eq 0 ]; then ok 'status reports on-state keys'; else bad 'status reports on-state keys'; fi

reset_state
add_zoro
sed -i '/:10800/d' "$STATE"
: >"$IPDIR/rule"
: >"$IPDIR/route"
out=$(run off --force 2>&1)
rc=$?
! grep -q 'comment "zoro-exit"' "$STATE" && [ "$rc" -eq 0 ]
if [ $? -eq 0 ]; then ok 'off --force works when Surflare is tombstoned'; else bad 'off --force works when Surflare is tombstoned'; fi

reset_state
add_zoro
: >"$IPDIR/rule"
: >"$IPDIR/route"
sed -i '/:10800/d' "$STATE"
out=$(run off 2>&1)
rc=$?
[ "$rc" -ne 0 ] && grep -q 'comment "zoro-exit"' "$STATE" && [ ! -s "$MUT" ]
if [ $? -eq 0 ]; then ok 'off refuses without --force when fallback is missing'; else bad 'off refuses without --force when fallback is missing'; fi

reset_state
add_zoro
add_dns
: >"$IPDIR/rule"
: >"$IPDIR/route"
sed -i '/:10800/d' "$STATE"
out=$(run check)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'fallback=missing' && has "$out" 'order=unverified' && has "$out" 'probe=ok' && [ ! -s "$MUT" ]
if [ $? -eq 0 ]; then ok 'check does not false-fail when fallback is tombstoned'; else bad 'check does not false-fail when fallback is tombstoned'; fi

reset_state
: >"$IPDIR/rule"
: >"$IPDIR/route"
sed -i '/:10800/d' "$STATE"
out=$(run on 2>&1)
rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'comment "zoro-exit"' "$STATE" && [ ! -s "$MUT" ]
if [ $? -eq 0 ]; then ok 'on refuses when Surflare fallback is missing'; else bad 'on refuses when Surflare fallback is missing'; fi

reset_state
rm -f "$FAKE_LISTEN_FLAG"
out=$(FAKE_LISTEN=auto run on 2>&1)
rc=$?
grep -q '^start$' "$SERVICE_LOG" && grep -q 'comment "zoro-exit"' "$STATE" && [ "$rc" -eq 0 ]
if [ $? -eq 0 ]; then ok 'on starts the xray service when needed'; else bad 'on starts the xray service when needed'; fi

reset_state
out=$(run on 2>&1)
rc=$?
grep -q 'comment "zoro-exit"' "$STATE" && [ -f "$IPDIR/rule" ] && [ -f "$IPDIR/route" ] && [ "$rc" -eq 0 ] && [ "$(cat "$TMP/requested" 2>/dev/null)" = on ] && grep -q 'position 38' "$FAKE_INSERT_LOG" && grep -q 'meta nfproto ipv4' "$FAKE_INSERT_LOG" && grep -q 'tproxy ip to :7895' "$FAKE_INSERT_LOG" && grep -q 'comment zoro-exit' "$FAKE_INSERT_LOG"
if [ $? -eq 0 ]; then ok 'on installs rule and route'; else bad 'on installs rule and route'; fi

out=$(run on 2>&1)
rc=$?
idem=1
if [ "$(grep -c 'comment "zoro-exit"' "$STATE")" -eq 1 ] && [ "$rc" -eq 0 ] && [ "$(wc -l <"$FAKE_INSERT_LOG")" -eq 6 ]; then
	idem=0
fi
if [ "$idem" -eq 0 ]; then ok 'on is idempotent'; else bad 'on is idempotent'; fi

out=$(run off 2>&1)
rc=$?
! grep -q 'comment "zoro-exit"' "$STATE" && [ ! -f "$IPDIR/rule" ] && [ ! -f "$IPDIR/route" ] && [ "$rc" -eq 0 ] && grep -q '^stop$' "$SERVICE_LOG" && [ "$(cat "$TMP/requested" 2>/dev/null)" = off ]
if [ $? -eq 0 ]; then ok 'off removes rule and route and stops xray'; else bad 'off removes rule and route and stops xray'; fi

reset_state
out=$(FAKE_NFT_CHAIN_RC=1 run check)
rc=$?
[ "$rc" -eq 3 ] && has "$out" 'mode=unknown'
if [ $? -eq 0 ]; then ok 'unreadable chain is unknown'; else bad 'unreadable chain is unknown'; fi

reset_state
add_zoro
add_dns
: >"$IPDIR/rule"
: >"$IPDIR/route"
out=$(FAKE_HTTP=200 run check)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'probe=ok'
if [ $? -eq 0 ]; then ok 'probe accepts HTTP 200'; else bad 'probe accepts HTTP 200'; fi

reset_state
out=$(run status)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'mode=off' && [ ! -s "$MUT" ] && [ ! -s "$SERVICE_LOG" ]
if [ $? -eq 0 ]; then ok 'status is read-only'; else bad 'status is read-only'; fi

reset_state
run check --alert >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then ok 'unknown check argument is usage error'; else bad 'unknown check argument is usage error'; fi
run bogus >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then ok 'unknown subcommand is usage error'; else bad 'unknown subcommand is usage error'; fi

reset_state
FAKE_IPDIR="$TMP/nonexistent" run on >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'comment "zoro-exit"' "$STATE"
if [ $? -eq 0 ]; then ok 'on fails closed when route cannot install'; else bad 'on fails closed when route cannot install'; fi

reset_state
out=$(FAKE_NFT_INSERT_FAIL_ON='dport 53' run on 2>&1)
rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'comment "zoro-exit"' "$STATE" && [ ! -f "$IPDIR/route" ]
if [ $? -eq 0 ]; then ok 'on rolls back when nft insert fails'; else bad 'on rolls back when nft insert fails'; fi

reset_state
mkdir -p "$TMP/state-dir"
out=$(ZORO_STATE_FILE="$TMP/state-dir" run on 2>&1)
rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'comment "zoro-exit"' "$STATE" && [ ! -f "$IPDIR/route" ]
if [ $? -eq 0 ]; then ok 'on rolls back when requested state cannot be recorded'; else bad 'on rolls back when requested state cannot be recorded'; fi

reset_state
add_zoro
: >"$IPDIR/rule"
: >"$IPDIR/route"
out=$(ZORO_STATE_FILE="$TMP/state-dir" run on 2>&1)
rc=$?
[ "$rc" -ne 0 ] && grep -q 'comment "zoro-exit"' "$STATE" && [ -f "$IPDIR/route" ]
if [ $? -eq 0 ]; then ok 'on keeps a pre-existing healthy rule when state write fails'; else bad 'on keeps a pre-existing healthy rule when state write fails'; fi

reset_state
add_zoro
sed -i 's/7895/9999/' "$STATE"
: >"$IPDIR/rule"
: >"$IPDIR/route"
out=$(run check)
rc=$?
[ "$rc" -eq 1 ] && has "$out" 'order=misplaced'
if [ $? -eq 0 ]; then ok 'rule with the wrong port exits 1'; else bad 'rule with the wrong port exits 1'; fi

# --- DNS exit consistency ---
# When the switch is on, the router's own upstream DNS must leave through
# Zoro like the data path: tproxy catch in surflare prerouting, dport-53
# mark rules ahead of the mark-0x1 rules in surflare output, and a
# killswitch accept for mark 0x2 (which the ks accept set lacked).

reset_state
run on >/dev/null 2>&1
[ "$?" -eq 0 ] &&
	grep -q 'meta l4proto udp meta mark 0x00000002' "$FAKE_SF_PRE_STATE" &&
	grep -q 'tproxy ip to :7895' "$FAKE_SF_PRE_STATE" &&
	ok "on installs the udp tproxy catch" ||
	bad "on missed the udp tproxy catch"

grep -q 'meta l4proto tcp meta mark 0x00000002' "$FAKE_SF_PRE_STATE" &&
	ok "on installs the tcp tproxy catch" ||
	bad "on missed the tcp tproxy catch"

grep -q 'meta nfproto ipv4 udp dport 53 meta mark set 0x00000002' "$FAKE_SF_OUT_STATE" &&
	ok "the output rules are IPv4-qualified" ||
	bad "the output rules lost their family qualifier"

_sport_ln=$(grep -n 'udp sport @server_ports accept' "$FAKE_SF_OUT_STATE" | head -1 | cut -d: -f1)
_first_zoro_ln=$(grep -n 'zoro-exit' "$FAKE_SF_OUT_STATE" | head -1 | cut -d: -f1)
[ -n "$_sport_ln" ] && [ "$_sport_ln" -lt "$_first_zoro_ln" ] &&
	ok "the output rules stay behind the server-port accepts" ||
	bad "the output rules jumped ahead of the server-port accepts"

_dns_ln=$(grep -n 'dport 53 meta mark set 0x00000002' "$FAKE_SF_OUT_STATE" | head -1 | cut -d: -f1)
_sf_ln=$(grep -n 'dport 53 meta mark set 0x00000001' "$FAKE_SF_OUT_STATE" | head -1 | cut -d: -f1)
[ -n "$_dns_ln" ] && [ -n "$_sf_ln" ] && [ "$_dns_ln" -lt "$_sf_ln" ] &&
	ok "the zoro DNS mark rules precede the surflare ones" ||
	bad "the zoro DNS mark rules landed after the surflare ones [$_dns_ln vs $_sf_ln]"

grep -q 'meta mark 0x00000002 accept' "$FAKE_KS_OUT_STATE" &&
	! grep -q 'meta mark set 0x00000002 accept' "$FAKE_KS_OUT_STATE" &&
	[ "$(head -1 "$FAKE_KS_OUT_STATE")" = 'ct state invalid drop # handle 1' ] &&
	ok "on installs the killswitch mark accept (match form)" ||
	bad "on missed the killswitch mark accept or used the set form or displaced the first verdict"

out=$(run status)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'mode=on' && has "$out" 'dns=ok' &&
	ok "status reports the DNS exit healthy" ||
	bad "status missed the DNS state"

out=$(run check)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'dns=ok' &&
	ok "check reports the DNS exit healthy" ||
	bad "check missed the DNS state"

# A half-installed DNS group must be repaired, not treated as done: if only
# the udp catch survived, "on" has to add the tcp catch back instead of
# failing and leaving the switch unusable until someone runs "off" first.
reset_state
add_zoro
add_dns
grep -v 'meta l4proto tcp meta mark 0x00000002' "$FAKE_SF_PRE_STATE" >"$FAKE_SF_PRE_STATE.new"
mv "$FAKE_SF_PRE_STATE.new" "$FAKE_SF_PRE_STATE"
printf 'on\n' >"$TMP/requested"
run on >/dev/null 2>&1
_rc=$?
[ "$_rc" -eq 0 ] &&
	grep -q 'meta l4proto tcp meta mark 0x00000002' "$FAKE_SF_PRE_STATE" &&
	ok "on repairs a half-installed DNS group" ||
	bad "on cannot repair a half-installed DNS group, rc=$_rc [$(grep -c zoro-exit "$FAKE_SF_PRE_STATE") rules]"

run off >/dev/null 2>&1
[ "$?" -eq 0 ] &&
	! grep -q 'zoro-exit' "$FAKE_SF_PRE_STATE" &&
	! grep -q 'zoro-exit' "$FAKE_SF_OUT_STATE" &&
	! grep -q 'zoro-exit' "$FAKE_KS_OUT_STATE" &&
	! grep -q 'zoro-exit' "$STATE" &&
	ok "off removes the DNS rules with the rest" ||
	bad "off left zoro rules behind"

reset_state
: >"$FAKE_KS_OUT_STATE"
out=$(run on 2>&1)
rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'DNS exit rules' &&
	ok "a missing killswitch anchor refuses the switch" ||
	bad "a missing anchor did not stop the switch rc=$rc"

# No competing dport-53 rule means nothing to insert in front of: the pair is
# appended.  What must still refuse is a chain that cannot be extended at all.
reset_state
: >"$FAKE_SF_OUT_STATE"
out=$(run on 2>&1)
rc=$?
[ "$rc" -eq 0 ] && grep -q 'udp dport 53' "$FAKE_SF_OUT_STATE" &&
	ok "an empty output chain gets the pair appended" ||
	bad "an empty output chain was not handled rc=$rc"

reset_state
out=$(FAKE_NFT_INSERT_FAIL_ON='dport 53' run on 2>&1)
rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'DNS exit rules' &&
	ok "a refused insert refuses the switch" ||
	bad "a refused insert did not stop the switch rc=$rc"

reset_state
run on >/dev/null 2>&1
sed -i 's/tproxy ip to :7895/tproxy ip to :9999/' "$FAKE_SF_PRE_STATE"
out=$(run status 2>&1)
has "$out" 'dns=missing' &&
	ok "status sees a tampered tproxy port" ||
	bad "status missed a tampered tproxy port"

reset_state

# --- the check exit code sees a vanished DNS exit ---
reset_state
run on >/dev/null 2>&1
sed -i '/zoro-exit/d' "$FAKE_KS_OUT_STATE"
out=$(FAKE_DNS_RC=0 run check)
rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'dns=missing' &&
	ok "check fails when the DNS exit vanishes" ||
	bad "check stayed green without the DNS exit"

# --- the UDP DNS probe gates check ---
reset_state
run on >/dev/null 2>&1
out=$(FAKE_DNS_RC=1 run check)
rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'probe=fail' &&
	ok "a dead DNS path fails the check" ||
	bad "check ignored the DNS probe"

# --- a refused switch leaves no DNS residue ---
reset_state
: >"$FAKE_KS_OUT_STATE"
run on >/dev/null 2>&1
! grep -q 'zoro-exit' "$FAKE_SF_PRE_STATE" &&
	! grep -q 'zoro-exit' "$FAKE_SF_OUT_STATE" &&
	! grep -q 'zoro-exit' "$FAKE_KS_OUT_STATE" &&
	ok "a refused switch leaves no DNS residue" ||
	bad "a refused switch left DNS residue behind"

reset_state
FAKE_NFT_INSERT_FAIL_ON='dport 53' run on >/dev/null 2>&1
! grep -q 'zoro-exit' "$FAKE_SF_PRE_STATE" &&
	! grep -q 'zoro-exit' "$FAKE_SF_OUT_STATE" &&
	ok "a refused DNS insert leaves no residue anywhere" ||
	bad "a refused DNS insert left residue behind"

# A DNS group can be complete and still wrong: if a Surflare mark-0x1 rule
# sits ahead of the Zoro ones, the router's DNS leaves through Surflare while
# the data path stays on Zoro.  Existence alone must not read as healthy.
reset_state
add_zoro
add_dns
printf '%s\n' \
	'udp dport 53 meta mark set 0x00000001 accept # handle 41' \
	'meta nfproto ipv4 udp dport 53 meta mark set 0x00000002 accept comment "zoro-exit" # handle 33' \
	'meta nfproto ipv4 tcp dport 53 meta mark set 0x00000002 accept comment "zoro-exit" # handle 34' \
	'tcp dport 53 meta mark set 0x00000001 accept # handle 42' \
	>"$FAKE_SF_OUT_STATE"
out=$(run check)
rc=$?
[ "$rc" -eq 1 ] && has "$out" 'dns=misplaced' &&
	ok "check calls out a shadowed DNS mark rule" ||
	bad "check missed the shadowed DNS mark rule [rc=$rc $(printf '%s' "$out" | tr '\n' ' ')]"

out=$(run status)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'dns=misplaced' &&
	ok "status reports the shadowed DNS mark rule" ||
	bad "status missed the shadowed DNS mark rule [rc=$rc]"

# "on" must repair what "check" calls broken, otherwise the tool reports success
# in the very state its own check fails on.
reset_state
add_zoro
add_dns
printf '%s\n' \
	'udp dport 53 meta mark set 0x00000001 accept # handle 41' \
	'meta nfproto ipv4 udp dport 53 meta mark set 0x00000002 accept comment "zoro-exit" # handle 33' \
	'meta nfproto ipv4 tcp dport 53 meta mark set 0x00000002 accept comment "zoro-exit" # handle 34' \
	>"$FAKE_SF_OUT_STATE"
run on >/dev/null 2>&1
out=$(run check)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'dns=ok' &&
	ok "on repairs a shadowed DNS pair" ||
	bad "on left a shadowed DNS pair behind [rc=$rc]"

# A rule for dport 5353 is not a rule for dport 53.
reset_state
add_zoro
add_dns
printf '%s\n' \
	'meta nfproto ipv4 udp dport 5353 meta mark set 0x00000002 accept comment "zoro-exit" # handle 51' \
	'meta nfproto ipv4 tcp dport 53 meta mark set 0x00000002 accept comment "zoro-exit" # handle 34' \
	>"$FAKE_SF_OUT_STATE"
out=$(run check)
rc=$?
[ "$rc" -eq 1 ] && has "$out" 'dns=missing' &&
	ok "a dport-5353 decoy does not satisfy the udp rule" ||
	bad "a dport-5353 decoy passed as the udp rule [rc=$rc]"

# Competing rules carry counters; matching by literal adjacency missed them.
reset_state
add_zoro
add_dns
printf '%s\n' \
	'udp dport 53 counter packets 91 bytes 8190 meta mark set 0x00000001 accept # handle 41' \
	'meta nfproto ipv4 udp dport 53 meta mark set 0x00000002 accept comment "zoro-exit" # handle 33' \
	'meta nfproto ipv4 tcp dport 53 meta mark set 0x00000002 accept comment "zoro-exit" # handle 34' \
	>"$FAKE_SF_OUT_STATE"
out=$(run check)
rc=$?
[ "$rc" -eq 1 ] && has "$out" 'dns=misplaced' &&
	ok "a counter-bearing shadow is reported" ||
	bad "a counter-bearing shadow read as healthy [rc=$rc]"

# Only one protocol of the pair shadowed: the first-match comparison missed it.
reset_state
add_zoro
add_dns
printf '%s\n' \
	'meta nfproto ipv4 udp dport 53 meta mark set 0x00000002 accept comment "zoro-exit" # handle 33' \
	'tcp dport 53 meta mark set 0x00000001 accept # handle 42' \
	'meta nfproto ipv4 tcp dport 53 meta mark set 0x00000002 accept comment "zoro-exit" # handle 34' \
	>"$FAKE_SF_OUT_STATE"
out=$(run check)
rc=$?
[ "$rc" -eq 1 ] && has "$out" 'dns=misplaced' &&
	ok "a half-shadowed pair is reported" ||
	bad "a half-shadowed pair read as healthy [rc=$rc]"

# Contention has its own exit code so the daemon can defer instead of paging.
reset_state
hold_lock
run on >/dev/null 2>&1
rc=$?
release_lock_holder
[ "$rc" -eq 4 ] && ok "contention exits with the busy code" ||
	bad "contention reused a failure exit code [$rc]"

# The same refusal has to cover "off": that is the command an operator runs to
# get LAN traffic back on Surflare.
reset_state
add_zoro
add_dns
printf 'on\n' >"$TMP/requested"
hold_lock
run off >/dev/null 2>&1
rc=$?
release_lock_holder
if [ "$rc" -eq 4 ] && grep -q 'zoro-exit' "$STATE"; then
	ok "off refuses while another writer holds the lock"
else
	bad "off ran despite a held lock [rc=$rc]"
fi

# The kernel drops the lock with the process, so a killed holder cannot wedge
# the next run -- no pid to recycle and no timestamp we grew old.
reset_state
hold_lock
kill -9 "$_holder_pid" 2>/dev/null
wait "$_holder_pid" 2>/dev/null
rm -f "$TMP/lock.ready"
_holder_pid=''
run on >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "a killed holder does not wedge the next run" ||
	bad "a killed holder wedged the next run [rc=$rc]"

# A lock path that cannot be opened is an environment failure, not contention.
reset_state
# Call the script directly: the point is what it reports before it touches nft.
ZORO_LOCK_FILE="$TMP/no-such/lock" "$SCRIPT" on >/dev/null 2>"$TMP/lockerr.txt"
rc=$?
out=$(cat "$TMP/lockerr.txt")
case "$out" in
*"cannot open the lock file"*) [ "$rc" -eq 1 ] &&
	ok "an unopenable lock file is reported honestly" ||
	bad "an unopenable lock file was treated as contention [$rc]" ;;
*) bad "an unopenable lock file produced the wrong diagnosis [rc=$rc out=$out]" ;;
esac

# A dport-5353 rule next to the pair is neither a competitor nor a substitute.
reset_state
add_zoro
add_dns
printf '%s\n' \
	'udp dport 5353 meta mark set 0x00000001 accept # handle 61' \
	'meta nfproto ipv4 udp dport 53 meta mark set 0x00000002 accept comment "zoro-exit" # handle 33' \
	'meta nfproto ipv4 tcp dport 53 meta mark set 0x00000002 accept comment "zoro-exit" # handle 34' \
	>"$FAKE_SF_OUT_STATE"
out=$(run check)
rc=$?
# The route fixture is not seeded here, so the exit code is not the signal --
# the DNS verdict is.
has "$out" 'dns=ok' &&
	ok "a dport-5353 neighbour is not a competitor" ||
	bad "a dport-5353 neighbour was read as a competitor [rc=$rc]"

# ... and it must not be chosen as the insert anchor either: with no competing
# dport-53 rule the pair is appended, leaving the 5353 rule in front.
reset_state
add_zoro
printf '%s\n' \
	'udp dport 5353 meta mark set 0x00000001 accept # handle 61' \
	>"$FAKE_SF_OUT_STATE"
run on >/dev/null 2>&1
_first=$(head -1 "$FAKE_SF_OUT_STATE")
case "$_first" in
*5353*) ok "the anchor ignores dport-5353 rules" ;;
*) bad "the pair was inserted in front of a dport-5353 rule [$_first]" ;;
esac
# The pair is incomplete and our surviving rule is the earliest dport-53 rule:
# the rebuild deletes it and must not anchor on it.  Anchoring first leaves nft
# with a dead handle and the rollback takes the whole switch down.
reset_state
add_zoro
printf '%s\n' \
	'meta nfproto ipv4 udp dport 53 meta mark set 0x00000002 accept comment "zoro-exit" # handle 33' \
	'udp dport 53 meta mark set 0x00000001 accept # handle 41' \
	>"$FAKE_SF_OUT_STATE"
out=$(run on 2>&1)
rc=$?
out2=$(run check)
_ours=$(grep -c 'comment "zoro-exit"' "$FAKE_SF_OUT_STATE")
[ "$rc" -eq 0 ] && has "$out2" 'dns=ok' && [ "$_ours" -eq 2 ] &&
	ok "a half pair ahead of its competitor is rebuilt in place" ||
	bad "rebuilding the half pair failed [rc=$rc ours=$_ours]"
# A mark on the rule itself is required: a bare port rule is not our rule.
reset_state
add_zoro
printf '%s\n' \
	'meta nfproto ipv4 udp dport 53 accept comment "zoro-exit" # handle 71' \
	'meta nfproto ipv4 tcp dport 53 meta mark set 0x00000002 accept comment "zoro-exit" # handle 34' \
	'meta nfproto ipv4 meta l4proto udp meta mark 0x00000002 tproxy ip to :7895 meta mark set 0x00000002 accept comment "zoro-exit" # handle 24' \
	>"$FAKE_SF_PRE_STATE"
out=$(run check)
rc=$?
[ "$rc" -eq 1 ] && has "$out" 'dns=missing' &&
	ok "a comment without the mark is not the rule" ||
	bad "a markless rule satisfied the check [rc=$rc]"

# A lost data rule still reports the DNS dimension, and a deliberate off that
# left our rules behind is not healthy.
reset_state
add_dns
printf 'on\n' >"$TMP/requested"
out=$(run check)
rc=$?
[ "$rc" -eq 1 ] && has "$out" 'mode=lost' && has "$out" 'dns=ok' &&
	ok "check reports the DNS state when the data rule is lost" ||
	bad "check hid the DNS state in mode=lost [rc=$rc]"

reset_state
add_dns
printf 'off\n' >"$TMP/requested"
out=$(run check)
rc=$?
[ "$rc" -eq 1 ] && has "$out" 'dns=residue' &&
	ok "check calls outoff residue dns rules" ||
	bad "check called leftover dns rules healthy [rc=$rc]"

reset_state

# The chain the router really has: mark-0x1 dport-53 rules plus a catch-all at
# the tail.  The pair has to land in front of the first rule that can take the
# traffic, not merely somewhere in the chain.
reset_state
: >"$IPDIR/rule"
out=$(run on 2>&1)
rc=$?
_ours=$(grep -c 'udp dport 53 meta mark set 0x00000002 accept comment "zoro-exit"' "$FAKE_SF_OUT_STATE")
_udp=$(grep -n 'udp dport 53 meta mark set 0x00000002 accept comment "zoro-exit"' "$FAKE_SF_OUT_STATE" | cut -d: -f1)
_first=$(grep -n 'dport 53 meta mark set 0x00000001' "$FAKE_SF_OUT_STATE" | head -1 | cut -d: -f1)
[ "$rc" -eq 0 ] && [ "$_ours" -eq 1 ] && [ -n "$_udp" ] && [ "$_udp" -lt "$_first" ] &&
	ok "the pair lands in front of the mark-0x1 DNS rules" ||
	bad "the pair did not reach the front [rc=$rc ours=$_ours udp=${_udp:-none} first=${_first:-none}]"
out=$(run check)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'dns=ok' &&
	ok "check agrees with that placement" ||
	bad "check disagreed right after on [rc=$rc]"

# Nothing matches port 53 but the tail accepts every tcp/udp packet: appending
# behind it would leave the pair dead while every presence check still passes.
reset_state
printf '%s\n' \
	'tcp sport @server_ports accept # handle 3' \
	'udp sport @server_ports accept # handle 4' \
	'meta l4proto { tcp, udp } meta mark set 0x00000001 accept # handle 9' \
	>"$FAKE_SF_OUT_STATE"
: >"$IPDIR/rule"
out=$(run on 2>&1)
rc=$?
_catch=$(grep -n 'meta l4proto { tcp, udp }' "$FAKE_SF_OUT_STATE" | cut -d: -f1)
_udp=$(grep -n 'udp dport 53 meta mark set 0x00000002 accept comment "zoro-exit"' "$FAKE_SF_OUT_STATE" | cut -d: -f1)
[ "$rc" -eq 0 ] && [ -n "$_udp" ] && [ -n "$_catch" ] && [ "$_udp" -lt "$_catch" ] &&
	ok "the pair goes in front of a catch-all instead of behind it" ||
	bad "the pair landed behind the catch-all [rc=$rc udp=${_udp:-none} catch=${_catch:-none}]"
out=$(run check)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'dns=ok' &&
	ok "check confirms the pair is reachable" ||
	bad "check rejected the placement [rc=$rc]"

# A pair that sits behind the catch-all is dead traffic, not a healthy switch.
reset_state
add_zoro
add_dns
printf 'on\n' >"$TMP/requested"
printf '%s\n' 'meta l4proto { tcp, udp } meta mark set 0x00000001 accept # handle 9' >"$FAKE_SF_OUT_STATE.new"
cat "$FAKE_SF_OUT_STATE" >>"$FAKE_SF_OUT_STATE.new"
mv "$FAKE_SF_OUT_STATE.new" "$FAKE_SF_OUT_STATE"
out=$(run check)
rc=$?
[ "$rc" -eq 1 ] && has "$out" 'dns=misplaced' &&
	ok "a pair behind the catch-all is reported as misplaced" ||
	bad "a shadowed pair read as healthy [rc=$rc]"

# A DNS-side failure says nothing about the rules that were already working.
reset_state
add_zoro
: >"$IPDIR/rule"
: >"$IPDIR/route"
printf 'on\n' >"$TMP/requested"
out=$(FAKE_NFT_INSERT_FAIL_ON='tproxy ip to :7895' run on 2>&1)
rc=$?
[ "$rc" -eq 1 ] && grep -q 'comment "zoro-exit"' "$STATE" && [ -f "$IPDIR/route" ] &&
	ok "a DNS repair failure leaves the installed switch alone" ||
	bad "a DNS failure tore the switch down [rc=$rc state=$(grep -c 'zoro-exit' "$STATE")]" \; rm -f "$IPDIR/route"

# ensure answers for the state it finds and changes nothing that already works.
reset_state
add_zoro
add_dns
: >"$IPDIR/rule"
: >"$IPDIR/route"
printf 'on\n' >"$TMP/requested"
out=$(run ensure)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'health=ok' && has "$out" 'reason=none' &&
	[ ! -s "$MUT" ] && [ ! -s "$SERVICE_LOG" ] && [ "$(cat "$TMP/requested")" = on ]
if [ $? -eq 0 ]; then ok "ensure leaves a healthy switch untouched"; else bad "ensure moved a healthy switch [rc=$rc mut=$(wc -l <"$MUT")]"; fi

# Nothing is being asked for, so the leftovers of an interrupted run go away.
reset_state
add_zoro
add_dns
printf 'off\n' >"$TMP/requested"
out=$(run ensure)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'health=cleaned' && ! grep -q 'comment "zoro-exit"' "$STATE" &&
	! grep -q 'comment "zoro-exit"' "$FAKE_SF_OUT_STATE" && [ "$(cat "$TMP/requested")" = off ]
if [ $? -eq 0 ]; then ok "ensure removes leftovers when the switch is asked off"; else bad "ensure left leftovers on a switch-off [rc=$rc out=$out]"; fi

reset_state
printf 'off\n' >"$TMP/requested"
out=$(run ensure)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'health=off' && [ ! -s "$MUT" ] &&
	ok "ensure reports a deliberate off without acting" ||
	bad "ensure acted on a switch that is off [rc=$rc]"

reset_state
out=$(run ensure)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'health=off' && [ ! -e "$TMP/requested" ] &&
	ok "ensure treats an unset request as off and writes nothing" ||
	bad "ensure rewrote an unset request [rc=$rc]"

reset_state
printf 'yes please\n' >"$TMP/requested"
out=$(run ensure)
rc=$?
[ "$rc" -eq 3 ] && has "$out" 'health=unknown' && has "$out" 'reason=request' &&
	ok "ensure refuses to guess an unrecognized request" ||
	bad "ensure guessed at an unrecognized request [rc=$rc]"

reset_state
printf 'on\n' >"$TMP/requested"
out=$(FAKE_NFT_TABLE_RC=1 run ensure)
rc=$?
[ "$rc" -eq 3 ] && has "$out" 'health=unknown' && has "$out" 'reason=nft-or-route' &&
	ok "ensure does not read an unreadable nft as a lost switch" ||
	bad "ensure confused unreadable nft with a loss [rc=$rc]"

reset_state
printf 'on\n' >"$TMP/requested"
out=$(FAKE_ABSENT_TABLE=sw_lan_tproxy run ensure)
rc=$?
[ "$rc" -eq 4 ] && has "$out" 'health=deferred' && has "$out" 'reason=no-table' &&
	ok "ensure defers while the table it needs is gone" ||
	bad "ensure tried to repair against a missing table [rc=$rc]"

reset_state
printf 'on\n' >"$TMP/requested"
out=$(FAKE_LISTEN=none run ensure)
rc=$?
[ "$rc" -eq 4 ] && has "$out" 'health=deferred' && has "$out" 'reason=xray' &&
	[ ! -s "$MUT" ] && [ ! -s "$SERVICE_LOG" ]
if [ $? -eq 0 ]; then ok "ensure defers instead of arming rules at a dead port"; else bad "ensure armed rules with no listener [rc=$rc]"; fi

# The three repair dimensions, each named in its own verdict.
reset_state
add_zoro
: >"$IPDIR/rule"
: >"$IPDIR/route"
printf 'on\n' >"$TMP/requested"
out=$(run ensure)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'health=repaired' && has "$out" 'reason=missing' &&
	run check | grep -q 'dns=ok'
if [ $? -eq 0 ]; then ok "ensure repairs a missing DNS pair and says so"; else bad "ensure did not repair the DNS pair [rc=$rc out=$out]"; fi

reset_state
add_zoro
add_dns
: >"$IPDIR/rule"
: >"$IPDIR/route"
printf 'on\n' >"$TMP/requested"
printf '%s\n' 'meta nfproto ipv4 udp dport 53 meta mark set 0x00000001 accept # handle 6' >"$FAKE_SF_OUT_STATE.new"
cat "$FAKE_SF_OUT_STATE" >>"$FAKE_SF_OUT_STATE.new"
mv "$FAKE_SF_OUT_STATE.new" "$FAKE_SF_OUT_STATE"
out=$(run ensure)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'health=repaired' && has "$out" 'reason=misplaced' &&
	run check | grep -q 'dns=ok'
if [ $? -eq 0 ]; then ok "ensure re-orders a shadowed DNS pair"; else bad "ensure left the pair shadowed [rc=$rc out=$out]"; fi

reset_state
add_dns
: >"$IPDIR/rule"
: >"$IPDIR/route"
printf 'on\n' >"$TMP/requested"
out=$(run ensure)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'health=repaired' && has "$out" 'reason=data' &&
	grep -q 'comment "zoro-exit"' "$STATE"
if [ $? -eq 0 ]; then ok "ensure restores a lost data rule"; else bad "ensure did not restore the data rule [rc=$rc out=$out]"; fi

reset_state
add_zoro
add_dns
: >"$IPDIR/rule"
rm -f "$IPDIR/route"
printf 'on\n' >"$TMP/requested"
out=$(run ensure)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'health=repaired' && has "$out" 'reason=route' && [ -f "$IPDIR/route" ]
if [ $? -eq 0 ]; then ok "ensure reinstalls a missing route"; else bad "ensure did not reinstall the route [rc=$rc out=$out]"; fi

# A held lock is not a failure: the caller has to be able to tell the two apart.
reset_state
add_zoro
add_dns
printf 'on\n' >"$TMP/requested"
hold_lock
out=$(run ensure 2>/dev/null)
rc=$?
release_lock_holder
[ "$rc" -eq 4 ] && has "$out" 'health=busy' &&
	ok "ensure reports a held lock as busy" ||
	bad "ensure hid a held lock [rc=$rc out=$out]"

# A dead Surflare catch is a reject rule, not a tproxy anchor. The existing
# Zoro rule below it must move above it and check must agree after ensure.
reset_state
add_zoro
add_dns
printf '%s\n' 'iifname "br-lan" meta l4proto tcp reject with tcp reset # handle 38' >"$STATE.new"
grep 'zoro-exit' "$STATE" >>"$STATE.new"
mv "$STATE.new" "$STATE"
: >"$IPDIR/rule"
: >"$IPDIR/route"
printf 'on\n' >"$TMP/requested"
status_before=$(run status)
status_rc=$?
out=$(run ensure)
rc=$?
verified=$(run check)
check_rc=$?
[ "$status_rc" -eq 0 ] && has "$status_before" 'order=misplaced' &&
	[ "$rc" -eq 0 ] && [ "$check_rc" -eq 0 ] && has "$out" 'health=repaired' &&
	has "$verified" 'order=ok' && [ "$(grep -c zoro-exit "$STATE")" -eq 1 ] &&
	ok 'ensure moves the data rule ahead of a tombstone' ||
	bad "tombstone repair disagrees with check [rc=$rc check=$check_rc out=$out]"

reset_state
add_zoro
add_dns
printf 'on\n' >"$TMP/requested"
# Malform only the data rule, preserving every other on-state dimension.
sed 's/ct mark set 0x00000200/ct mark set 0x00000000/' "$STATE" >"$STATE.new"
mv "$STATE.new" "$STATE"
: >"$IPDIR/rule"
: >"$IPDIR/route"
out=$(run ensure)
rc=$?
verified=$(run check)
check_rc=$?
[ "$rc" -eq 0 ] && [ "$check_rc" -eq 0 ] && has "$out" 'reason=data' &&
	ok 'ensure replaces an existing malformed data rule' ||
	bad "malformed data rule survived [rc=$rc check=$check_rc]"

for intent in off unset; do
	reset_state
	: >"$IPDIR/rule"
	: >"$IPDIR/route"
	[ "$intent" = unset ] || printf 'off\n' >"$TMP/requested"
	out=$(run ensure)
	rc=$?
	[ "$rc" -eq 0 ] && has "$out" 'health=cleaned' &&
		[ ! -f "$IPDIR/rule" ] && [ ! -f "$IPDIR/route" ] &&
		ok "ensure cleans route-only residue for $intent" ||
		bad "route-only residue reported off [$intent rc=$rc out=$out]"
done

reset_state
: >"$IPDIR/rule"
: >"$IPDIR/route"
printf 'off\n' >"$TMP/requested"
out=$(FAKE_ROUTE_DELETE_FAIL=1 run ensure)
rc=$?
[ "$rc" -eq 1 ] && has "$out" 'health=failed' && has "$out" 'reason=cleanup' &&
	ok 'failed route deletion is not certified cleaned' ||
	bad "route cleanup failure was hidden [rc=$rc out=$out]"

reset_state
add_zoro
add_dns
printf 'off\n' >"$TMP/requested"
out=$(FAKE_DELETE_FAIL=1 run ensure)
rc=$?
[ "$rc" -eq 1 ] && has "$out" 'health=failed' && has "$out" 'reason=cleanup' &&
	ok 'failed rule deletion is not certified cleaned' ||
	bad "rule cleanup failure was hidden [rc=$rc out=$out]"

reset_state
printf 'on\n' >"$TMP/requested"
out=$(ZORO_LOCK_FILE="$TMP/missing/lock" run ensure 2>/dev/null)
rc=$?
[ "$rc" -eq 1 ] && has "$out" 'health=failed' && has "$out" 'reason=lock' &&
	ok 'ensure lock-open failure emits a structured verdict' ||
	bad "lock-open failure was silent [rc=$rc out=$out]"

reset_state
add_zoro
add_dns
: >"$IPDIR/rule"
: >"$IPDIR/route"
printf 'on\n' >"$TMP/requested"
out=$(FAKE_ABSENT_SF_OUTPUT=1 run ensure)
rc=$?
[ "$rc" -eq 4 ] && has "$out" 'health=deferred' &&
	has "$out" 'reason=no-table' && [ ! -s "$MUT" ] &&
	ok 'ensure independently checks the Surflare chains before writing' ||
	bad "missing Surflare chain was ignored [rc=$rc out=$out]"

reset_state
printf 'off\n' >"$TMP/requested"
out=$(FAKE_LISTEN=auto run on --repair)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'health=off' && [ ! -s "$MUT" ] &&
	[ ! -s "$SERVICE_LOG" ] && [ "$(cat "$TMP/requested")" = off ] &&
	ok 'listener recovery honors a queued off under its lock' ||
	bad "recovery overrode off [rc=$rc out=$out]"

# Requested-on recovery may restart a dead listener even while Surflare is a
# tombstone; a user need not manually re-arm the same primary switch.
reset_state
printf '%s\n' 'iifname "br-lan" meta l4proto tcp reject with tcp reset # handle 38' >"$STATE"
printf 'on\n' >"$TMP/requested"
out=$(FAKE_LISTEN=auto run on --repair)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'health=repaired' &&
	grep -q '^start$' "$SERVICE_LOG" && [ "$(cat "$TMP/requested")" = on ] &&
	ok 'listener recovery also works with a tombstoned standby' ||
	bad "listener recovery depended on a live standby [rc=$rc out=$out]"

# Mixed real-producer state: TCP tombstone survived, UDP :10800 still live.
reset_state
add_zoro
add_dns
: >"$IPDIR/rule"
: >"$IPDIR/route"
printf 'on\n' >"$TMP/requested"
printf '%s\n' 'iifname "br-lan" meta l4proto tcp reject with tcp reset # handle 35' >"$STATE"
printf '%s\n' 'iifname "br-lan" meta nfproto ipv4 udp dport 443 tproxy ip to :10800 meta mark set 0x00000001 accept # handle 38' >>"$STATE"
out=$(run ensure)
rc=$?
first=$(grep -n zoro-exit "$STATE" | cut -d: -f1)
reject=$(grep -n 'tcp reject' "$STATE" | cut -d: -f1)
[ "$rc" -eq 0 ] && [ "$first" -lt "$reject" ] && has "$out" 'health=repaired' &&
	ok 'mixed TCP tombstone and live UDP cannot hide the reject' ||
	bad "mixed tombstone still shadows data [rc=$rc first=$first reject=$reject]"

reset_state
add_zoro
add_dns
: >"$IPDIR/rule"
: >"$IPDIR/route"
printf 'on\n' >"$TMP/requested"
sed '/zoro-exit/s/l4proto tcp tproxy/l4proto tcp ct state established tproxy/' "$STATE" >"$STATE.new"
mv "$STATE.new" "$STATE"
out=$(run ensure)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'health=repaired' &&
	! grep -q 'ct state established' "$STATE" &&
	ok 'an established-only catch is not a complete TCP rule' ||
	bad "restricted rule certified healthy [rc=$rc out=$out]"

for part in rule local; do
	reset_state
	add_zoro
	add_dns
	: >"$IPDIR/rule"
	: >"$IPDIR/route"
	printf 'on\n' >"$TMP/requested"
	if [ "$part" = rule ]; then
		out=$(FAKE_RULE_DELETE_FAIL=1 run off)
		rc=$?
	else
		out=$(FAKE_LOCAL_DELETE_FAIL=1 run off)
		rc=$?
	fi
	[ "$rc" -eq 1 ] && [ "$(cat "$TMP/requested")" = on ] &&
		! grep -q '^stop$' "$SERVICE_LOG" &&
		ok "partial off preserves intent and listener for remaining $part" ||
		bad "partial off was certified [$part rc=$rc]"
done

for kind in chain ip-rule ip-route; do
	reset_state
	add_zoro
	add_dns
	: >"$IPDIR/rule"
	: >"$IPDIR/route"
	printf 'off\n' >"$TMP/requested"
	case "$kind" in
	chain)
		out=$(FAKE_NFT_CHAIN_RC=1 run ensure)
		rc=$?
		;;
	ip-rule)
		out=$(FAKE_IP_RULE_READ_FAIL=1 run ensure)
		rc=$?
		;;
	ip-route)
		out=$(FAKE_IP_ROUTE_READ_FAIL=1 run ensure)
		rc=$?
		;;
	esac
	[ "$rc" -eq 3 ] && has "$out" 'health=unknown' && [ ! -s "$MUT" ] &&
		ok "unreadable $kind is not absence and causes no cleanup" ||
		bad "unreadable $kind certified absence [rc=$rc out=$out]"
done

reset_state
add_zoro
add_dns
: >"$IPDIR/rule"
: >"$IPDIR/route"
printf 'off\n' >"$TMP/requested"
out=$(FAKE_POST_DELETE_FAIL="$TMP/fail-after-delete" run ensure)
rc=$?
[ "$rc" -eq 3 ] && has "$out" 'health=unknown' && grep -q zoro-exit "$STATE" &&
	ok 'unreadable post-delete verification is not cleaned' ||
	bad "post-delete failure certified cleaned [rc=$rc out=$out]"

reset_state
add_dns
: >"$IPDIR/rule"
: >"$IPDIR/route"
printf 'off\n' >"$TMP/requested"
out=$(FAKE_ABSENT_TABLE=sw_lan_tproxy run ensure)
rc=$?
[ "$rc" -eq 0 ] && has "$out" 'health=cleaned' &&
	[ ! -f "$IPDIR/rule" ] && [ ! -f "$IPDIR/route" ] &&
	! grep -q zoro-exit "$FAKE_SF_OUT_STATE" &&
	ok 'absent data table does not prevent DNS and route cleanup' ||
	bad "absent data table stranded unrelated residue [rc=$rc out=$out]"

reset_state
add_zoro
add_dns
: >"$IPDIR/rule"
: >"$IPDIR/route"
printf 'on\n' >"$TMP/requested"
printf '%s\n' 'ip daddr 203.0.113.7 return # handle 70' >>"$STATE"
grep -v 'tproxy ip to :10800' "$STATE" >"$STATE.new"
printf '%s\n' 'iifname "br-lan" meta l4proto tcp tproxy ip to :10800 meta mark set 0x00000001 accept # handle 38' >>"$STATE.new"
mv "$STATE.new" "$STATE"
before=$(cat "$STATE")
out=$(FAKE_NFT_INSERT_FAIL_ON='tproxy ip to :7895' run ensure)
rc=$?
[ "$rc" -eq 1 ] && has "$out" 'reason=data' && [ "$(cat "$STATE")" = "$before" ] &&
	ok 'failed replacement keeps the original working data rule byte-for-byte' ||
	bad "failed insert removed the old working path [rc=$rc out=$out]"

# A failed second insert leaves the first rule in place on purpose: deleting it
# cannot be told apart from removing a concurrent writer's identical rule, and a
# rule with our own mark is harmless. The run must say so and keep every rule.
reset_state
add_zoro
add_dns
: >"$IPDIR/rule"
: >"$IPDIR/route"
printf 'on\n' >"$TMP/requested"
sed -i '/udp dport 53/s/0x00000002 accept/0x00000009 accept/' "$FAKE_SF_OUT_STATE"
_before_lines=$(wc -l <"$FAKE_SF_OUT_STATE")
out=$(FAKE_NFT_INSERT_FAIL_ON='tcp dport 53' run on --force 2>&1)
rc=$?
_after_lines=$(wc -l <"$FAKE_SF_OUT_STATE")
_ours=$(grep -c 'udp dport 53 meta mark set 0x00000002 accept comment "zoro-exit"' "$FAKE_SF_OUT_STATE" 2>/dev/null) || _ours=0
# The WARN goes through the daemon logger, which the fixture stubs out, so the
# observable evidence is the retained rule plus the failure code.
if [ "$rc" -eq 1 ] && [ "$_ours" -eq 1 ] && [ "$_after_lines" -ge "$_before_lines" ]; then
	ok 'a failed rebuild leaves its own half-install in place and says so'
else
	bad "half-installed rule handling is unclear [rc=$rc ours=$_ours lines=$_before_lines->$_after_lines]"
fi

# The failure path needs the same live re-check: a rule another writer took over
# during our insert attempt must not be cleaned up as if it were ours.
reset_state
add_zoro
add_dns
: >"$IPDIR/rule"
: >"$IPDIR/route"
printf 'on\n' >"$TMP/requested"
sed -i '/udp dport 53/s/0x00000002 accept/0x00000009 accept/' "$FAKE_SF_OUT_STATE"
out=$(FAKE_RECYCLE_ON_INSERT=1 FAKE_NFT_INSERT_FAIL_ON='tcp dport 53' run on --force 2>&1)
rc=$?
_foreign2=$(grep -c 'someone-else' "$FAKE_SF_OUT_STATE" 2>/dev/null) || _foreign2=0
_our_tcp=$(grep -c 'tcp dport 53 meta mark set 0x2\?' "$FAKE_SF_OUT_STATE" 2>/dev/null) || _our_tcp=0
if [ "$rc" -eq 1 ] && [ "$_foreign2" -ge 1 ]; then
	ok 'a failed rebuild keeps a rule another writer added'
else
	bad "the failed-rebuild cleanup deleted a foreign rule [rc=$rc foreign=$_foreign2]"
fi
# A handle another writer recycled between capture and delete must survive: the
# delete pass re-reads the live chain instead of trusting the captured list.
reset_state
add_zoro
add_dns
: >"$IPDIR/rule"
: >"$IPDIR/route"
printf 'on\n' >"$TMP/requested"
sed -i '/udp dport 53/s/0x00000002 accept/0x00000009 accept/' "$FAKE_SF_OUT_STATE"
out=$(FAKE_RECYCLE_ON_INSERT=1 run on --force 2>&1)
rc=$?
_foreign=$(grep -c 'someone-else' "$FAKE_SF_OUT_STATE" 2>/dev/null) || _foreign=0
if [ "$_foreign" -ge 1 ]; then
	ok 'a rule another writer added is not deleted by the rebuild cleanup'
else
	bad "the rebuild deleted a rule another writer owned [rc=$rc foreign=$_foreign]"
fi

# A DNS rebuild that fails must leave the working pair in place: the old rules
# are removed only after both new ones are in.
reset_state
add_zoro
add_dns
: >"$IPDIR/rule"
: >"$IPDIR/route"
printf 'on\n' >"$TMP/requested"
# A complete pair with both handles captured is the realistic input: the
# rollback must not treat it as "not ours" and delete everything.
reset_state
add_zoro
add_dns
: >"$IPDIR/rule"
: >"$IPDIR/route"
printf 'on\n' >"$TMP/requested"
# Make the udp rule wrong so a rebuild is required while both handles exist
sed -i '/udp dport 53/s/0x00000002 accept/0x00000009 accept/' "$FAKE_SF_OUT_STATE"
_pair_before=$(grep -c 'dport 53 meta mark set' "$FAKE_SF_OUT_STATE")
out=$(FAKE_NFT_INSERT_FAIL_ON='udp dport 53' run on --force 2>&1)
rc=$?
_pair_after=$(grep -c 'dport 53 meta mark set' "$FAKE_SF_OUT_STATE" 2>/dev/null) || _pair_after=0
if [ "$rc" -eq 1 ] && [ "$_pair_before" -eq 2 ] && [ "$_pair_after" -eq 2 ] &&
	! grep -q 'another zoro-exit is running' <<EOF_OUT; then
$out
EOF_OUT
	ok 'a failed rebuild keeps both captured output rules'
else
	bad "rollback deleted a captured rule it did not add [rc=$rc before=$_pair_before after=$_pair_after out=$(cat "$TMP/out")]"
fi

# Drop the udp half so a rebuild is required, then fail its insert.
sed -i '/udp dport 53/d' "$FAKE_SF_OUT_STATE"
_before=$(grep -c 'tcp dport 53 meta mark set 0x00000002' "$FAKE_SF_OUT_STATE")
out=$(FAKE_NFT_INSERT_FAIL_ON='udp dport 53' run on --force 2>&1)
rc=$?
_after=$(grep -c 'tcp dport 53 meta mark set 0x00000002' "$FAKE_SF_OUT_STATE" 2>/dev/null) || _after=0
[ "$rc" -ne 0 ] && [ "$_before" -eq 1 ] && [ "$_after" -eq 1 ] &&
	ok 'a failed DNS rebuild keeps the surviving output rule' ||
	bad "a failed DNS rebuild removed the working DNS rule [rc=$rc before=$_before after=$_after]"

# An unreadable request file is unknown, not a clean "off".
reset_state
add_zoro
add_dns
: >"$IPDIR/rule"
: >"$IPDIR/route"
printf 'bogus\n' >"$TMP/requested"
out=$(run on --repair 2>&1)
rc=$?
[ "$rc" -eq 3 ] && has "$out" 'health=unknown' &&
	ok 'on --repair reports an unreadable request as unknown' ||
	bad "on --repair guessed off for an unreadable request [rc=$rc out=$out]"

# A service that will not stop is a failure, not a clean off.
reset_state
add_zoro
add_dns
: >"$IPDIR/rule"
: >"$IPDIR/route"
printf 'on\n' >"$TMP/requested"
: >"$FAKE_LISTEN_FLAG"
out=$(FAKE_SERVICE_STOP_RC=1 run off --force 2>&1)
rc=$?
[ "$rc" -eq 5 ] && has "$out" 'reason=service-stop-failed' &&
	[ "$(cat "$TMP/requested")" = off ] &&
	ok 'off reports a service that would not stop' ||
	bad "off hid a failed service stop [rc=$rc out=$out]"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ] && [ "$pass" -eq 120 ]
