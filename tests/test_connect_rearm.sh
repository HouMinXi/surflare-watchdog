#!/bin/bash
# connect_vpn unarms the killswitch output chain so the CLI can reach its API.
# Every exit between that unarm and the successful re-install must re-arm first,
# or the router routes outside the tunnel while _killswitch_armed still says 1
# and nothing in the tick repairs it.
set -u
cd "$(dirname "$0")/.." || exit 1
WD=${WD:-surflare_watchdog.sh}
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass+1)); }
bad() { echo "FAIL: $*"; fail=$((fail+1)); }

# Scan the body of connect_vpn: after _unarm_killswitch_output, any return that
# is not preceded by a re-arm within two lines is a fail-open exit.
report=$(awk '
	/^connect_vpn\(\) \{/ { infn = 1; depth = 0 }
	infn {
		n++
		if ($0 ~ /^[[:space:]]*_unarm_killswitch_output[[:space:]]*$/) { unarmed = 1; unarm_line = n }
		if ($0 ~ /_reinstall_killswitch_output/) { unarmed = 0 }
		if (unarmed && $0 ~ /^[[:space:]]*return[[:space:]]/) {
			printf "line %d: %s\n", n, $0
		}
	}
	infn && /^}$/ { infn = 0 }
' "$WD")

if [ -z "$report" ]; then
	ok "no exit leaves the killswitch output chain unarmed"
else
	bad "exits that leave the output chain unarmed:"
	printf '%s\n' "$report" | sed 's/^/    /'
fi

# The scan must actually see the unarm, otherwise it passes for the wrong reason.
if awk '/^connect_vpn\(\) \{/{i=1} i&&/_unarm_killswitch_output/{print "found"; exit}' "$WD" | grep -q found; then
	ok "the scan found the unarm site it is meant to police"
else
	bad "connect_vpn no longer contains _unarm_killswitch_output -- update this test"
fi

# And it must see at least one re-arm, so a total removal is not silent.
rearmsg=$(grep -c "_reinstall_killswitch_output" "$WD")
if [ "$rearmsg" -ge 5 ]; then
	ok "re-arm sites still present ($rearmsg)"
else
	bad "only $rearmsg re-arm sites left in the script"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]