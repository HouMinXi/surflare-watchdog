#!/bin/bash
# Stub-level test for watchdog flap-class stamp throttle.
# The stub mirrors _send_alert in surflare_watchdog.sh (incl. the
# rate-limiter ordering: the limiter advances only after the stamp
# check passes). Real-code extraction verification is done separately
# by the PM harness.

set -eo pipefail

# Use temp directory for testing (real path is /run/surflare which requires root)
STAMP_DIR=$(mktemp -d)
STAMP_FILE="${STAMP_DIR}/alert_flap:test.stamp"
PASS=0
FAIL=0

cleanup() {
    rm -f "$STAMP_FILE" "${STAMP_DIR}"/alert_flap:*.stamp "${STAMP_DIR}"/out1 "${STAMP_DIR}"/out2 2>/dev/null
    rmdir "$STAMP_DIR" 2>/dev/null || true
    exit $((FAIL > 0 ? 1 : 0))
}
trap cleanup EXIT

# Create stamp directory
mkdir -p "$STAMP_DIR" 2>/dev/null || true

# Minimal _send_alert with stamp throttle (mirrors watchdog logic,
# limiter advance AFTER the stamp check)
_deliver_calls=0
_alert_last_ts=0

_send_alert_test() {
    local _title="${1:-surflare alert}"
    local _class="${4:-}"

    local _now _last
    _now=$(date +%s)
    _last=${_alert_last_ts:-0}
    local _diff=$((_now - _last))
    if [ "$_diff" -ge 0 ] && [ "$_diff" -lt 600 ]; then
        echo "RATE_LIMITED"
        return 0
    fi

    # Stamp file throttle for flap-class alerts
    if [ -n "$_class" ] && [[ "$_class" == flap:* ]]; then
        if [[ ! "$_class" =~ ^flap:[a-z0-9]+$ ]]; then
            echo "ERROR: invalid flap class format: ${_class}"
            return 1
        fi
        local _stamp="${STAMP_DIR}/alert_${_class}.stamp"
        if [ -f "$_stamp" ]; then
            local _stamp_age=$(($(date +%s) - $(stat -c %Y "$_stamp" 2>/dev/null || echo 0)))
            if [ "$_stamp_age" -lt 86400 ]; then
                echo "SUPPRESSED"
                return 0
            fi
        fi
        date +%s > "$_stamp"
    fi

    _alert_last_ts=$_now

    _deliver_calls=$(( _deliver_calls + 1 ))
    echo "SENT"
}

echo "=== Test: flap alert stamp throttle ==="

# Test 1: First alert should send
rm -f "${STAMP_DIR}/alert_flap:test.stamp"
_alert_last_ts=0
_deliver_calls=0
output=$(_send_alert_test "fw4 auto-recovered" "test body" "no" "flap:test")

if [ "$output" = "SENT" ]; then
    echo "PASS: first flap alert sent"
    PASS=$((PASS + 1))
else
    echo "FAIL: first alert should be SENT, got: $output"
    FAIL=$((FAIL + 1))
fi

# Test 2: Second alert within 24h should be suppressed
_alert_last_ts=0
output=$(_send_alert_test "fw4 auto-recovered" "test body" "no" "flap:test")

if [ "$output" = "SUPPRESSED" ]; then
    echo "PASS: second flap alert suppressed"
    PASS=$((PASS + 1))
else
    echo "FAIL: second alert should be SUPPRESSED, got: $output"
    FAIL=$((FAIL + 1))
fi

# Test 3: Invalid flap class format should fail
_alert_last_ts=0
output=$(_send_alert_test "test" "body" "no" "flap:INVALID-CAPS" 2>&1) && true
if echo "$output" | grep -q "invalid flap class"; then
    echo "PASS: invalid flap class rejected"
    PASS=$((PASS + 1))
else
    echo "FAIL: invalid flap class not rejected, got: $output"
    FAIL=$((FAIL + 1))
fi

# Test 4: Non-flap class has no stamp throttle
_alert_last_ts=0
output=$(_send_alert_test "fw4 DOWN" "body" "yes" "fault:fw4")
if [ "$output" = "SENT" ]; then
    echo "PASS: non-flap class not stamp-throttled"
    PASS=$((PASS + 1))
else
    echo "FAIL: non-flap should be SENT, got: $output"
    FAIL=$((FAIL + 1))
fi

# Test 5: Stamp older than 24h -> alert sends again (stamp refreshed)
rm -f "$STAMP_FILE"
date +%s > "$STAMP_FILE"
touch -d '25 hours ago' "$STAMP_FILE"
_alert_last_ts=0
_deliver_calls=0
output=$(_send_alert_test "fw4 auto-recovered" "test body" "no" "flap:test")
_stamp_age=$(($(date +%s) - $(stat -c %Y "$STAMP_FILE" 2>/dev/null || echo 0)))
if [ "$output" = "SENT" ] && [ "$_stamp_age" -lt 60 ]; then
    echo "PASS: expired stamp -> resend, stamp refreshed"
    PASS=$((PASS + 1))
else
    echo "FAIL: expired stamp should resend and refresh, got: $output age=${_stamp_age}s"
    FAIL=$((FAIL + 1))
fi

# Test 6: Stamp-suppressed alert does NOT advance the 600s rate limiter,
# so a different alert right after is still sent.
# Setup: stamp fresh (so the flap is stamp-suppressed), limiter expired
# (last send 700s ago, so the 600s rate gate is open).
# NOTE: calls must run in the CURRENT shell (no command substitution) or
# the limiter variable mutation is lost in the subshell.
rm -f "$STAMP_FILE"
date +%s > "$STAMP_FILE"
_alert_last_ts=$(( $(date +%s) - 700 ))
_send_alert_test "fw4 auto-recovered" "b" "no" "flap:test" > "$STAMP_DIR/out1"
_send_alert_test "surflare: fw4 DOWN" "b" "yes" "fault:fw4" > "$STAMP_DIR/out2"
output1=$(cat "$STAMP_DIR/out1")
output2=$(cat "$STAMP_DIR/out2")
if [ "$output1" = "SUPPRESSED" ] && [ "$output2" = "SENT" ]; then
    echo "PASS: suppressed flap does not shadow a later fault alert"
    PASS=$((PASS + 1))
else
    echo "FAIL: suppression shadowed later alert: flap=$output1 fault=$output2"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
