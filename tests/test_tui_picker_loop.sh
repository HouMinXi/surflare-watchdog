#!/bin/sh
# tests/tui-picker-loop.sh -- bounds proof for the language-picker walk
# in scripts/tui-supervisor.sh (pin_dedicated picker block).
#
# The mirror below MUST stay in lockstep with the deployed loop: same
# check-first shape, same bound.  It stubs only the external surface
# (sexpect key-send and the TUI log file); the control flow is the
# code under test.  Row map matches the picker: 1 English, 2 Deutsch,
# 3 한국어, 4 日本語, 5 中文.
#
# The 2026-10-18 forge review (qodo+expert+adversarial, 3x CONFIRMED)
# caught the shipped `-lt 4` bound: the 4th down key lands the cursor
# on Chinese but the loop exits without checking row 5, so every
# picker-path pin aborted.  This test fails on that bound and passes
# on the fix.
#
# Run: sh tests/tui-picker-loop.sh   (exit 0 = pass)

CURSOR=1
LOG=$(mktemp)
SENT_KEYS=0

# stub: one arrow-down moves the highlight one row; the "TUI log"
# re-renders with the new highlighted row.
send_down() {
    CURSOR=$((CURSOR + 1))
    SENT_KEYS=$((SENT_KEYS + 1))
    : > "$LOG"
    case "$CURSOR" in
        1) printf '  ▸ English\n'    >> "$LOG" ;;
        2) printf '  ▸ Deutsch\n'    >> "$LOG" ;;
        3) printf '  ▸ 한국어\n'      >> "$LOG" ;;
        4) printf '  ▸ 日本語\n'      >> "$LOG" ;;
        5) printf '  ▸ 中文\n'        >> "$LOG" ;;
        *) printf '  ▸ Português\n'  >> "$LOG" ;;
    esac
}
# initial render: cursor on row 1
: > "$LOG"; printf '  ▸ English\n' >> "$LOG"

BOUND=6   # mirror of the deployed loop bound
_picker_ok=0
_k=0
while [ "$_k" -lt "$BOUND" ]; do
    if tail -c 2000 "$LOG" 2>/dev/null | grep -q "▸ 中文"; then
        _picker_ok=1
        break
    fi
    send_down
    _k=$((_k + 1))
done
[ "$_picker_ok" = "1" ] || { echo "FAIL: picker walk never verified 中文 (bound=$BOUND keys=$SENT_KEYS)"; rm -f "$LOG"; exit 1; }
[ "$SENT_KEYS" -eq 4 ] || { echo "FAIL: expected exactly 4 downs, sent $SENT_KEYS"; rm -f "$LOG"; exit 1; }
echo "PASS: verified 中文 with bound=$BOUND after $SENT_KEYS downs"
rm -f "$LOG"

# --- injection arm: the reviewed-away `-lt 4` bound must fail here ---
CURSOR=1; SENT_KEYS=0
: > "$LOG"; printf '  ▸ English\n' >> "$LOG"
_picker_ok=0
_k=0
while [ "$_k" -lt 4 ]; do
    if tail -c 2000 "$LOG" 2>/dev/null | grep -q "▸ 中文"; then
        _picker_ok=1
        break
    fi
    send_down
    _k=$((_k + 1))
done
if [ "$_picker_ok" = "1" ]; then
    echo "FAIL: injected -lt 4 bound unexpectedly passed"
    rm -f "$LOG"
    exit 1
fi
echo "PASS: injected -lt 4 bound correctly fails"
rm -f "$LOG"
exit 0
