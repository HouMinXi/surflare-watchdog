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
case " $* " in
	*" list table inet sw_lan_tproxy "*)
		exit "${FAKE_NFT_TABLE_RC:-0}"
		;;
	*" list chain inet sw_lan_tproxy prerouting "*)
		rc=${FAKE_NFT_CHAIN_RC:-0}
		[ "$rc" -eq 0 ] || exit "$rc"
		while IFS= read -r line; do
			case " $* " in
			*" -a "*|*" --handle "*) printf '%s\n' "$line" ;;
			*) printf '%s\n' "${line%% # handle*}" ;;
			esac
		done < "${FAKE_NFT_STATE:?}"
		exit 0
		;;
	*" add rule "*)
		[ "${FAKE_NFT_INSERT_RC:-0}" = 0 ] || exit 1
		printf '%s\n' "$*" >> "${FAKE_INSERT_LOG:?}"
		printf 'nft %s\n' "$*" >> "${FAKE_MUTATION_LOG:?}"
		line=${*#*prerouting }
		line=$(printf '%s' "$line" | sed 's/ iifname \([^ ]*\)/ iifname "\1"/; s/ comment \([^ ]*\)$/ comment "\1"/')
		printf '%s\n' "$(cat "${FAKE_NFT_STATE:?}")" > "${FAKE_NFT_STATE}.new"
		printf '%s # handle 37\n' "$line" >> "${FAKE_NFT_STATE}.new"
		mv "${FAKE_NFT_STATE}.new" "$FAKE_NFT_STATE"
		exit 0
		;;
	*" insert rule "*)
		[ "${FAKE_NFT_INSERT_RC:-0}" = 0 ] || exit 1
		printf '%s\n' "$*" >> "${FAKE_INSERT_LOG:?}"
		printf 'nft %s\n' "$*" >> "${FAKE_MUTATION_LOG:?}"
		line=${*#*prerouting }
		case "$line" in
		position\ *) line=${line#position }; line=${line# } ;;
		esac
		line=$(printf '%s' "$line" | sed 's/ iifname \([^ ]*\)/ iifname "\1"/; s/ comment \([^ ]*\)$/ comment "\1"/')
		# shellcheck disable=SC2086  # deliberate positional scan
		pos=""; prev=""
		for arg in "$@"; do
			[ "$prev" = position ] && pos=$arg
			prev=$arg
		done
		ln=""
		[ -n "$pos" ] && ln=$(grep -n "# handle $pos\$" "${FAKE_NFT_STATE:?}" | head -1 | cut -d: -f1)
		if [ -n "$ln" ]; then
			head -n "$((ln - 1))" "${FAKE_NFT_STATE}" > "${FAKE_NFT_STATE}.new"
			printf '%s # handle 37\n' "$line" >> "${FAKE_NFT_STATE}.new"
			tail -n "+$ln" "${FAKE_NFT_STATE}" >> "${FAKE_NFT_STATE}.new"
		else
			printf '%s # handle 37\n' "$line" > "${FAKE_NFT_STATE}.new"
			cat "${FAKE_NFT_STATE:?}" >> "${FAKE_NFT_STATE}.new"
		fi
		mv "${FAKE_NFT_STATE}.new" "$FAKE_NFT_STATE"
		exit 0
		;;
	*" delete rule "*)
		printf 'nft %s\n' "$*" >> "${FAKE_MUTATION_LOG:?}"
		handle=""
		for arg in "$@"; do
			if [ "$handle" = next ]; then
				handle=$arg
				break
			fi
			[ "$arg" = handle ] && handle=next
		done
		[ -n "$handle" ] && [ "$handle" != next ] || exit 1
		grep -v "# handle ${handle}$" "${FAKE_NFT_STATE:?}" > "${FAKE_NFT_STATE}.rem"
		mv "${FAKE_NFT_STATE}.rem" "$FAKE_NFT_STATE"
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
export ZORO_SERVICE="$BIN/service" ZORO_PROBE_URL="https://probe.invalid/generate_204" ZORO_STATE_FILE="$TMP/requested" ZORO_CONFIG="$TMP/xray.json"
export FAKE_NFT_STATE="$STATE" FAKE_IPDIR="$IPDIR" FAKE_LISTEN_FLAG="$TMP/listening"
export FAKE_MUTATION_LOG="$MUT" FAKE_CURL_LOG="$CURL_LOG" FAKE_SERVICE_LOG="$SERVICE_LOG"
export FAKE_INSERT_LOG="$TMP/insert.log"

pass=0
fail=0
ok() { printf 'PASS %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }
has() { printf '%s\n' "$1" | grep -q "^$2$"; }

reset_state() {
	rm -f "$TMP/requested"
	printf 'iifname "br-lan" meta nfproto ipv4 meta l4proto tcp tproxy ip to :10800 meta mark set 0x00000001 ct mark set 0x00000100 accept # handle 38\n' > "$STATE"
	rm -f "$IPDIR/rule" "$IPDIR/route"
	: > "$MUT"; : > "$CURL_LOG"; : > "$SERVICE_LOG"; : > "$FAKE_INSERT_LOG"
}

add_zoro() {
	printf 'iifname "br-lan" meta nfproto ipv4 meta l4proto tcp tproxy ip to :7895 meta mark set 0x00000002 ct mark set 0x00000200 accept comment "zoro-exit" # handle 37\n' > "$STATE.new"
	cat "$STATE" >> "$STATE.new"
	mv "$STATE.new" "$STATE"
}

run() {
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

reset_state; add_zoro; : > "$IPDIR/rule"; : > "$IPDIR/route"
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
grep -q 'comment "zoro-exit"' "$STATE" && [ "$rc" -eq 0 ] && ! grep -q 'position' "$FAKE_INSERT_LOG"
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

reset_state; add_zoro; : > "$IPDIR/rule"; : > "$IPDIR/route"; sed -i '/:10800/d' "$STATE"
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
if [ "$(grep -c 'comment "zoro-exit"' "$STATE")" -eq 1 ] && [ "$rc" -eq 0 ] && [ "$(wc -l < "$FAKE_INSERT_LOG")" -eq 1 ]; then
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

reset_state; add_zoro; : > "$IPDIR/rule"; : > "$IPDIR/route"
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

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ] && [ "$pass" -eq 38 ]
