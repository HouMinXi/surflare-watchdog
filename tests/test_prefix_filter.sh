#!/bin/bash
# Remote prefix lists must never reach nft's parser unvalidated, and one bad
# line must not take the whole batch (and the CN bypass) with it.
set -u
cd "$(dirname "$0")/.." || exit 1
WD=${WD:-surflare_watchdog.sh}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass+1)); }
bad() { echo "FAIL: $*"; fail=$((fail+1)); }

FUNC=_filter_prefixes
awk -v fn="$FUNC" 'index($0, fn "() {") == 1 { inside = 1 } inside { print } inside && /^}$/ { exit }' \
	"$WD" > "$TMP/funcs.sh"
if [ -s "$TMP/funcs.sh" ] && grep -q "^$FUNC() {" "$TMP/funcs.sh"; then
	ok "extracted $FUNC ($(wc -l < "$TMP/funcs.sh") lines)"
else
	bad "could not extract $FUNC"
	echo "RESULT: $pass passed, $fail failed"
	exit 1
fi

filter_out=""
filter_log=""
filter() { # $1 file, $2 family; log() goes to stderr so the result stays clean
	bash -c '. "$1/funcs.sh"; log() { echo "$*" >&2; }; _filter_prefixes "$2" "$3"' \
		_ "$TMP" "$1" "$2" > "$TMP/out.txt" 2> "$TMP/err.txt"
	filter_out=$(cat "$TMP/out.txt")
	filter_log=$(cat "$TMP/err.txt")
}

# --- case 1: a clean list comes through unchanged --------------------------
printf '%s\n' '# comment' '1.0.1.0/24' '1.0.2.0/23' '' '223.255.252.0/23' > "$TMP/v4.txt"
filter "$TMP/v4.txt" 4; got=$filter_out
if [ "$got" = "1.0.1.0/24,1.0.2.0/23,223.255.252.0/23" ]; then
	ok "a clean v4 list passes through unchanged"
else
	bad "clean list mangled: $got"
fi

# --- case 2: an nft injection payload is dropped, the rest survives --------
{
	echo '1.0.1.0/24'
	echo '1.2.3.4 } ; destroy table inet killswitch ; { 5.6.7.8'
	echo '9.9.9.0/24'
} > "$TMP/inject.txt"
filter "$TMP/inject.txt" 4; got=$filter_out
case "$got" in
*1.0.1.0/24*9.9.9.0/24*)
	if printf '%s' "$got" | grep -q 'destroy\|}\|{'; then
		bad "the payload survived into the nft text: $got"
	else
		ok "an nft injection payload is dropped and the rest of the list survives"
	fi
	;;
*) bad "the good entries were lost along with the payload: $got" ;;
esac

# --- case 3: malformed prefixes are dropped ------------------------------
printf '%s\n' '10.0.0.0/33' '300.1.1.1' '192.168.1.0/24' 'not-an-ip' > "$TMP/bad.txt"
filter "$TMP/bad.txt" 4; got=$filter_out
if [ "$got" = "192.168.1.0/24" ]; then
	ok "malformed prefixes are dropped, the valid one stays"
else
	bad "malformed handling wrong: $got"
fi

# --- case 4: a bad line stops nothing else -------------------------------
# This is the blast-radius property: nft rejects the whole batch on one bad
# element, so the filter is what keeps the rest of the list applied.
printf '%s\n' '1.0.1.0/24' 'bogus' '2.0.0.0/16' '3.0.0.0/8' '4.0.0.0/8' '5.0.0.0/8' > "$TMP/mixed.txt"
filter "$TMP/mixed.txt" 4; count=$(printf '%s' "$filter_out" | tr ',' '\n' | grep -c .)
if [ "$count" -eq 5 ]; then
	ok "one bad line leaves the other five prefixes applied"
else
	bad "bad line cost $((6 - count)) prefixes"
fi

# --- case 5: families do not leak into each other ------------------------
printf '%s\n' '1.0.1.0/24' '2001:db8::/32' '2400:3200::/32' > "$TMP/mixed_fam.txt"
filter "$TMP/mixed_fam.txt" 6; got6=$filter_out
if [ "$got6" = "2001:db8::/32,2400:3200::/32" ]; then
	ok "a v6 filter keeps v6 and drops v4"
else
	bad "v6 filter wrong: $got6"
fi

# --- case 5b: IPv6 grammar, not just shape -----------------------------
# These four look like addresses and are rejected by nft, which aborts the
# whole element batch: a shape regex lets them through and silently skips the
# CN bypass for that refresh.
{
	printf '%s\n' '2001:db8::/32' ':::' '1:2:3:4:5:6:7:8:9' '::1::' 'abcd:' '2400:3200::/32'
} > "$TMP/v6grammar.txt"
filter "$TMP/v6grammar.txt" 6
if [ "$filter_out" = "2001:db8::/32,2400:3200::/32" ]; then
	ok "invalid IPv6 forms are dropped, valid ones kept"
else
	bad "IPv6 grammar check wrong: $filter_out"
fi
if printf '%s' "$filter_log" | grep -q 'dropped 4 entries'; then
	ok "the IPv6 drops are reported with a count"
else
	bad "IPv6 drops not reported: $filter_log"
fi

# --- case 6: the drop is reported, not silent ----------------------------
filter "$TMP/bad.txt" 4
if printf '%s' "$filter_log" | grep -q 'dropped 3 entries'; then
	ok "dropped entries are logged with their count"
else
	bad "no drop warning: $filter_log"
fi

# --- case 7: a missing file is not an error ------------------------------
filter "$TMP/nope.txt" 4
if [ -z "$filter_out" ]; then
	ok "a missing list yields empty output"
else
	bad "missing list mishandled: $filter_out"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]