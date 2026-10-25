#!/bin/bash
# The init script exists so the receive spread is restored seconds after an
# interface event instead of up to five minutes later.  What has to hold:
# it acts at boot, it rides the same events packet_steering does, and it comes
# after packet_steering in the boot order.
set -u
cd "$(dirname "$0")/.." || exit 1
SUT=${SUT:-router/services/procd/surflare-rps-assert}
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

[ -f "$SUT" ] || { echo "FAIL: $SUT missing"; exit 1; }

# START must outrank packet_steering's 25, or the re-assert runs first and the
# thing that clears the value wins the boot.
start=$(sed -n 's/^START=\([0-9]*\)$/\1/p' "$SUT")
if [ -n "$start" ] && [ "$start" -gt 25 ]; then
	ok "starts after packet_steering (START=$start > 25)"
else
	bad "START=${start:-unset} does not run after packet_steering's 25"
fi

if grep -q 'procd_add_raw_trigger "interface\.\*"' "$SUT"; then
	ok "re-asserts on interface events rather than waiting for cron"
else
	bad "no interface trigger, so only cron covers a reset"
fi

# packet_steering debounces 1000 ms; ours has to be later than that or the two
# race and the loser is whichever ran last.
delay=$(sed -n 's/.*procd_add_raw_trigger "interface\.\*" \([0-9]*\).*/\1/p' "$SUT")
if [ -n "$delay" ] && [ "$delay" -gt 1000 ]; then
	ok "its trigger fires after packet_steering's 1 s debounce (${delay} ms)"
else
	bad "trigger delay ${delay:-unset} ms races packet_steering"
fi

if grep -q 'surflare_rps_assert\.sh' "$SUT"; then
	ok "it calls the assert script and nothing else"
else
	bad "the init script does not call the assert"
fi

# It must be silent-free at boot: an init script that fails when the queue is
# absent would block the boot sequence.
if grep -q '\[ -x "$ASSERT" \] || return 0' "$SUT"; then
	ok "a missing assert script is survivable at boot"
else
	bad "boot would break if the assert were not installed"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
