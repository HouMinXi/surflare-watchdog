#!/bin/bash
# The control-plane probe decides whether a packet reaches the control return.
# Two ways it can lie:
#
#   - say HIT when a rule stopped the packet (teeth, no coverage),
#   - say MISS when the handshake was merely slow (a false accusation that turns
#     a loaded machine into a product defect).
#
# The second one was real: eight copies of the bypass test at once produced
# three MISSes, all reported as "a rule before the control return stops the
# packet".  The probe's whole budget was half a second.
set -u
cd "$(dirname "$0")/.." || exit 1
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

if ! unshare --user --map-root-user --net true 2>/dev/null; then
	echo "SKIP: this user cannot create network namespaces"
	exit 2
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

TPL=router/rule/surflare-lan-tproxy.nft
probe() { unshare --user --map-root-user --net python3 tests/cp_behavior.py "$1"; }

# 1. An honest template: the packet reaches the control return.
got=$(probe "$TPL")
if [ "$got" = "HIT" ]; then
	ok "an honest template reaches the control return"
else
	bad "the probe said '$got' about an honest template"
fi

# 2. A rule in front of the control return must still be caught.  The drop goes
#    in the same chain and before the return, so the packet never arrives.
awk '
	/@surflare_control[[:space:]]+return/ && !done {
		print "ip daddr 203.0.113.10 drop"
		done = 1
	}
	{ print }
' "$TPL" > "$TMP/dropped.nft"
if grep -q '^ip daddr 203.0.113.10 drop' "$TMP/dropped.nft"; then
	got=$(probe "$TMP/dropped.nft")
	if [ "$got" = "MISS" ]; then
		ok "a drop before the control return reads as MISS"
	else
		bad "the probe said '$got' about a stopping rule"
	fi
else
	bad "the injection did not land in the template"
fi

# 3. The same probe, six at once.  This is the check the half-second budget
#    failed: contention slowed the handshake and the probe called it a drop.
for i in 1 2 3 4 5 6; do
	( r=$(probe "$TPL"); echo "$r" > "$TMP/par.$i" ) &
done
wait
wrong=0
unbuilt=0
for i in 1 2 3 4 5 6; do
	r=$(cat "$TMP/par.$i" 2>/dev/null)
	[ "$r" = "HIT" ] && continue
	[ "$r" = "MISS" ] && { wrong=$((wrong + 1)); continue; }
	# SETUP_FAIL and LOAD_FAIL are not verdicts on the template; they say the
	# sandbox could not be built under load.  Retry once alone before deciding,
	# and if it still cannot run, say so instead of calling it a MISS.
	r2=$(probe "$TPL")
	case "$r2" in
		HIT) ;;
		MISS) wrong=$((wrong + 1)) ;;
		*) unbuilt=$((unbuilt + 1)) ;;
	esac
done
if [ "$wrong" -eq 0 ]; then
	ok "six concurrent probes all see the honest template as HIT"
else
	bad "$wrong of six concurrent probes reported MISS on an honest template"
fi
[ "$unbuilt" -gt 0 ] && echo "NOTE: $unbuilt probe(s) could not build a sandbox; not counted as verdicts"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]