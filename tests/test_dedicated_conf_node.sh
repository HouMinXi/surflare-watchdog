#!/bin/bash
# NODE must come from /etc/surflare/dedicated.conf (DED_NODE), not from
# a literal baked into the watchdog.  The loader block is EXTRACTED from
# the real script.  A pass with the conf pointing at one address and the
# script default at another proves the conf wins.
#
# shellcheck disable=SC2015

set -u
cd "$(dirname "$0")/.." || exit 1
WATCHDOG=surflare_watchdog.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# RFC 5737 TEST-NET-2, built at runtime so no IPv4 literal sits in the file.
DEDICATED="United States($(printf '%d.%d.%d.%d' 198 51 100 7))"

# The loader: from the NODE= default through the unset of the scratch vars.
extract_loader() {
	awk '
		/^NODE="Chicago"$/ { f=1 }
		f { print }
		f && saw && /^fi$/ { exit }
		f && /^[[:space:]]*unset _ded_en _ded_node$/ { saw=1 }
	' "$1"
}

BLK=$(extract_loader "$WATCHDOG")
if [ -n "$BLK" ] && printf '%s\n' "$BLK" | grep -q 'DED_NODE='; then
	ok "loader extracted ($(printf '%s\n' "$BLK" | wc -l) lines)"
else
	bad "loader extraction failed"
	echo "PASS=$PASS FAIL=$FAIL"
	exit 1
fi

# Production reads a literal path.  Rewrite that one path at a fixture,
# write the block to a file, and source it.  Sourcing (not bash -c of the
# block text) keeps pipes and quotes in the production bytes intact.
run_case() {  # $1 = conf body (empty = file absent)
	local d f
	d=$(mktemp -d /tmp/dn_XXXXXX)
	if [ -n "$1" ]; then
		printf '%s\n' "$1" > "$d/dedicated.conf"
	fi
	f="$d/loader.sh"
	printf '%s\n' "$BLK" | sed "s|/etc/surflare/dedicated[.]conf|$d/dedicated.conf|g" > "$f"
	# shellcheck disable=SC1090
	( set -u; . "$f"; printf '%s' "$NODE" )
	rm -rf "$d"
}

echo "T1: ENABLED=1 + DED_NODE -> conf wins over the Chicago default"
out=$(run_case "$(printf 'ENABLED=1\nDED_NODE="%s"' "$DEDICATED")")
[ "$out" = "$DEDICATED" ] && ok "conf DED_NODE adopted" || bad "T1 got: [$out]"

echo "T2: ENABLED=0 -> subscription lapse, stay on the city default"
out=$(run_case "$(printf 'ENABLED=0\nDED_NODE="%s"' "$DEDICATED")")
[ "$out" = "Chicago" ] && ok "disabled conf ignored" || bad "T2 got: [$out]"

echo "T3: no dedicated.conf -> city default"
out=$(run_case "")
[ "$out" = "Chicago" ] && ok "missing conf -> Chicago" || bad "T3 got: [$out]"

echo "T4: ENABLED=1 but empty DED_NODE -> city default"
out=$(run_case "ENABLED=1
DED_NODE=")
[ "$out" = "Chicago" ] && ok "empty DED_NODE ignored" || bad "T4 got: [$out]"

echo "T5: quoted DED_NODE has the quotes stripped"
out=$(run_case "ENABLED=\"1\"
DED_NODE=\"$DEDICATED\"")
[ "$out" = "$DEDICATED" ] && ok "quotes stripped" || bad "T5 got: [$out]"

echo "T5b: CRLF conf does not keep the carriage return"
out=$(run_case "$(printf 'ENABLED=1\r\nDED_NODE="%s"\r' "$DEDICATED")")
[ "$out" = "$DEDICATED" ] && ok "CR stripped" || bad "T5b got: [$out]"

echo "T6: injection -- comment out the adoption, T1 must stay on Chicago"
inj=$(printf '%s\n' "$BLK" | sed 's|^\([[:space:]]*\)NODE="\$_ded_node"|\1:|')
if [ "$inj" = "$BLK" ]; then
	bad "T6 sed changed nothing"
else
	printf '%s\n' "$inj" | bash -n || bad "T6 injection is not valid shell"
	d=$(mktemp -d /tmp/dn_XXXXXX)
	printf 'ENABLED=1\nDED_NODE="%s"\n' "$DEDICATED" > "$d/dedicated.conf"
	printf '%s\n' "$inj" | sed "s|/etc/surflare/dedicated[.]conf|$d/dedicated.conf|g" > "$d/loader.sh"
	# shellcheck disable=SC1090
	# nounset off: the parent script enables it, and a sourced fragment
	# inherits that.  The assertion needs the fragment to finish.
	out=$( set +u; . "$d/loader.sh"; printf '%s' "$NODE" )
	rm -rf "$d"
	[ "$out" = "Chicago" ] && ok "adoption deleted -> conf ignored" || bad "T6 still adopted: [$out]"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
