#!/bin/bash
# shellcheck disable=SC2034
# Regression test for proxy log monitor lifecycle and logger rate limiting.
# Production functions are extracted and sourced below; shellcheck cannot
# observe their reads of these test-controlled globals.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

WATCHDOG=${WATCHDOG_UNDER_TEST:-surflare_watchdog.sh}
WORK=$(mktemp -d /tmp/proxy-log-monitor-test.XXXXXX)
FUNCS="$WORK/monitor-functions.sh"
PASS=0
FAIL=0
ROUND_PIDS=""
MONITOR_PIDS=""
USR1_COUNT=0

ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

cleanup_pids() {
    local p
    for p in $ROUND_PIDS $MONITOR_PIDS; do
        case "$p" in ''|*[!0-9]*) continue ;; esac
        kill -9 "$p" 2>/dev/null || true
    done
    ROUND_PIDS=""
    MONITOR_PIDS=""
}
cleanup() {
    cleanup_pids
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'USR1_COUNT=$((USR1_COUNT + 1))' USR1

extract_function() {
    local name="$1"
    awk -v name="$name" '
        index($0, name "() {") == 1 { active=1 }
        active { print }
        active && /^}$/ { exit }
    ' "$WATCHDOG"
}

extract_function _start_proxy_log_monitor > "$FUNCS"
extract_function _stop_proxy_log_monitor >> "$FUNCS"
if ! grep -q '^_start_proxy_log_monitor() {' "$FUNCS" ||
   ! grep -q '^_stop_proxy_log_monitor() {' "$FUNCS"; then
    echo "FAIL: unable to extract production monitor functions"
    exit 1
fi
# Extraction completeness: each function body must end with a top-level
# closing brace and must NOT bleed into its successor.  A renamed or
# re-indented function signature would otherwise extract garbage that
# still contains the header line above and pass vacuously.
if [ "$(grep -c '^}' "$FUNCS")" -ne 2 ] ||
   grep -q '_stop_proxy_log_monitor() {' \
       <(awk '/^_start_proxy_log_monitor\(\)/,/^}/' "$WATCHDOG"); then
    echo "FAIL: monitor extraction incomplete (bleed or missing close)"
    exit 1
fi
{
    # Test override: 2s vs 1s production.  The blocking-logger ceiling uses
    # this exact value, so a production bump to 2s is NOT caught by the
    # runtime assertion -- the static guard below pins the production
    # default separately, and the sanity check right after asserts the
    # override stays distinct so that guard remains meaningful.
    printf 'AUTH_EXPIRED_FILE="%s"\n' "$WORK/auth-expired"
    printf 'PROXY_LOG_LOGGER_TIMEOUT=2\n'
    cat "$FUNCS"
} > "$FUNCS.tmp" && mv "$FUNCS.tmp" "$FUNCS"
# shellcheck source=/dev/null
source "$FUNCS"
# Override must stay distinct from the production default, else the static
# guard pinning production's 1s becomes vacuous (a bump would pass unseen).
# POSIX-safe extraction (no grep -P): cut after the last '='.
_prod_timeout=$(grep '^PROXY_LOG_LOGGER_TIMEOUT=' "$WATCHDOG" | head -1 | awk -F= '{print $NF}')
# An anchored grep that finds nothing means the production default was
# renamed or removed -- fail loud rather than compare against "".
if [ -z "$_prod_timeout" ]; then
    echo "FAIL: production PROXY_LOG_LOGGER_TIMEOUT assignment not found"
    exit 1
fi
if [ "$PROXY_LOG_LOGGER_TIMEOUT" = "$_prod_timeout" ]; then
    echo "FAIL: test override must differ from production default (guard vacuity)"
    exit 1
fi

collect_tree() {
    local found=" $1 " changed=1 p ppid
    while [ "$changed" -eq 1 ]; do
        changed=0
        for p in /proc/[0-9]*; do
            p=${p##*/}
            case "$found" in *" $p "*) continue ;; esac
            ppid=$(awk '/^PPid:/{print $2}' "/proc/$p/status" 2>/dev/null || true)
            case "$found" in
                *" $ppid "*) found="$found$p "; changed=1 ;;
            esac
        done
    done
    printf '%s\n' "$found" | xargs
}

wait_for_count() {
    local want="$1" tries=0 got=0
    while [ "$tries" -lt 80 ]; do
        got=$(awk '{print $1}' "$PROXY_ERR_STATE" 2>/dev/null || echo 0)
        [ "$got" -ge "$want" ] 2>/dev/null && return 0
        sleep 0.1
        tries=$((tries + 1))
    done
    return 1
}

wait_for_tail_ready() {
    local tries=0 p cmd
    while [ "$tries" -lt 50 ]; do
        for p in $(collect_tree "$_proxy_log_pid"); do
            [ -r "/proc/$p/cmdline" ] || continue
            cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)
            case "$cmd" in
                *"tail -n 0 -F $PROXY_LOG"*) return 0 ;;
            esac
        done
        sleep 0.1
        tries=$((tries + 1))
    done
    return 1
}

wait_tree_gone() {
    local tries=0 p leftover
    while [ "$tries" -lt 50 ]; do
        leftover=""
        for p in $ROUND_PIDS; do
            case "$p" in ''|*[!0-9]*) continue ;; esac
            [ -d "/proc/$p" ] || continue
            leftover=1
            break
        done
        [ -z "$leftover" ] && return 0
        sleep 0.1
        tries=$((tries + 1))
    done
    return 1
}

# Explicit tree-reap verification: snapshot the tree rooted at $1, stop the
# monitor, wait, assert.  Self-contained -- never reads a stale global set
# by an earlier section (a prior review flagged that hazard).
stop_and_assert_tree_gone() {
    local label="$1" root="$2"
    ROUND_PIDS=$(collect_tree "$root")
    MONITOR_PIDS="$MONITOR_PIDS $ROUND_PIDS"
    _stop_proxy_log_monitor
    wait_tree_gone || true
    assert_tree_gone "$label"
}

wait_for_logger_count() {
    local want="$1" tries=0 got=0
    while [ "$tries" -lt 80 ]; do
        got=$(wc -l < "$PROXY_TEST_LOGGER")
        [ "$got" -ge "$want" ] 2>/dev/null && return 0
        sleep 0.1
        tries=$((tries + 1))
    done
    return 1
}

wait_file_gone() {
    local f="$1" tries=0
    while [ "$tries" -lt 80 ]; do
        [ ! -f "$f" ] && return 0
        sleep 0.1
        tries=$((tries + 1))
    done
    return 1
}

wait_file_exists() {
    local f="$1" tries=0
    while [ "$tries" -lt 80 ]; do
        [ -f "$f" ] && return 0
        sleep 0.1
        tries=$((tries + 1))
    done
    return 1
}

wait_for_storm() {
    local want="$1" tries=0 got=0
    while [ "$tries" -lt 80 ]; do
        got=$(awk '{print $1}' "$STORM_503_STATE" 2>/dev/null || echo 0)
        [ "$got" -ge "$want" ] 2>/dev/null && return 0
        sleep 0.1
        tries=$((tries + 1))
    done
    return 1
}

wait_for_usr1_count() {
    local want="$1" tries=0
    while [ "$tries" -lt 80 ]; do
        [ "$USR1_COUNT" -ge "$want" ] && return 0
        sleep 0.1
        tries=$((tries + 1))
    done
    return 1
}

assert_tree_gone() {
    local label="$1" p survivors=""
    for p in $ROUND_PIDS; do
        [ -d "/proc/$p" ] || continue
        survivors="$survivors $p"
        echo "  survivor pid=$p ppid=$(awk '/^PPid:/{print $2}' "/proc/$p/status" 2>/dev/null) fd0=$(readlink "/proc/$p/fd/0" 2>/dev/null) cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
    done
    if [ -z "$survivors" ]; then
        ok "$label: monitor process tree reaped"
    else
        bad "$label: monitor process tree leaked:$survivors"
    fi
}

# Unique PATH stubs for logger/date must exist before any monitor start.
# Keep the real sleep so a blocking rate-limit sleep still leaks.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/date" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "+%s" ]; then
    cat "$PROXY_TEST_CLOCK"
else
    exec /usr/bin/date "$@"
fi
STUB
cat > "$WORK/bin/logger" <<'STUB'
#!/bin/bash
fail_file="${PROXY_TEST_LOGGER_FAIL:-}"
if [ -n "$fail_file" ] && [ -f "$fail_file" ]; then
    rm -f "$fail_file"
    exit 1
fi
block_file="${PROXY_TEST_LOGGER_BLOCK:-}"
if [ -n "$block_file" ] && [ -f "$block_file" ]; then
    rm -f "$block_file"
    sleep 12
fi
printf '%s\n' "$*" >> "$PROXY_TEST_LOGGER"
STUB
cat > "$WORK/bin/timeout" <<'STUB'
#!/bin/bash
exec /usr/bin/timeout "$@"
STUB
chmod 700 "$WORK/bin/date" "$WORK/bin/logger" "$WORK/bin/timeout"
export PROXY_TEST_CLOCK="$WORK/clock"
export PROXY_TEST_LOGGER="$WORK/logger"
export PROXY_TEST_LOGGER_FAIL="$WORK/logger-fail-once"
export PROXY_TEST_LOGGER_BLOCK="$WORK/logger-block"
: > "$PROXY_TEST_LOGGER"
printf '1000\n' > "$PROXY_TEST_CLOCK"
ORIGINAL_PATH=$PATH
PATH="$WORK/bin:$PATH"
export PATH
case "$(command -v logger)" in
    "$WORK"/bin/logger) ;;
    *) echo "FAIL: logger is not the unique test stub ($(command -v logger))"; exit 1 ;;
esac
case "$(command -v date)" in
    "$WORK"/bin/date) ;;
    *) echo "FAIL: date is not the unique test stub ($(command -v date))"; exit 1 ;;
esac
case "$(command -v timeout)" in
    "$WORK"/bin/timeout) ;;
    *) echo "FAIL: timeout is not the unique test stub ($(command -v timeout))"; exit 1 ;;
esac

run_lifecycle_round() {
    local round="$1" i
    PROXY_LOG="$WORK/proxy-$round.log"
    PROXY_ERR_STATE="$WORK/errors-$round"
    STORM_503_STATE="$WORK/503-$round"
    PROXY_LOG_RATE_SEC=60
    PROXY_ERR_THRESHOLD=1000
    AUTH_EXPIRED_FILE="$WORK/auth-$round"
    : > "$PROXY_LOG"
    : > "$PROXY_TEST_LOGGER"
    rm -f "$AUTH_EXPIRED_FILE"
    _proxy_log_pid=""

    _start_proxy_log_monitor
    MONITOR_PIDS="$MONITOR_PIDS $_proxy_log_pid"
    if ! wait_for_tail_ready; then
        bad "round $round: monitor tail did not become ready"
        _stop_proxy_log_monitor
        cleanup_pids
        return
    fi
    ok "round $round: monitor tail ready"
    for i in $(seq 1 30); do
        printf '+0000 test ERROR lifecycle-%s-%02d\n' "$round" "$i"
    done >> "$PROXY_LOG"
    if ! wait_for_count 1; then
        bad "round $round: monitor did not count first error"
        _stop_proxy_log_monitor
        cleanup_pids
        return
    fi
    stop_and_assert_tree_gone "round $round" "$_proxy_log_pid"
    cleanup_pids
}

for round in 1 2 3; do
    run_lifecycle_round "$round"
done

if [ "${1:-}" = "--lifecycle-only" ]; then
    echo "RESULT: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ]
    exit
fi

PROXY_LOG="$WORK/behavior.log"
PROXY_ERR_STATE="$WORK/behavior-errors"
STORM_503_STATE="$WORK/behavior-503"
PROXY_LOG_RATE_SEC=60
PROXY_ERR_THRESHOLD=10
AUTH_EXPIRED_FILE="$WORK/auth-expired"
: > "$PROXY_LOG"
: > "$PROXY_TEST_LOGGER"
rm -f "$AUTH_EXPIRED_FILE"
printf '1000\n' > "$PROXY_TEST_CLOCK"
_proxy_log_pid=""
_start_proxy_log_monitor
MONITOR_PIDS="$MONITOR_PIDS $_proxy_log_pid"
_behavior_ready=1
USR1_COUNT=0
if ! wait_for_tail_ready; then
    bad "behavior: monitor tail did not become ready"
    _behavior_ready=0
else
    ok "behavior: monitor tail ready"
fi
if [ "$_behavior_ready" -eq 1 ]; then
for i in $(seq 1 30); do
    printf '+0000 test ERROR behavior-%02d\n' "$i"
done >> "$PROXY_LOG"
if wait_for_count 30; then
    ok "counter: 30 generic errors consumed without logger delay"
else
    bad "counter: expected 30 generic errors promptly"
fi
if wait_for_usr1_count 3 && [ "$USR1_COUNT" -eq 3 ]; then
    ok "counter: USR1 fired at generic thresholds 10/20/30"
else
    bad "counter: expected 3 generic USR1 signals, got $USR1_COUNT"
fi
calls=$(wc -l < "$PROXY_TEST_LOGGER")
if [ "$calls" -eq 1 ]; then
    ok "rate: fixed window emits one logger line"
else
    bad "rate: fixed window emitted $calls logger lines"
fi

printf '1060\n' > "$PROXY_TEST_CLOCK"
printf '+0000 test ERROR boundary\n' >> "$PROXY_LOG"
wait_for_count 31 || true
calls=$(wc -l < "$PROXY_TEST_LOGGER")
if [ "$calls" -eq 2 ]; then
    ok "rate: diff equal to limit emits"
else
    bad "rate: boundary expected 2 logger calls, got $calls"
fi

printf '900\n' > "$PROXY_TEST_CLOCK"
printf '+0000 test ERROR rollback\n' >> "$PROXY_LOG"
wait_for_count 32 || true
calls=$(wc -l < "$PROXY_TEST_LOGGER")
if [ "$calls" -eq 2 ]; then
    ok "rate: clock rollback rebases silently (no extra emission)"
else
    bad "rate: rollback expected 2 logger calls, got $calls"
fi
printf '+0000 test ERROR post-rollback\n' >> "$PROXY_LOG"
wait_for_count 33 || true
calls=$(wc -l < "$PROXY_TEST_LOGGER")
if [ "$calls" -eq 2 ]; then
    ok "rate: post-rollback window suppresses until next window"
else
    bad "rate: post-rollback expected 2 logger calls, got $calls"
fi
# NTP jitter oscillation: repeated small backwards steps must not emit.
for i in 1 2 3 4 5; do
    printf '895\n' > "$PROXY_TEST_CLOCK"
    printf '+0000 test ERROR jitter-%s\n' "$i" >> "$PROXY_LOG"
done
wait_for_count 38 || true
calls=$(wc -l < "$PROXY_TEST_LOGGER")
if [ "$calls" -eq 2 ]; then
    ok "rate: jitter oscillation stays silent"
else
    bad "rate: jitter produced $calls logger calls (expected 2)"
fi
printf '960\n' > "$PROXY_TEST_CLOCK"
: > "$PROXY_TEST_LOGGER_FAIL"
printf '+0000 test ERROR logger-fail-1\n' >> "$PROXY_LOG"
wait_for_count 39 || true
if wait_file_gone "$PROXY_TEST_LOGGER_FAIL"; then
    ok "logger-fail: first attempt invoked logger"
else
    bad "logger-fail: first attempt did not invoke logger"
fi
calls=$(wc -l < "$PROXY_TEST_LOGGER")
if [ "$calls" -eq 2 ]; then
    ok "logger-fail: failed attempt did not record success"
else
    bad "logger-fail: expected 2 logger lines after failure, got $calls"
fi
printf '+0000 test ERROR logger-fail-2\n' >> "$PROXY_LOG"
wait_for_count 40 || true
sleep 0.3
calls=$(wc -l < "$PROXY_TEST_LOGGER")
if [ "$calls" -eq 2 ]; then
    ok "logger-fail: same-window retry is suppressed"
else
    bad "logger-fail: same-window failure retried, logger lines=$calls"
fi
printf '1020\n' > "$PROXY_TEST_CLOCK"
printf '+0000 test ERROR logger-fail-3\n' >> "$PROXY_LOG"
wait_for_count 41 || true
if wait_for_logger_count 3; then
    ok "logger-fail: next window retries and succeeds"
else
    calls=$(wc -l < "$PROXY_TEST_LOGGER")
    bad "logger-fail: next-window retry expected 3 calls, got $calls"
fi

# Blocking logger must not stall the reader past PROXY_LOG_LOGGER_TIMEOUT.
# Queue a second line: it cannot reach the counter until the first logger call
# returns or timeout kills it. Use a fresh attempt window after 1020.
printf '1080\n' > "$PROXY_TEST_CLOCK"
: > "$PROXY_TEST_LOGGER_BLOCK"
block_start=$(/usr/bin/date +%s)
printf '+0000 test ERROR logger-block-1\n' >> "$PROXY_LOG"
printf '+0000 test ERROR logger-block-2\n' >> "$PROXY_LOG"
if wait_for_count 43; then
    block_elapsed=$(( $(/usr/bin/date +%s) - block_start ))
    if [ "$block_elapsed" -le $((PROXY_LOG_LOGGER_TIMEOUT + 4)) ]; then
        ok "logger-block: reader resumed within timeout slack (${block_elapsed}s)"
    else
        bad "logger-block: reader elapsed ${block_elapsed}s (limit=$((PROXY_LOG_LOGGER_TIMEOUT + 4))s)"
    fi
    ok "logger-block: same-window second error consumed after timeout"
else
    block_elapsed=$(( $(/usr/bin/date +%s) - block_start ))
    bad "logger-block: reader did not resume within timeout (${block_elapsed}s)"
fi
if [ ! -f "$PROXY_TEST_LOGGER_BLOCK" ]; then
    ok "logger-block: blocking logger attempt was exercised"
else
    bad "logger-block: blocking logger stub was not invoked"
fi
calls=$(wc -l < "$PROXY_TEST_LOGGER")
if [ "$calls" -eq 3 ]; then
    ok "logger-block: timed-out attempt and same-window line emitted nothing"
else
    bad "logger-block: expected 3 logger lines after timeout window, got $calls"
fi
printf '1140\n' > "$PROXY_TEST_CLOCK"
printf '+0000 test ERROR logger-block-3\n' >> "$PROXY_LOG"
wait_for_count 44 || true
if wait_for_logger_count 4; then
    ok "logger-block: next window retries and succeeds"
else
    calls=$(wc -l < "$PROXY_TEST_LOGGER")
    bad "logger-block: next-window retry expected 4 calls, got $calls"
fi

# Coupled branches: 503 storm + auth-expired. Use test-local AUTH_EXPIRED_FILE.
generic_before=$(awk '{print $1}' "$PROXY_ERR_STATE" 2>/dev/null || echo 0)
logger_before=$(wc -l < "$PROXY_TEST_LOGGER")
usr1_before=$USR1_COUNT
for i in 1 2 3 4 5; do
    printf '+0000 urltest ERROR 503 storm-%s\n' "$i"
done >> "$PROXY_LOG"
if wait_for_storm 5; then
    storm=$(cat "$STORM_503_STATE")
    # Word-split storm "count first last" on purpose.
    # shellcheck disable=SC2086
    set -- $storm
    if [ "$1" -eq 5 ] && [ -n "$2" ] && [ -n "$3" ]; then
        ok "503: storm state is 5 first last"
    else
        bad "503: storm state expected '5 first last', got '$storm'"
    fi
else
    bad "503: storm count did not reach 5"
fi
generic_after=$(awk '{print $1}' "$PROXY_ERR_STATE" 2>/dev/null || echo 0)
if [ "$generic_after" -eq "$generic_before" ]; then
    ok "503: generic error counter unchanged"
else
    bad "503: generic counter $generic_before -> $generic_after"
fi
if grep -q '503 storm:' "$PROXY_TEST_LOGGER"; then
    ok "503: fifth event emitted storm logger line"
else
    bad "503: missing storm logger line"
fi
logger_after=$(wc -l < "$PROXY_TEST_LOGGER")
if [ "$logger_after" -eq $((logger_before + 1)) ]; then
    ok "503: generic logger gate not used by storm lines"
else
    bad "503: unexpected extra logger lines ($logger_before -> $logger_after)"
fi
if wait_for_usr1_count $((usr1_before + 1)); then
    sleep 0.2
    if [ "$USR1_COUNT" -eq $((usr1_before + 1)) ]; then
        ok "503: fifth event sent exactly one USR1"
    else
        bad "503: expected one USR1, got $((USR1_COUNT - usr1_before))"
    fi
else
    bad "503: fifth event did not send USR1"
fi

rm -f "$AUTH_EXPIRED_FILE"
usr1_before=$USR1_COUNT
generic_before=$(awk '{print $1}' "$PROXY_ERR_STATE" 2>/dev/null || echo 0)
printf '+0000 ERROR authentication required first\n' >> "$PROXY_LOG"
if wait_file_exists "$AUTH_EXPIRED_FILE"; then
    ok "auth: first event created marker"
else
    bad "auth: marker not created"
fi
if wait_for_usr1_count $((usr1_before + 1)); then
    ok "auth: first marker creation sent USR1"
else
    bad "auth: first event did not send USR1"
fi
usr1_after_first=$USR1_COUNT
printf '+0000 ERROR authentication required second\n' >> "$PROXY_LOG"
sleep 0.4
if [ "$USR1_COUNT" -eq "$usr1_after_first" ]; then
    ok "auth: existing marker suppressed duplicate USR1"
else
    bad "auth: second event sent duplicate USR1"
fi
generic_after=$(awk '{print $1}' "$PROXY_ERR_STATE" 2>/dev/null || echo 0)
if [ "$generic_after" -eq "$generic_before" ]; then
    ok "auth: generic error counter unchanged"
else
    bad "auth: generic counter $generic_before -> $generic_after"
fi
if [ -f "$AUTH_EXPIRED_FILE" ]; then
    ok "auth: marker remains after second event"
else
    bad "auth: marker disappeared"
fi
fi

stop_and_assert_tree_gone "behavior" "$_proxy_log_pid"
cleanup_pids
PATH=$ORIGINAL_PATH

# Static source guards make bug injection failures immediate and specific.
# Ignore comment-only lines, then collapse all whitespace so a coherent
# statement can be matched across the original indentation/newlines.
_norm=$(awk '!/^[[:blank:]]*#/' "$FUNCS" | tr -s '[:space:]' ' ')
# shellcheck disable=SC2016  # Match literal production variable references.
if echo "$_norm" | grep -q 'sleep "$PROXY_LOG_RATE_SEC"'; then
    bad "source: blocking monitor sleep remains"
else
    ok "source: monitor loop has no blocking rate-limit sleep"
fi
# shellcheck disable=SC2016  # Match literal production variable references.
if echo "$_norm" | grep -q '_last_proxy_log_emit' &&
   echo "$_norm" | grep -q '"$_diff" -lt 0' &&
   echo "$_norm" | grep -q '"$_diff" -ge "$PROXY_LOG_RATE_SEC"'; then
    ok "source: rollback-safe timestamp gate present"
else
    bad "source: rollback-safe timestamp gate missing"
fi
# shellcheck disable=SC2016  # Match literal production variable references.
# Guards below fail-closed: pattern absence is a FAIL, not a vacuous pass.
if echo "$_norm" | grep -q '_last_proxy_log_emit=$_now timeout "$PROXY_LOG_LOGGER_TIMEOUT" logger -t surflare-proxy "$_line"'; then
    ok "source: logger attempt advances one-attempt-per-window timestamp"
else
    bad "source: logger attempt window is not guarded coherently"
fi
# All three AUTH_EXPIRED_FILE consumers must use the variable: monitor,
# connect_vpn, main loop.  A hardcoded /run path at any site breaks the
# test-local marker override invisibly.
# shellcheck disable=SC2016  # literal production variable reference
_auth_sites=$(grep -c '"$AUTH_EXPIRED_FILE"' "$WATCHDOG")
if [ "$_auth_sites" -ge 3 ]; then
    ok "source: all AUTH_EXPIRED_FILE call sites use the variable"
else
    bad "source: expected >=3 AUTH_EXPIRED_FILE consumers, found ${_auth_sites:-0}"
fi
if echo "$_norm" | grep -q 'AUTH_EXPIRED_FILE="/run/surflare_auth_expired"'; then
    bad "source: extracted monitor still pins /run auth marker"
else
    ok "source: extracted monitor uses test auth marker"
fi
# The guard above reads FUNCS which has the override PREPENDED -- a
# hardcoded /run literal inside the extracted monitor body would still be
# caught by it, but a hardcoded literal in the PRODUCTION assignment (line
# 603, outside the extracted range) would not.  Pin the production
# assignment's value to the variable form explicitly:
# shellcheck disable=SC2016
if grep -q '^AUTH_EXPIRED_FILE="/run/surflare_auth_expired"$' "$WATCHDOG"; then
    ok "source: production AUTH_EXPIRED_FILE assignment pins the /run path"
else
    bad "source: production AUTH_EXPIRED_FILE assignment changed"
fi
# shellcheck disable=SC2016
if grep -q 'AUTH_EXPIRED_FILE="${AUTH_EXPIRED_FILE:-' "$WATCHDOG"; then
    bad "source: production AUTH_EXPIRED_FILE still accepts env override"
else
    ok "source: production AUTH_EXPIRED_FILE is a fixed /run path"
fi
# shellcheck disable=SC2016
# Anchor the timeout guard to the rate-limit context so removing the
# timeout from the 503-storm path alone is still caught: both call sites
# must carry the bounded logger.
_timeout_sites=$(grep -c 'timeout "$PROXY_LOG_LOGGER_TIMEOUT" logger -t surflare-proxy' "$WATCHDOG")
if [ "$_timeout_sites" -ge 2 ]; then
    ok "source: production logger bounded by timeout (generic + 503 paths)"
else
    bad "source: expected 2 bounded logger sites, found ${_timeout_sites:-0}"
fi
# shellcheck disable=SC2016
# Production default must stay 1s: the runtime test overrides it to 2s,
# so only this static guard catches a production bump that would double
# the worst-case per-ERROR stall.
if grep -q '^PROXY_LOG_LOGGER_TIMEOUT=1$' "$WATCHDOG"; then
    ok "source: production logger timeout default is 1s"
else
    bad "source: production PROXY_LOG_LOGGER_TIMEOUT default changed"
fi
# shellcheck disable=SC2016
if echo "$_norm" | grep -q 'kill -USR1'; then
    ok "source: monitor still signals USR1 from 503/auth/generic paths"
else
    bad "source: USR1 signal missing from extracted monitor"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
