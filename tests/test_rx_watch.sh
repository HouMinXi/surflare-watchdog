#!/bin/bash
# The counter this watches could not be attributed on the day it was measured,
# and it cannot be forced. What a sampler can be held to: silent when nothing
# moves, one line with context when something does, and no unbounded growth in
# RAM.
set -u
cd "$(dirname "$0")/.." || exit 1
SUT=${SUT:-router/services/surflare_rx_watch.sh}
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/sys/statistics"
for f in rx_missed_errors rx_fifo_errors; do echo 0 > "$TMP/sys/statistics/$f"; done
echo 0 > "$TMP/sys/carrier_changes"

drive() {
	SYSFS="$TMP/sys" STATE="$TMP/state" LOG="$TMP/log" sh "$SUT" >/dev/null 2>&1
	echo $?
}

rc=$(drive)
if [ "$rc" -eq 0 ] && [ ! -f "$TMP/log" ]; then
	ok "the first run only takes a baseline and reports nothing"
else
	bad "the first run wrote an event (rc=$rc)"
fi

rc=$(drive)
if [ "$rc" -eq 0 ] && [ ! -f "$TMP/log" ]; then
	ok "an unchanged counter stays silent"
else
	bad "an unchanged counter produced output"
fi

echo 5 > "$TMP/sys/statistics/rx_missed_errors"
rc=$(drive)
if [ "$rc" -eq 0 ] && grep -q 'missed=+5' "$TMP/log"; then
	ok "a rise is recorded with its delta"
else
	bad "a rise was not recorded (rc=$rc)"
fi

if grep -q 'softnet_drop=\|carrier_changes=' "$TMP/log"; then
	ok "the event carries the context needed to attribute it"
else
	bad "the event has no context beyond the one number"
fi

before=$(wc -l < "$TMP/log")
echo 9 > "$TMP/sys/statistics/rx_missed_errors"
drive >/dev/null
after=$(wc -l < "$TMP/log")
if [ "$after" -gt "$before" ]; then
	ok "the second rise appends rather than overwriting history"
else
	bad "the log did not grow"
fi

# A link flap with no new drops still has to be recorded: a carrier reset is
# what silently clears the receive spread, and a sampler blind to it cannot
# explain a window in which nothing else moved.
: > "$TMP/log"
echo 3 > "$TMP/sys/carrier_changes"
rc=$(drive)
if [ "$rc" -eq 0 ] && grep -q 'carrier_changes=3' "$TMP/log"; then
	ok "a carrier change alone is recorded"
else
	bad "a carrier change went unrecorded (rc=$rc)"
fi

# softnet_stat prints hex.  Reading it as decimal reports numbers that are not
# in the file at all.
: > "$TMP/log"
printf '00000000 00000010 00000000 00000000\n' > "$TMP/softnet"
echo 11 > "$TMP/sys/statistics/rx_missed_errors"
SOFTNET="$TMP/softnet" SYSFS="$TMP/sys" STATE="$TMP/state" LOG="$TMP/log" sh "$SUT" >/dev/null 2>&1
if grep -q 'softnet_drop=+16' "$TMP/log"; then
	ok "a hex softnet column is converted, not read as decimal"
else
	bad "softnet was read as decimal: $(grep -o 'softnet_drop=[^ ]*' "$TMP/log" | tail -1)"
fi

rm -f "$TMP/sys/statistics/rx_missed_errors"
rc=$(drive)
if [ "$rc" -eq 0 ]; then
	ok "a missing counter is not an error"
else
	bad "a missing counter returned rc=$rc"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
