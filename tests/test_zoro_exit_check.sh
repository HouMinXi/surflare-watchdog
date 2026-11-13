#!/bin/sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/router/zoro-exit"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
STATE="$TMP/nft.state"
IPDIR="$TMP/ip"
mkdir -p "$BIN" "$IPDIR"
MUT="$TMP/mutations.log"
CURL_LOG="$TMP/curl.log"
SERVICE_LOG="$TMP/service.log"
: > "$MUT"
: > "$CURL_LOG"
: > "$SERVICE_LOG"

cat > "$BIN/logger" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$BIN/ss" <<'EOF'
#!/bin/sh
case "${FAKE_LISTEN:-public}" in
	public) echo 'LISTEN 0 4096 *:7895 *:*' ;;
	loopback) echo 'LISTEN 0 4096 127.0.0.1:7895 0.0.0.0:*' ;;
	auto) [ -f "${FAKE_LISTEN_FLAG:?}" ] && echo 'LISTEN 0 4096 *:7895 *:*' ;;
esac
exit 0
EOF

cat > "$BIN/nft" <<'EOF'
#!/bin/sh
# Multi-chain fake. Each chain lives in its own state file; the table name
# selects it. Handles are static (37 for adds) like the old single-chain
# fake, which is fine because nothing here tests handle arithmetic.
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
"list table")
	[ "$3 $4" = "inet sw_lan_tproxy" ] || exit 1
	exit "${FAKE_NFT_TABLE_RC:-0}"
	;;
"list chain")
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
	_file=$(chain_file "$4" "$5") || exit 1
	[ "${FAKE_NFT_INSERT_RC:-0}" = 0 ] || exit 1
	printf '%s\n' "$*" >> "${FAKE_INSERT_LOG:?}"
	printf 'nft %s\n' "$*" >> "${FAKE_MUTATION_LOG:?}"
	# drop argv through the chain name; what remains is [position H] RULE
	shift 5
	_pos=""
	if [ "${1:-}" = position ]; then
		_pos=$2
		shift 2
	fi
	line=$(printf '%s' "$*" | sed 's/\( \|^\)iifname \([^ ]*\)/\1iifname "\2"/; s/ comment \([^ ]*\)$/ comment "\1"/')
	if [ "$_cmd" = "insert rule" ] && [ -n "$_pos" ]; then
		ln=$(grep -n "# handle ${_pos}\$" "$_file" | head -1 | cut -d: -f1)
		if [ -n "$ln" ]; then
			head -n "$((ln - 1))" "$_file" > "$_file.new"
			printf '%s # handle 37\n' "$line" >> "$_file.new"
			tail -n "+$ln" "$_file" >> "$_file.new"
		else
			printf '%s # handle 37\n' "$line" > "$_file.new"
			cat "$_file" >> "$_file.new"
		fi
	elif [ "$_cmd" = "insert rule" ]; then
		printf '%s # handle 37\n' "$line" > "$_file.new"
		cat "$_file" >> "$_file.new"
	else
		cat "$_file" > "$_file.new"
		printf '%s # handle 37\n' "$line" >> "$_file.new"
	fi
	mv "$_file.new" "$_file"
	exit 0
	;;
"delete rule")
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

cat > "$BIN/ip" <<'EOF'
#!/bin/sh
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
		printf 'ip %s\n' "$*" >> "${FAKE_MUTATION_LOG:?}"
		rm -f "${FAKE_IPDIR:?}/rule"
		exit 0
		;;
	*" route del "*)
		printf 'ip %s\n' "$*" >> "${FAKE_MUTATION_LOG:?}"
		rm -f "${FAKE_IPDIR:?}/route"
		exit 0
		;;
	*" rule "*)
		[ -f "${FAKE_IPDIR:?}/rule" ] && echo '1000: from all fwmark 0x2 lookup 101'
		exit 0
		;;
	*" route show table 101 "*)
		[ -f "${FAKE_IPDIR:?}/route" ] && echo 'local default dev lo scope host'
		exit 0
		;;
esac
exit 0
EOF

cat > "$BIN/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${FAKE_CURL_LOG:?}"
printf '%s' "${FAKE_HTTP:-204}"
exit "${FAKE_CURL_RC:-0}"
EOF

cat > "$BIN/dnspy" <<'EOF'
#!/bin/sh
cat > /dev/null
exit "${FAKE_DNS_RC:-0}"
EOF

cat > "$BIN/service" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${FAKE_SERVICE_LOG:?}"
[ "$1" = start ] && : > "${FAKE_LISTEN_FLAG:?}"
[ "$1" = stop ] && rm -f "${FAKE_LISTEN_FLAG:?}"
exit 0
EOF

chmod 755 "$BIN"/*
: > "$TMP/xray.json"
export ZORO_TEST_MODE=1
export ZORO_NFT="$BIN/nft" ZORO_IP="$BIN/ip" ZORO_SS="$BIN/ss"
export ZORO_CURL="$BIN/curl" ZORO_LOGGER="$BIN/logger"
export ZORO_SERVICE="$BIN/service" ZORO_DNSPY="$BIN/dnspy" ZORO_PROBE_URL="https://probe.invalid/generate_204" ZORO_STATE_FILE="$TMP/requested" ZORO_CONFIG="$TMP/xray.json"
export FAKE_NFT_STATE="$STATE" FAKE_IPDIR="$IPDIR" FAKE_LISTEN_FLAG="$TMP/listening"
export FAKE_SF_PRE_STATE="$TMP/sf_pre.state" FAKE_SF_OUT_STATE="$TMP/sf_out.state" FAKE_KS_OUT_STATE="$TMP/ks_out.state"
export FAKE_MUTATION_LOG="$MUT" FAKE_CURL_LOG="$CURL_LOG" FAKE_SERVICE_LOG="$SERVICE_LOG"
export FAKE_INSERT_LOG="$TMP/insert.log"

pass=0
fail=0
ok() { printf 'PASS %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }
has() { printf '%s\n' "$1" | grep -q "^$2$"; }

reset_state() {
	rm -f "$TMP/requested"
	: > "$FAKE_SF_PRE_STATE"
	printf '%s\n' \
		'oifname "lo" tcp dport 10800 counter drop comment "watchdog-tproxy-self-dial" # handle 2' \
		'tcp sport @server_ports accept # handle 3' \
		'udp sport @server_ports accept # handle 4' \
		'tcp dport 53 meta mark set 0x00000001 accept # handle 6' \
		'udp dport 53 meta mark set 0x00000001 accept # handle 7' \
		'meta l4proto { tcp, udp } meta mark set 0x00000001 accept # handle 9' \
		> "$FAKE_SF_OUT_STATE"
	printf '%s\n' \
		'ct state invalid drop # handle 1' \
		'oif "lo" accept # handle 2' \
		'meta mark 0x00000001 accept # handle 3' \
		'meta mark 0x000000ff accept # handle 4' \
		> "$FAKE_KS_OUT_STATE"
	printf 'iifname "br-lan" meta nfproto ipv4 meta l4proto tcp tproxy ip to :10800 meta mark set 0x00000001 ct mark set 0x00000100 accept # handle 38\n' > "$STATE"
	rm -f "$IPDIR/rule" "$IPDIR/route"
	: > "$MUT"; : > "$CURL_LOG"; : > "$SERVICE_LOG"; : > "$FAKE_INSERT_LOG"
}

add_zoro() {
	printf 'iifname "br-lan" meta nfproto ipv4 meta l4proto tcp tproxy ip to :7895 meta mark set 0x00000002 ct mark set 0x00000200 accept comment "zoro-exit" # handle 37\n' > "$STATE.new"
	cat "$STATE" >> "$STATE.new"
	mv "$STATE.new" "$STATE"
}

add_dns() {
	printf '%s\n' \
		'meta nfproto ipv4 meta l4proto udp meta mark 0x00000002 tproxy ip to :7895 meta mark set 0x00000002 accept comment "zoro-exit" # handle 31' \
		'meta nfproto ipv4 meta l4proto tcp meta mark 0x00000002 tproxy ip to :7895 meta mark set 0x00000002 accept comment "zoro-exit" # handle 32' \
		> "$FAKE_SF_PRE_STATE"
	printf '%s\n' \
		'meta nfproto ipv4 udp dport 53 meta mark set 0x00000002 accept comment "zoro-exit" # handle 33' \
		'meta nfproto ipv4 tcp dport 53 meta mark set 0x00000002 accept comment "zoro-exit" # handle 34' \
		> "$FAKE_SF_OUT_STATE"
	printf '%s\n' \
		'meta mark 0x00000002 accept comment "zoro-exit" # handle 35' \
		> "$FAKE_KS_OUT_STATE"
}

run() {
	FAKE_DNS_RC="${FAKE_DNS_RC:-0}" \
	FAKE_LISTEN="${FAKE_LISTEN:-public}" FAKE_HTTP="${FAKE_HTTP:-204}" \
	FAKE_CURL_RC="${FAKE_CURL_RC:-0}" FAKE_NFT_TABLE_RC="${FAKE_NFT_TABLE_RC:-0}" \
	FAKE_NFT_CHAIN_RC="${FAKE_NFT_CHAIN_RC:-0}" \
	"$SCRIPT" "$@"
}

reset_state
out=$(FAKE_LISTEN=none run check); rc=$?
[ "$rc" -eq 0 ] && has "$out" 'mode=off' && has "$out" 'route=missing' &&
	has "$out" 'xray_listening=no' && has "$out" 'probe=skipped' &&
	[ ! -s "$MUT" ] && [ ! -s "$SERVICE_LOG" ]
if [ $? -eq 0 ]; then ok 'off state is measured and read-only'; else bad 'off state is measured and read-only'; fi

reset_state; add_zoro; add_dns; : > "$IPDIR/rule"; : > "$IPDIR/route"
out=$(run check); rc=$?
[ "$rc" -eq 0 ] && has "$out" 'mode=on' && has "$out" 'route=ok' &&
	has "$out" 'xray_listening=yes' && has "$out" 'order=ok' &&
	has "$out" 'probe=ok' && [ ! -s "$MUT" ] && [ ! -s "$SERVICE_LOG" ] &&
	grep -q -- '--socks5-hostname 127.0.0.1:7890' "$CURL_LOG"
if [ $? -eq 0 ]; then ok 'healthy on path is measured and read-only'; else bad 'healthy on path is measured and read-only'; fi

reset_state
out=$(FAKE_HTTP=000 FAKE_CURL_RC=7 run on 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'comment "zoro-exit"' "$STATE" && [ ! -f "$IPDIR/route" ] && [ ! -e "$TMP/requested" ]
if [ $? -eq 0 ]; then ok 'on preflight failure changes nothing'; else bad 'on preflight failure changes nothing'; fi

reset_state; add_zoro; : > "$IPDIR/rule"; : > "$IPDIR/route"
out=$(FAKE_HTTP=000 FAKE_CURL_RC=7 run check); rc=$?
[ "$rc" -eq 1 ] && has "$out" 'probe=fail'
if [ $? -eq 0 ]; then ok 'probe failure exits 1'; else bad 'probe failure exits 1'; fi

reset_state; add_zoro; : > "$IPDIR/rule"
out=$(run check); rc=$?
[ "$rc" -eq 1 ] && has "$out" 'route=missing'
if [ $? -eq 0 ]; then ok 'missing table-101 route exits 1'; else bad 'missing table-101 route exits 1'; fi

reset_state; add_zoro; : > "$IPDIR/rule"; : > "$IPDIR/route"
out=$(FAKE_LISTEN=none run check); rc=$?
[ "$rc" -eq 1 ] && has "$out" 'xray_listening=no'
if [ $? -eq 0 ]; then ok 'listener down exits 1'; else bad 'listener down exits 1'; fi

reset_state; add_zoro; : > "$IPDIR/rule"; : > "$IPDIR/route"
out=$(FAKE_LISTEN=loopback run check); rc=$?
[ "$rc" -eq 1 ] && has "$out" 'xray_listening=no'
if [ $? -eq 0 ]; then ok 'loopback-only listener is rejected'; else bad 'loopback-only listener is rejected'; fi

reset_state
printf 'iifname "br-lan" meta nfproto ipv4 meta l4proto tcp tproxy ip to :7895 meta mark set 0x00000002 ct mark set 0x00000200 accept comment "zoro-exit" # handle 39\n' > "$STATE"
printf 'iifname "br-lan" ip daddr @bypass_devices return # handle 15\n' >> "$STATE"
printf 'iifname "br-lan" meta nfproto ipv4 meta l4proto tcp tproxy ip to :10800 meta mark set 0x00000001 ct mark set 0x00000100 accept # handle 38\n' >> "$STATE"
: > "$IPDIR/rule"; : > "$IPDIR/route"
out=$(run check); rc=$?
[ "$rc" -eq 1 ] && has "$out" 'order=misplaced'
if [ $? -eq 0 ]; then ok 'rule above bypass returns is misplaced'; else bad 'rule above bypass returns is misplaced'; fi

reset_state
# Real misplaced shape: zoro, bypass return, then :10800 (adjacency broken).
printf 'iifname "br-lan" meta nfproto ipv4 meta l4proto tcp tproxy ip to :7895 meta mark set 0x00000002 ct mark set 0x00000200 accept comment "zoro-exit" # handle 37\n' > "$STATE"
printf 'iifname "br-lan" ip daddr @bypass_devices return # handle 15\n' >> "$STATE"
printf 'iifname "br-lan" meta nfproto ipv4 meta l4proto tcp tproxy ip to :10800 meta mark set 0x00000001 ct mark set 0x00000100 accept # handle 38\n' >> "$STATE"
out=$(run on 2>&1); rc=$?
_z=$(grep -n 'comment "zoro-exit"' "$STATE" | cut -d: -f1)
_s=$(grep -n 'tproxy ip to :10800' "$STATE" | cut -d: -f1)
if [ "$rc" -eq 0 ] && [ -n "$_z" ] && [ "$_z" -eq "$((_s - 1))" ]; then
	ok 'on repairs a misplaced rule'
else
	bad 'on repairs a misplaced rule'
fi

reset_state; : > "$IPDIR/rule"; : > "$IPDIR/route"; printf 'on\n' > "$TMP/requested"
out=$(run status); rc=$?
[ "$rc" -eq 1 ] && has "$out" 'mode=lost'
if [ $? -eq 0 ]; then ok 'status exits 1 for mode=lost'; else bad 'status exits 1 for mode=lost'; fi

reset_state
out=$(FAKE_NFT_TABLE_RC=1 run check); rc=$?
[ "$rc" -eq 3 ] && has "$out" 'mode=unknown' && has "$out" 'xray_listening=yes' &&
	[ ! -s "$MUT" ] && [ ! -s "$SERVICE_LOG" ]
if [ $? -eq 0 ]; then ok 'unreadable table is unknown'; else bad 'unreadable table is unknown'; fi

reset_state; printf 'on\n' > "$TMP/requested"
out=$(run check); rc=$?
[ "$rc" -eq 1 ] && has "$out" 'mode=lost'
if [ $? -eq 0 ]; then ok 'requested on but rule gone is mode=lost'; else bad 'requested on but rule gone is mode=lost'; fi

reset_state; : > "$TMP/requested"
out=$(run status); rc=$?
[ "$rc" -eq 3 ] && has "$out" 'mode=unknown'
if [ $? -eq 0 ]; then ok 'status exits 3 for an unreadable requested state'; else bad 'status exits 3 for an unreadable requested state'; fi

reset_state
sed -i '/:10800/d' "$STATE"
out=$(run on --force 2>&1); rc=$?
grep -q 'comment "zoro-exit"' "$STATE" && [ "$rc" -eq 0 ] && ! head -1 "$FAKE_INSERT_LOG" | grep -q 'position'
if [ $? -eq 0 ]; then ok 'on --force works without a Surflare fallback'; else bad 'on --force works without a Surflare fallback'; fi

reset_state; add_zoro; sed -i 's/0x00000002/0x00000009/' "$STATE"
: > "$IPDIR/rule"; : > "$IPDIR/route"
out=$(run on 2>&1); rc=$?
grep -q 'meta mark set 0x00000002' "$STATE" && [ "$rc" -eq 0 ] && [ "$(grep -c 'comment "zoro-exit"' "$STATE")" -eq 1 ]
if [ $? -eq 0 ]; then ok 'on replaces a stale rule with the correct mark'; else bad 'on replaces a stale rule with the correct mark'; fi

reset_state; add_zoro; : > "$IPDIR/rule"; : > "$IPDIR/route"
out=$(FAKE_NFT_TABLE_RC=1 run off --force 2>&1); rc=$?
[ "$rc" -ne 0 ] && [ -f "$IPDIR/route" ] && ! grep -q '^stop$' "$SERVICE_LOG"
if [ $? -eq 0 ]; then ok 'off refuses while nft is unreadable'; else bad 'off refuses while nft is unreadable'; fi

reset_state
printf 'iifname "br-lan" meta nfproto ipv4 meta l4proto tcp reject with tcp reset # handle 38\n' > "$STATE"
: > "$IPDIR/rule"; : > "$IPDIR/route"
out=$(run on --force 2>&1); rc=$?
_z=$(grep -n 'comment "zoro-exit"' "$STATE" | cut -d: -f1)
_t=$(grep -n 'l4proto tcp reject' "$STATE" | cut -d: -f1)
if [ "$rc" -eq 0 ] && [ -n "$_z" ] && [ -n "$_t" ] && [ "$_z" -lt "$_t" ]; then
	ok 'on --force inserts above the Surflare tombstone reject'
else
	bad 'on --force inserts above the Surflare tombstone reject'
fi

reset_state
printf 'iifname "br-lan" meta nfproto ipv4 meta l4proto tcp reject with tcp reset # handle 38\n' > "$STATE"
printf 'iifname "br-lan" meta nfproto ipv4 meta l4proto tcp tproxy ip to :7895 meta mark set 0x00000002 ct mark set 0x00000200 accept comment "zoro-exit" # handle 39\n' >> "$STATE"
: > "$IPDIR/rule"; : > "$IPDIR/route"
out=$(run check); rc=$?
[ "$rc" -eq 1 ] && has "$out" 'order=misplaced'
if [ $? -eq 0 ]; then ok 'rule behind a tombstone is misplaced'; else bad 'rule behind a tombstone is misplaced'; fi

reset_state
: > "$IPDIR/rule"; : > "$IPDIR/route"
out=$(FAKE_LISTEN=none run check); rc=$?
[ "$rc" -eq 0 ] && has "$out" 'mode=off' && has "$out" 'route=ok'
if [ $? -eq 0 ]; then ok 'off measures a leftover policy route'; else bad 'off measures a leftover policy route'; fi

reset_state; add_zoro; : > "$IPDIR/rule"; : > "$IPDIR/route"
out=$(run status); rc=$?
[ "$rc" -eq 0 ] && has "$out" 'mode=on' && has "$out" 'route=ok' &&
	has "$out" 'surflare_10800=yes'
if [ $? -eq 0 ]; then ok 'status reports on-state keys'; else bad 'status reports on-state keys'; fi

reset_state; add_zoro; sed -i '/:10800/d' "$STATE"
: > "$IPDIR/rule"; : > "$IPDIR/route"
out=$(run off --force 2>&1); rc=$?
! grep -q 'comment "zoro-exit"' "$STATE" && [ "$rc" -eq 0 ]
if [ $? -eq 0 ]; then ok 'off --force works when Surflare is tombstoned'; else bad 'off --force works when Surflare is tombstoned'; fi

reset_state; add_zoro; : > "$IPDIR/rule"; : > "$IPDIR/route"; sed -i '/:10800/d' "$STATE"
out=$(run off 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'comment "zoro-exit"' "$STATE" && [ ! -s "$MUT" ]
if [ $? -eq 0 ]; then ok 'off refuses without --force when fallback is missing'; else bad 'off refuses without --force when fallback is missing'; fi

reset_state; add_zoro; add_dns; : > "$IPDIR/rule"; : > "$IPDIR/route"; sed -i '/:10800/d' "$STATE"
out=$(run check); rc=$?
[ "$rc" -eq 0 ] && has "$out" 'fallback=missing' && has "$out" 'order=unverified' && has "$out" 'probe=ok' && [ ! -s "$MUT" ]
if [ $? -eq 0 ]; then ok 'check does not false-fail when fallback is tombstoned'; else bad 'check does not false-fail when fallback is tombstoned'; fi

reset_state; : > "$IPDIR/rule"; : > "$IPDIR/route"; sed -i '/:10800/d' "$STATE"
out=$(run on 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'comment "zoro-exit"' "$STATE" && [ ! -s "$MUT" ]
if [ $? -eq 0 ]; then ok 'on refuses when Surflare fallback is missing'; else bad 'on refuses when Surflare fallback is missing'; fi

reset_state; rm -f "$FAKE_LISTEN_FLAG"
out=$(FAKE_LISTEN=auto run on 2>&1); rc=$?
grep -q '^start$' "$SERVICE_LOG" && grep -q 'comment "zoro-exit"' "$STATE" && [ "$rc" -eq 0 ]
if [ $? -eq 0 ]; then ok 'on starts the xray service when needed'; else bad 'on starts the xray service when needed'; fi

reset_state
out=$(run on 2>&1); rc=$?
grep -q 'comment "zoro-exit"' "$STATE" && [ -f "$IPDIR/rule" ] && [ -f "$IPDIR/route" ] && [ "$rc" -eq 0 ] && [ "$(cat "$TMP/requested" 2>/dev/null)" = on ] && grep -q 'position 38' "$FAKE_INSERT_LOG" && grep -q 'meta nfproto ipv4' "$FAKE_INSERT_LOG" && grep -q 'tproxy ip to :7895' "$FAKE_INSERT_LOG" && grep -q 'comment zoro-exit' "$FAKE_INSERT_LOG"
if [ $? -eq 0 ]; then ok 'on installs rule and route'; else bad 'on installs rule and route'; fi

out=$(run on 2>&1); rc=$?
idem=1
if [ "$(grep -c 'comment "zoro-exit"' "$STATE")" -eq 1 ] && [ "$rc" -eq 0 ] && [ "$(wc -l < "$FAKE_INSERT_LOG")" -eq 6 ]; then
	idem=0
fi
if [ "$idem" -eq 0 ]; then ok 'on is idempotent'; else bad 'on is idempotent'; fi

out=$(run off 2>&1); rc=$?
! grep -q 'comment "zoro-exit"' "$STATE" && [ ! -f "$IPDIR/rule" ] && [ ! -f "$IPDIR/route" ] && [ "$rc" -eq 0 ] && grep -q '^stop$' "$SERVICE_LOG" && [ "$(cat "$TMP/requested" 2>/dev/null)" = off ]
if [ $? -eq 0 ]; then ok 'off removes rule and route and stops xray'; else bad 'off removes rule and route and stops xray'; fi

reset_state
out=$(FAKE_NFT_CHAIN_RC=1 run check); rc=$?
[ "$rc" -eq 3 ] && has "$out" 'mode=unknown'
if [ $? -eq 0 ]; then ok 'unreadable chain is unknown'; else bad 'unreadable chain is unknown'; fi

reset_state; add_zoro; add_dns; : > "$IPDIR/rule"; : > "$IPDIR/route"
out=$(FAKE_HTTP=200 run check); rc=$?
[ "$rc" -eq 0 ] && has "$out" 'probe=ok'
if [ $? -eq 0 ]; then ok 'probe accepts HTTP 200'; else bad 'probe accepts HTTP 200'; fi

reset_state
out=$(run status); rc=$?
[ "$rc" -eq 0 ] && has "$out" 'mode=off' && [ ! -s "$MUT" ] && [ ! -s "$SERVICE_LOG" ]
if [ $? -eq 0 ]; then ok 'status is read-only'; else bad 'status is read-only'; fi

reset_state
run check --alert >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok 'unknown check argument is usage error'; else bad 'unknown check argument is usage error'; fi
run bogus >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok 'unknown subcommand is usage error'; else bad 'unknown subcommand is usage error'; fi

reset_state
FAKE_IPDIR="$TMP/nonexistent" run on >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'comment "zoro-exit"' "$STATE"
if [ $? -eq 0 ]; then ok 'on fails closed when route cannot install'; else bad 'on fails closed when route cannot install'; fi

reset_state
out=$(FAKE_NFT_INSERT_RC=1 run on 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'comment "zoro-exit"' "$STATE" && [ ! -f "$IPDIR/route" ]
if [ $? -eq 0 ]; then ok 'on rolls back when nft insert fails'; else bad 'on rolls back when nft insert fails'; fi

reset_state; mkdir -p "$TMP/state-dir"
out=$(ZORO_STATE_FILE="$TMP/state-dir" run on 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'comment "zoro-exit"' "$STATE" && [ ! -f "$IPDIR/route" ]
if [ $? -eq 0 ]; then ok 'on rolls back when requested state cannot be recorded'; else bad 'on rolls back when requested state cannot be recorded'; fi

reset_state; add_zoro; : > "$IPDIR/rule"; : > "$IPDIR/route"
out=$(ZORO_STATE_FILE="$TMP/state-dir" run on 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'comment "zoro-exit"' "$STATE" && [ -f "$IPDIR/route" ]
if [ $? -eq 0 ]; then ok 'on keeps a pre-existing healthy rule when state write fails'; else bad 'on keeps a pre-existing healthy rule when state write fails'; fi

reset_state; add_zoro; sed -i 's/7895/9999/' "$STATE"; : > "$IPDIR/rule"; : > "$IPDIR/route"
out=$(run check); rc=$?
[ "$rc" -eq 1 ] && has "$out" 'order=misplaced'
if [ $? -eq 0 ]; then ok 'rule with the wrong port exits 1'; else bad 'rule with the wrong port exits 1'; fi

# --- DNS exit consistency ---
# When the switch is on, the router's own upstream DNS must leave through
# Zoro like the data path: tproxy catch in surflare prerouting, dport-53
# mark rules ahead of the mark-0x1 rules in surflare output, and a
# killswitch accept for mark 0x2 (which the ks accept set lacked).

reset_state
run on >/dev/null 2>&1
[ "$?" -eq 0 ] \
	&& grep -q 'meta l4proto udp meta mark 0x00000002' "$FAKE_SF_PRE_STATE" \
	&& grep -q 'tproxy ip to :7895' "$FAKE_SF_PRE_STATE" \
	&& ok "on installs the udp tproxy catch" \
	|| bad "on missed the udp tproxy catch"

grep -q 'meta l4proto tcp meta mark 0x00000002' "$FAKE_SF_PRE_STATE" \
	&& ok "on installs the tcp tproxy catch" \
	|| bad "on missed the tcp tproxy catch"

grep -q 'meta nfproto ipv4 udp dport 53 meta mark set 0x00000002' "$FAKE_SF_OUT_STATE" \
	&& ok "the output rules are IPv4-qualified" \
	|| bad "the output rules lost their family qualifier"

_sport_ln=$(grep -n 'udp sport @server_ports accept' "$FAKE_SF_OUT_STATE" | head -1 | cut -d: -f1)
_first_zoro_ln=$(grep -n 'zoro-exit' "$FAKE_SF_OUT_STATE" | head -1 | cut -d: -f1)
[ -n "$_sport_ln" ] && [ "$_sport_ln" -lt "$_first_zoro_ln" ] \
	&& ok "the output rules stay behind the server-port accepts" \
	|| bad "the output rules jumped ahead of the server-port accepts"

_dns_ln=$(grep -n 'dport 53 meta mark set 0x00000002' "$FAKE_SF_OUT_STATE" | head -1 | cut -d: -f1)
_sf_ln=$(grep -n 'dport 53 meta mark set 0x00000001' "$FAKE_SF_OUT_STATE" | head -1 | cut -d: -f1)
[ -n "$_dns_ln" ] && [ -n "$_sf_ln" ] && [ "$_dns_ln" -lt "$_sf_ln" ] \
	&& ok "the zoro DNS mark rules precede the surflare ones" \
	|| bad "the zoro DNS mark rules landed after the surflare ones [$_dns_ln vs $_sf_ln]"

grep -q 'meta mark 0x00000002 accept' "$FAKE_KS_OUT_STATE" \
	&& ! grep -q 'meta mark set 0x00000002 accept' "$FAKE_KS_OUT_STATE" \
	&& [ "$(head -1 "$FAKE_KS_OUT_STATE")" = 'ct state invalid drop # handle 1' ] \
	&& ok "on installs the killswitch mark accept (match form)" \
	|| bad "on missed the killswitch mark accept or used the set form or displaced the first verdict"

out=$(run status); rc=$?
[ "$rc" -eq 0 ] && has "$out" 'mode=on' && has "$out" 'dns=ok' \
	&& ok "status reports the DNS exit healthy" \
	|| bad "status missed the DNS state"

out=$(run check); rc=$?
[ "$rc" -eq 0 ] && has "$out" 'dns=ok' \
	&& ok "check reports the DNS exit healthy" \
	|| bad "check missed the DNS state"

run off >/dev/null 2>&1
[ "$?" -eq 0 ] \
	&& ! grep -q 'zoro-exit' "$FAKE_SF_PRE_STATE" \
	&& ! grep -q 'zoro-exit' "$FAKE_SF_OUT_STATE" \
	&& ! grep -q 'zoro-exit' "$FAKE_KS_OUT_STATE" \
	&& ! grep -q 'zoro-exit' "$STATE" \
	&& ok "off removes the DNS rules with the rest" \
	|| bad "off left zoro rules behind"

reset_state
: > "$FAKE_KS_OUT_STATE"
out=$(run on 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'DNS exit rules' \
	&& ok "a missing killswitch anchor refuses the switch" \
	|| bad "a missing anchor did not stop the switch rc=$rc"

reset_state
: > "$FAKE_SF_OUT_STATE"
out=$(run on 2>&1); rc=$?
[ "$rc" -eq 1 ] \
	&& ok "a missing output anchor refuses the switch" \
	|| bad "a missing output anchor did not stop the switch rc=$rc"

reset_state
run on >/dev/null 2>&1
sed -i 's/tproxy ip to :7895/tproxy ip to :9999/' "$FAKE_SF_PRE_STATE"
out=$(run status 2>&1)
has "$out" 'dns=missing' \
	&& ok "status sees a tampered tproxy port" \
	|| bad "status missed a tampered tproxy port"

reset_state

# --- the check exit code sees a vanished DNS exit ---
reset_state
run on >/dev/null 2>&1
sed -i '/zoro-exit/d' "$FAKE_KS_OUT_STATE"
out=$(FAKE_DNS_RC=0 run check); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'dns=missing' \
	&& ok "check fails when the DNS exit vanishes" \
	|| bad "check stayed green without the DNS exit"

# --- the UDP DNS probe gates check ---
reset_state
run on >/dev/null 2>&1
out=$(FAKE_DNS_RC=1 run check); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'probe=fail' \
	&& ok "a dead DNS path fails the check" \
	|| bad "check ignored the DNS probe"

# --- a refused switch leaves no DNS residue ---
reset_state
: > "$FAKE_KS_OUT_STATE"
run on >/dev/null 2>&1
! grep -q 'zoro-exit' "$FAKE_SF_PRE_STATE" \
	&& ! grep -q 'zoro-exit' "$FAKE_SF_OUT_STATE" \
	&& ! grep -q 'zoro-exit' "$FAKE_KS_OUT_STATE" \
	&& ok "a refused switch leaves no DNS residue" \
	|| bad "a refused switch left DNS residue behind"

reset_state
: > "$FAKE_SF_OUT_STATE"
run on >/dev/null 2>&1
! grep -q 'zoro-exit' "$FAKE_SF_PRE_STATE" \
	&& ! grep -q 'zoro-exit' "$FAKE_SF_OUT_STATE" \
	&& ok "an output-anchor refusal leaves no prerouting residue" \
	|| bad "an output-anchor refusal left residue behind"

reset_state

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ] && [ "$pass" -eq 54 ]
