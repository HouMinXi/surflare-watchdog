#!/bin/bash
# IPv6 bypass MAC lookup must parse `ip -6 neigh` regardless of
# whether `dev br-lan` is on the command (4 fields: ADDR lladdr MAC
# STATE) or omitted (6 fields: ADDR dev br-lan lladdr MAC STATE).
# Production used $5, which is STATE on the 4-field form — empty set.
#
# shellcheck disable=SC2015
# shellcheck disable=SC2016
set -u
cd "$(dirname "$0")/.." || exit 1
WATCHDOG=surflare_watchdog.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

MAC='04:7c:16:49:be:32'
GUA='240e:b8f:a19:e500::11'
ULA='fd40:98e2:e85e::11'
LL='fe80::b786:987e:a780:582d'

# Production awk *program* (single-quoted body after awk -v m=).
# The body may span lines; take the first single-quoted string after
# the neigh-show pipe.
extract_prog() {
	python3 - "$1" <<'PY'
import sys, re
text = open(sys.argv[1]).read()
m = re.search(
    r"ip -6 neigh show.*?awk -v m=\"\$mac\" '((?:\\'|[^'])*)'",
    text,
    re.S,
)
if not m:
    sys.exit(1)
print(m.group(1))
PY
}

PROG=$(extract_prog "$WATCHDOG")
[ -n "$PROG" ] || { echo "FATAL: awk program extract empty"; exit 1; }
echo "PROG=[$PROG]"

run_awk() {
	local neigh="$1" prog="$2"
	printf '%s\n' "$neigh" | awk -v m="$MAC" "$prog"
}

# 4-field form: `ip -6 neigh show dev br-lan` (N100 live)
NEIGH4="${ULA} lladdr ${MAC} STALE
${GUA} lladdr ${MAC} STALE
${LL} lladdr ${MAC} STALE
2001:db8::1 lladdr aa:bb:cc:dd:ee:ff REACHABLE"

# 6-field form: `ip -6 neigh show` without dev filter
NEIGH6="${ULA} dev br-lan lladdr ${MAC} STALE
${GUA} dev br-lan lladdr ${MAC} STALE
${LL} dev br-lan lladdr ${MAC} STALE
2001:db8::1 dev br-lan lladdr aa:bb:cc:dd:ee:ff REACHABLE"

out4=$(run_awk "$NEIGH4" "$PROG")
echo "$out4" | grep -qx "$GUA" && echo "$out4" | grep -qx "$ULA" \
	&& ! echo "$out4" | grep -q "$LL" \
	&& ok "T1 4-field neigh (dev on cmdline) finds GUA+ULA, skips fe80" \
	|| bad "T1 4-field: [$out4]"

out6=$(run_awk "$NEIGH6" "$PROG")
echo "$out6" | grep -qx "$GUA" && echo "$out6" | grep -qx "$ULA" \
	&& ! echo "$out6" | grep -q "$LL" \
	&& ok "T2 6-field neigh (no dev filter) finds GUA+ULA, skips fe80" \
	|| bad "T2 6-field: [$out6]"

# Production source must not pin column $5 (that's STATE when `dev` is
# already on the ip command). Match lladdr then the next field.
if printf '%s\n' "$PROG" | grep -qE '\$5'; then
	bad "T3 awk still keys on \$5 (STATE on 4-field neigh)"
else
	ok "T3 awk does not key on \$5"
fi

if printf '%s\n' "$PROG" | grep -qi lladdr; then
	ok "T4 awk matches lladdr token, not a column number"
else
	bad "T4 awk does not mention lladdr"
fi

# Inject: restore $5 matcher, T1 must go red (load-bearing).
INJECT='tolower($5)==tolower(m) && $1!~/^fe80/ {print $1}'
out_i=$(run_awk "$NEIGH4" "$INJECT")
if echo "$out_i" | grep -q "$GUA"; then
	bad "T5 inject \$5 still found GUA — inject did not reproduce the bug"
else
	ok "T5 inject \$5 on 4-field neigh finds nothing (bug reproduced)"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
