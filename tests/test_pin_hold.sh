#!/bin/bash
# A dedicated pin kills the surflare process on purpose.  The watchdog
# must not treat that gap as a lost tunnel and rotate to a city node.
# The supervisor writes an expiry before the kill; _pin_in_progress
# (extracted from the real script) is true only while that expiry is
# still in the future.  The LOCAL_FAIL branch calls it and, while it
# is true, leaves fail_count alone.
#
# shellcheck disable=SC2015

set -u
cd "$(dirname "$0")/.." || exit 1
WATCHDOG=surflare_watchdog.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

extract_fn() {
    awk -v name="$2" '
        $0 ~ "^" name "\\(\\) \\{" { f=1 }
        f { print }
        f && /^}$/ { exit }
    ' "$1"
}

PIN=$(extract_fn "$WATCHDOG" _pin_in_progress)
case "$PIN" in
    *surflare_ded_pin_until*) ok "pin check extracted" ;;
    *) bad "pin check missing"; echo "PASS=$PASS FAIL=$FAIL"; exit 1 ;;
esac

# The LOCAL_FAIL handler sits inside the main loop, past the
# source-only return, so it cannot be executed here.  Require the real
# call, not a mention: the line must invoke _pin_in_progress, and the
# fail_count assignment must sit in its else.  A comment naming the
# function, or a same-named assignment in a later branch, stays red.
if awk '
    /if \[ "\$health" = "LOCAL_FAIL" \]; then/ { f=1 }
    f && /^[[:space:]]*if _pin_in_progress; then/ { call=1; depth=1; next }
    call && depth==1 && /^[[:space:]]*else$/ { arm=1 }
    arm && depth==1 && /^[[:space:]]*fail_count=\$FAIL_THRESHOLD$/ { got=1 }
    call && /if[ ;]/ { depth++ }
    call && /^[[:space:]]*fi$/ { depth--; if (depth==0) exit }
    END { exit !got }
' "$WATCHDOG"; then
    ok "LOCAL_FAIL holds during a pin and reconnects otherwise"
else
    bad "LOCAL_FAIL pin guard is missing or toothless"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
MARK="$TMP/pin_until"
cat > "$TMP/harness.sh" <<EOF
PIN_UNTIL="$MARK"
$(printf '%s\n' "$PIN")
EOF

run_pin() {
    (
        cd "$TMP" || exit 9
        # shellcheck disable=SC1091
        source ./harness.sh
        if _pin_in_progress; then echo yes; else echo no; fi
    )
}

echo $(( $(date +%s) + 90 )) > "$MARK"
[ "$(run_pin)" = "yes" ] && ok "fresh marker counts as a pin" \
    || bad "fresh marker not seen"

echo $(( $(date +%s) - 10 )) > "$MARK"
[ "$(run_pin)" = "no" ] && ok "expired marker is not a pin" \
    || bad "expired marker still counts"

printf 'abc\n' > "$MARK"
[ "$(run_pin)" = "no" ] && ok "non-numeric marker is not a pin" \
    || bad "non-numeric marker counted"

rm -f "$MARK"
[ "$(run_pin)" = "no" ] && ok "missing marker is not a pin" \
    || bad "missing marker counted"

# pin_abort must stop pin_dedicated, not only itself.  Extract the real
# function, stub the TUI so the spawn fails, and require that nothing
# after the failure runs and that the marker is gone.
SUP=scripts/tui-supervisor.sh
PD=$(awk '/^pin_dedicated\(\) \{/ { f=1 } f { print } f && /^}$/ { exit }' "$SUP")
case "$PD" in
    *pin_abort*) ok "pin_dedicated extracted" ;;
    *) bad "pin_dedicated extraction failed"; echo "PASS=$PASS FAIL=$FAIL"; exit 1 ;;
esac
MARK2="$TMP/pin_until2"
cat > "$TMP/pin.sh" <<EOF
PINMARK="$MARK2"
SOCK=/nonexistent
TUI_LOG="$TMP/tui.log"
DED_NODE="nowhere"
sexpect() { echo "sexpect \$*" >> "$TMP/trace"; return 1; }
pkill() { :; }
sleep() { :; }
_cursor_row() { echo ""; }
surflare() { echo "  Server: Chicago"; }
note() { :; }
$(printf '%s\n' "$PD" | sed 's#/run/surflare_ded_pin_until#"$PINMARK"#g')
EOF
rm -f "$TMP/trace"
(
    cd "$TMP" || exit 9
    # shellcheck disable=SC1091
    source ./pin.sh
    pin_dedicated
    echo "rc=$?"
) > "$TMP/out"
rc=$(sed -n 's/^rc=//p' "$TMP/out")
[ "$rc" = "1" ] && ok "failed spawn returns failure" || bad "failed spawn rc=$rc"
[ ! -f "$MARK2" ] && ok "failed spawn clears the marker" || bad "marker survived a failed spawn"
if grep -q 'send' "$TMP/trace" 2>/dev/null; then
    bad "walk continued after a failed spawn"
else
    ok "walk stops after a failed spawn"
fi

# The spawn stub fails every sexpect, so it never reaches the later
# abort sites.  Drive one of them directly: the menu opens, but the
# cursor never lands on the target.  The loop must stop at MAX_STEPS
# and must not send the connect Enter.
cat > "$TMP/pin2.sh" <<EOF
PINMARK="$TMP/pin_until3"
SOCK=/nonexistent
TUI_LOG="$TMP/tui2.log"
DED_NODE="nowhere"
sexpect() {
    echo "sexpect \$*" >> "$TMP/trace2"
    case "\$1 \$2" in
        *" send "*) ;;
        *) return 0 ;;
    esac
}
pkill() { :; }
sleep() { :; }
_cursor_row() { echo "some other node"; }
surflare() { echo "  Server: Chicago"; }
note() { :; }
$(printf '%s\n' "$PD" | sed 's#/run/surflare_ded_pin_until#"$PINMARK"#g')
EOF
rm -f "$TMP/trace2"
(
    cd "$TMP" || exit 9
    # shellcheck disable=SC1091
    source ./pin2.sh
    pin_dedicated
    echo "rc=$?"
) > "$TMP/out2" &
pin_pid=$!
(
    sleep 15
    kill "$pin_pid" 2>/dev/null
) &
guard=$!
wait "$pin_pid" 2>/dev/null
pin_rc=$?
kill "$guard" 2>/dev/null
wait "$guard" 2>/dev/null
if [ "$pin_rc" -gt 128 ]; then
    bad "missing-node walk did not stop"
else
    rc=$(sed -n 's/^rc=//p' "$TMP/out2")
    [ "$rc" = "1" ] && ok "missing node returns failure" || bad "missing node rc=$rc"
    [ ! -f "$TMP/pin_until3" ] && ok "missing node clears the marker" || bad "marker survived a missing node"
    arrows=$(grep -c 'x1b\[B' "$TMP/trace2" 2>/dev/null || true)
    [ "$arrows" -eq 40 ] && ok "down-arrows stop at MAX_STEPS ($arrows)" \
        || bad "down-arrows ran past MAX_STEPS ($arrows)"
fi

# Settle re-read.  The cursor matches twice so the loop breaks, then the
# re-read disagrees.  pin_dedicated must stop there.  The two Enter presses
# are the menu; a third would be the connect Enter, which means the abort
# fell through.  The harness is written by python because the extracted
# function contains $(...) that an unquoted heredoc would expand.
python3 - "$PD" "$TMP" <<'PYSTUB'
import sys
pd, tmp = sys.argv[1], sys.argv[2]
pd = pd.replace("/run/surflare_ded_pin_until", '"$PINMARK"')
rows = [
    'PINMARK="%s/pin_until4"' % tmp,
    "SOCK=/nonexistent",
    'TUI_LOG="%s/tui3.log"' % tmp,
    'DED_NODE="target"',
    'sexpect() { echo "sexpect $*" >> "%s/trace3"; case "$1 $2" in *" send "*) ;; *) return 0 ;; esac; }' % tmp,
    "pkill() { :; }",
    "sleep() { :; }",
    '_cursor_row() { echo x >> "%s/reads"; c=$(grep -c x "%s/reads"); if [ "$c" -le 1 ]; then echo target; else echo neighbor; fi; }' % (tmp, tmp),
    'surflare() { echo "  Server: Chicago"; }',
    "note() { :; }",
    pd,
]
open(tmp + "/pin3.sh", "w").write("\n".join(rows) + "\n")
PYSTUB
rm -f "$TMP/trace3" "$TMP/reads"
(
    cd "$TMP" || exit 9
    # shellcheck disable=SC1091
    source ./pin3.sh
    pin_dedicated
    echo "rc=$?"
) > "$TMP/out3"
rc=$(sed -n 's/^rc=//p' "$TMP/out3")
[ "$rc" = "1" ] && ok "settle mismatch returns failure" || bad "settle mismatch rc=$rc"
[ ! -f "$TMP/pin_until4" ] && ok "settle mismatch clears the marker" || bad "marker survived a settle mismatch"
enters=$(grep -c 'send -cr' "$TMP/trace3" 2>/dev/null || echo 0)
[ "$enters" -eq 1 ] && ok "no connect Enter after a settle mismatch" \
    || bad "settle mismatch sent $enters Enter presses, want 1"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
