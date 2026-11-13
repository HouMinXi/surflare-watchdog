#!/bin/bash
# Behavioral tests for scripts/zoro-quota-alert.sh. The vnstat and curl
# binaries are stubbed; python3 stays real because the script's JSON parsing
# is part of what is being tested.
set -u
cd "$(dirname "$0")/.." || exit 1
SCRIPT="$PWD/scripts/zoro-quota-alert.sh"
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"

cat > "$TMP/bin/vnstat" <<'EOF'
#!/bin/bash
# fake: emit one month record; VNSTAT_BYTES is the rx+tx total
printf '%s\n' "$*" >> "$TMP/vnstat.args"
case ${VNSTAT_MODE:-ok} in
empty)   exit 0 ;;
nomonth) printf '{"interfaces":[{"traffic":{"month":[]}}]}'; exit 0 ;;
garbage) printf 'not json'; exit 0 ;;
esac
_total=${VNSTAT_BYTES:-0}
_rx=${VNSTAT_RX:-$((_total * 4 / 5))}
_tx=${VNSTAT_TX:-$((_total - _rx))}
printf '{"interfaces":[{"traffic":{"month":[{"date":{"year":%s,"month":%s},"rx":%s,"tx":%s}]}}]}' \
	"${VNSTAT_YEAR:-2026}" "${VNSTAT_MONTH:-11}" "$_rx" "$_tx"
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TMP/curl.args"
echo "${CURL_CODE:-200}"
exit "${CURL_RC:-0}"
EOF
chmod +x "$TMP/bin/vnstat" "$TMP/bin/curl"

export TMP
export ZORO_QUOTA_CONF="$TMP/quota.conf"
export ZORO_QUOTA_STATE_DIR="$TMP/state"
export ZORO_QUOTA_LOG="$TMP/alert.log"
export VNSTAT_BYTES=0
export PATH="$TMP/bin:/usr/local/bin:/usr/bin:/bin"

# --- missing config: silent success ---
rm -f "$ZORO_QUOTA_CONF"
bash "$SCRIPT"; rc=$?
[ "$rc" -eq 0 ] && grep -q "no $ZORO_QUOTA_CONF" "$TMP/alert.log" \
	&& ok "a missing config only logs" || bad "missing config rc=$rc"

# --- empty quota: silent success ---
printf 'SENDKEY=testkey\nQUOTA_GB=\n' > "$ZORO_QUOTA_CONF"; chmod 600 "$ZORO_QUOTA_CONF"
bash "$SCRIPT" >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "an empty quota is not an error" || bad "empty quota errored"

# --- non-numeric quota: failure ---
printf 'SENDKEY=testkey\nQUOTA_GB=lots\n' > "$ZORO_QUOTA_CONF"; chmod 600 "$ZORO_QUOTA_CONF"
bash "$SCRIPT" >/dev/null 2>&1
[ "$?" -eq 1 ] && ok "a non-numeric quota is refused" || bad "a non-numeric quota passed"

# --- missing key: failure ---
printf 'SENDKEY=\nQUOTA_GB=1000\n' > "$ZORO_QUOTA_CONF"; chmod 600 "$ZORO_QUOTA_CONF"
bash "$SCRIPT" >/dev/null 2>&1
[ "$?" -eq 1 ] && ok "a missing key is refused" || bad "a missing key passed"

printf 'SENDKEY=testkey\nQUOTA_GB=1000\n' > "$ZORO_QUOTA_CONF"; chmod 600 "$ZORO_QUOTA_CONF"

# --- below the ladder: no page ---
VNSTAT_BYTES=$(( 700 * 1000000000 )) bash "$SCRIPT" >/dev/null 2>&1
[ ! -e "$TMP/curl.args" ] && ok "seventy percent sends nothing" \
	|| bad "seventy percent paged"

# --- past 80: one page, stamp records the level ---
VNSTAT_BYTES=$(( 850 * 1000000000 )) bash "$SCRIPT" >/dev/null 2>&1
[ -e "$TMP/curl.args" ] && [ "$(cat "$TMP/state/level-2026-11")" = "80" ] \
	&& grep -q '85' "$TMP/curl.args" && ok "eighty-five percent pages once" \
	|| bad "eighty-five percent did not page once"

# --- a higher level the same day: the daily cap holds ---
VNSTAT_BYTES=$(( 960 * 1000000000 )) bash "$SCRIPT" >/dev/null 2>&1
[ "$(grep -c 'title=' "$TMP/curl.args")" -eq 1 ] \
	&& ok "the daily cap holds a same-day level jump" \
	|| bad "the daily cap let a same-day jump through [$(grep -c 'title=' "$TMP/curl.args")]"

# --- a higher level on a new day: the ladder advances ---
rm -f "$TMP/state"/sent-*
VNSTAT_BYTES=$(( 960 * 1000000000 )) bash "$SCRIPT" >/dev/null 2>&1
[ "$(grep -c 'title=' "$TMP/curl.args")" -eq 2 ] \
	&& [ "$(cat "$TMP/state/level-2026-11")" = "95" ] \
	&& ok "a higher level on a new day pages again" \
	|| bad "the ninety-five percent page never came"

# --- lower level afterwards: no page ---
rm -f "$TMP/state"/sent-*
VNSTAT_BYTES=$(( 900 * 1000000000 )) bash "$SCRIPT" >/dev/null 2>&1
[ "$(grep -c 'title=' "$TMP/curl.args")" -eq 2 ] \
	&& ok "a lower level never pages again" \
	|| bad "a lower level paged again"

# --- new month, same level: pages again ---
rm -f "$TMP/state"/sent-*
VNSTAT_MONTH=12 VNSTAT_BYTES=$(( 960 * 1000000000 )) bash "$SCRIPT" >/dev/null 2>&1
[ "$(grep -c 'title=' "$TMP/curl.args")" -eq 3 ] \
	&& [ "$(cat "$TMP/state/level-2026-12")" = "95" ] \
	&& ok "a new month restarts the ladder" \
	|| bad "a new month did not restart the ladder"

# --- a failed send never burns the level ---
rm -rf "$TMP/state"; mkdir -p "$TMP/state"; rm -f "$TMP/curl.args"
CURL_RC=28 VNSTAT_BYTES=$(( 850 * 1000000000 )) bash "$SCRIPT" >/dev/null 2>&1
[ "$?" -eq 1 ] && [ ! -e "$TMP/state/level-2026-11" ] \
	&& [ -z "$(ls "$TMP/state"/sent-* 2>/dev/null)" ] \
	&& grep -q 'page failed' "$TMP/alert.log" \
	&& ok "a failed send leaves the state untouched" \
	|| bad "a failed send burned the level"

rm -f "$TMP/curl.args"
VNSTAT_BYTES=$(( 850 * 1000000000 )) bash "$SCRIPT" >/dev/null 2>&1
[ "$(grep -c 'title=' "$TMP/curl.args")" -eq 1 ] \
	&& [ "$(cat "$TMP/state/level-2026-11")" = "80" ] \
	&& ok "the retry after a failure still pages" \
	|| bad "the retry after a failure was lost"

# --- a non-200 answer is also a failure ---
rm -rf "$TMP/state"; mkdir -p "$TMP/state"; rm -f "$TMP/curl.args" "$TMP/alert.log"
CURL_CODE=500 VNSTAT_BYTES=$(( 850 * 1000000000 )) bash "$SCRIPT" >/dev/null 2>&1
[ "$?" -eq 1 ] && [ ! -e "$TMP/state/level-2026-11" ] \
	&& ok "a non-200 answer leaves the state untouched" \
	|| bad "a non-200 answer burned the level"

# --- a silent measurement pipeline is loud ---
rm -f "$TMP/alert.log"
VNSTAT_MODE=empty bash "$SCRIPT" >/dev/null 2>&1
[ "$?" -eq 1 ] && grep -q 'measurement pipeline broken' "$TMP/alert.log" \
	&& ok "an empty pipeline is logged and fails" \
	|| bad "an empty pipeline passed silently"

rm -f "$TMP/alert.log"
VNSTAT_MODE=garbage bash "$SCRIPT" >/dev/null 2>&1
[ "$?" -eq 1 ] && grep -q 'measurement pipeline broken' "$TMP/alert.log" \
	&& ok "garbage output is logged and fails" \
	|| bad "garbage output passed silently"

rm -f "$TMP/alert.log"
VNSTAT_MODE=nomonth bash "$SCRIPT" >/dev/null 2>&1
[ "$?" -eq 0 ] && grep -q 'month record missing' "$TMP/alert.log" \
	&& ok "a missing month record is logged" \
	|| bad "a missing month record passed silently"

# --- quota zero is refused ---
printf 'SENDKEY=testkey\nQUOTA_GB=0\n' > "$ZORO_QUOTA_CONF"; chmod 600 "$ZORO_QUOTA_CONF"
rm -f "$TMP/alert.log"
bash "$SCRIPT" >/dev/null 2>&1
[ "$?" -eq 1 ] && grep -q 'QUOTA_GB is zero' "$TMP/alert.log" \
	&& ok "a zero quota is refused with a record" \
	|| bad "a zero quota reached the division"
printf 'SENDKEY=testkey\nQUOTA_GB=1000\n' > "$ZORO_QUOTA_CONF"; chmod 600 "$ZORO_QUOTA_CONF"

# --- a permissive conf mode is refused ---
printf 'SENDKEY=testkey\nQUOTA_GB=1000\n' > "$ZORO_QUOTA_CONF"; chmod 644 "$ZORO_QUOTA_CONF"
rm -f "$TMP/alert.log"
bash "$SCRIPT" >/dev/null 2>&1
[ "$?" -eq 1 ] && grep -q 'refusing conf mode' "$TMP/alert.log" \
	&& ok "a world-readable conf is refused" \
	|| bad "a world-readable conf was executed"
chmod 600 "$ZORO_QUOTA_CONF"

# --- the exact 100 percent rung fires ---
rm -rf "$TMP/state"; mkdir -p "$TMP/state"; rm -f "$TMP/curl.args"
VNSTAT_BYTES=$(( 1000 * 1000000000 )) bash "$SCRIPT" >/dev/null 2>&1
[ "$(cat "$TMP/state/level-2026-11")" = "100" ] \
	&& ok "the exact quota boundary pages at level 100" \
	|| bad "the exact quota boundary was missed [$(cat "$TMP/state/level-2026-11" 2>/dev/null)]"

# --- the configured interface reaches vnstat ---
rm -rf "$TMP/state"; mkdir -p "$TMP/state"; rm -f "$TMP/vnstat.args" "$TMP/curl.args"
printf 'SENDKEY=testkey\nQUOTA_GB=1000\nIFACE=tailscale0\n' > "$ZORO_QUOTA_CONF"; chmod 600 "$ZORO_QUOTA_CONF"
VNSTAT_BYTES=$(( 850 * 1000000000 )) bash "$SCRIPT" >/dev/null 2>&1
grep -q -- '-i tailscale0' "$TMP/vnstat.args" \
	&& ok "the configured interface reaches the measurement" \
	|| bad "the configured interface was ignored [$(cat "$TMP/vnstat.args" 2>/dev/null)]"
printf 'SENDKEY=testkey\nQUOTA_GB=1000\n' > "$ZORO_QUOTA_CONF"; chmod 600 "$ZORO_QUOTA_CONF"

# --- the page goes to the keyed ServerChan endpoint ---
grep -q 'sctapi.ftqq.com/testkey.send' "$TMP/curl.args" \
	&& grep -q 'title=' "$TMP/curl.args" \
	&& ok "the page carries the key and the title" \
	|| bad "the page shape regressed [$(head -1 "$TMP/curl.args" 2>/dev/null)]"

echo "RESULT: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
