#!/bin/bash
# The killswitch is repaired from a memory flag that records the last install,
# not from the ruleset.  Anything that removes `inet killswitch` from outside
# -- a manual flush, a partially applied firewall reload -- leaves the flag at
# 1 and every repair site gated on it, so the LAN stays outside the tunnel.
set -u
cd "$(dirname "$0")/.." || exit 1
WD=${WD:-surflare_watchdog.sh}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

awk -v fn="_killswitch_needs_install" '
	index($0, fn "() {") == 1 { i = 1 }
	i { print }
	i && /^}$/ { exit }
' "$WD" > "$TMP/fn.sh"
if [ ! -s "$TMP/fn.sh" ]; then
	echo "FAIL: could not extract _killswitch_needs_install from $WD"
	echo "RESULT: 0 passed, 1 failed"
	exit 1
fi
if [ "$(wc -l < "$TMP/fn.sh")" -gt 60 ]; then
	echo "FAIL: extraction ran away ($(wc -l < "$TMP/fn.sh") lines)"
	echo "RESULT: 0 passed, 1 failed"
	exit 1
fi

# stub nft: PRESENT_FILE decides whether the forward chain exists
mkdir -p "$TMP/bin"
cat > "$TMP/bin/nft" <<'EOS'
#!/bin/bash
printf '%s\n' "$*" >> "$NFT_CALLS"
[ "${NFT_BROKEN:-0}" = 1 ] && exit 1
case "$1 $2" in
"list tables")
	[ -f "$NFT_PRESENT" ] && printf 'table inet killswitch\n'
	exit 0 ;;
"list table")
	# The whole table in one dump: chains, and the rules that actually block.
	[ -f "$NFT_PRESENT" ] || exit 1
	printf 'table inet killswitch {\n'
	if [ -f "${NFT_CHAIN:-$NFT_PRESENT}" ]; then
		printf '\tchain forward {\n\t\ttype filter hook forward priority filter - 10; policy accept;\n'
		[ -f "${NFT_FORWARD_RULES:-${NFT_CHAIN:-$NFT_PRESENT}}" ] &&
			printf '\t\ttcp dport 853 reject\n'
		printf '\t}\n'
	fi
	if [ -f "${NFT_OUTPUT:-$NFT_PRESENT}" ]; then
		printf '\tchain output {\n\t\ttype filter hook output priority filter - 10; policy accept;\n'
		[ -f "${NFT_OUTPUT_RULES:-${NFT_OUTPUT:-$NFT_PRESENT}}" ] &&
			printf '\t\tudp dport 53 reject\n'
		printf '\t}\n'
	fi
	# Static sets.  A table from an older version has the chains and the reject
	# but not these, so the stub has to be able to leave them out.
	if [ -f "${NFT_SETS:-$NFT_PRESENT}" ]; then
		# The elements come from files so a case can hand back a set whose
		# contents differ from what the script expects.
		if [ -n "${NFT_SET_DERP:-}" ]; then
			_el=$(cat "$NFT_SET_DERP")
		else
			_el=101.132.101.215
		fi
		printf "	set derp_asia { type ipv4_addr; elements = { $_el } }\n"
		if [ -n "${NFT_SET_CTRL:-}" ]; then
			_el=$(cat "$NFT_SET_CTRL")
		else
			_el=192.200.0.0/24
		fi
		printf "	set ts_control { type ipv4_addr; flags interval; elements = { $_el } }\n"
	fi
	printf '}\n'
	exit 0 ;;
"list chain")
	[ -f "${NFT_CHAIN:-$NFT_PRESENT}" ] || exit 1
	printf 'table inet killswitch {\n\tchain forward {\n\t\tcounter packets 0 bytes 0\n\t}\n}\n'
	exit 0 ;;
esac
exit 1
EOS
chmod +x "$TMP/bin/nft"

drive() { # $1 = initial armed flag, $2 = present file, prints "<rc> <armed>"
	PATH="$TMP/bin:$PATH" NFT_CALLS="$TMP/calls" NFT_PRESENT="$2" NFT_BROKEN="${3:-0}" NFT_CHAIN="${4:-$2}" NFT_FORWARD_RULES="${5:-}" NFT_OUTPUT="${6:-}" NFT_OUTPUT_RULES="${7:-}" NFT_SETS="${8:-}" \
		bash -c '
		. "$1/fn.sh"
		_killswitch_armed=$2
		if _killswitch_needs_install; then rc=0; else rc=1; fi
		echo "$rc $_killswitch_armed"
	' "$WD" "$TMP" "$1" 2>/dev/null
}

# --- case 1: flag says armed, the chain is gone -> install again ---------
: > "$TMP/calls"
rm -f "$TMP/present"
out=$(drive 1 "$TMP/present")
set -- $out
if [ "${1:-x}" = "0" ]; then
	ok "a missing forward chain makes the killswitch look uninstalled"
else
	bad "a missing forward chain did not trigger a reinstall (got ${out:-nothing})"
fi
if [ "${2:-x}" = "0" ]; then
	ok "the stale armed flag is cleared so the install path runs"
else
	bad "the flag stayed at ${2:-?}: the install path would not run"
fi

# --- case 2: armed and the chain is there -> no work ---------------------
: > "$TMP/calls"
touch "$TMP/present"
out=$(drive 1 "$TMP/present")
set -- $out
if [ "${1:-x}" = "1" ]; then
	ok "an intact killswitch costs no reinstall"
else
	bad "an intact killswitch was reinstalled (got ${out:-nothing})"
fi
if [ "${2:-x}" = "1" ]; then
	ok "the armed flag is left alone when the chain is intact"
else
	bad "the flag was cleared on a healthy chain"
fi
if [ "$(wc -l < "$TMP/calls")" -ge 1 ]; then
	ok "the check asks nft rather than trusting the flag"
else
	bad "nft was never consulted"
fi

# --- case 2b: chains and reject there, static sets missing -> rebuild ------
# This is the upgrade path: a table built before ts_control existed looks
# healthy by every older check, so the new exemption never lands.
: > "$TMP/calls"
touch "$TMP/present"
rm -f "$TMP/nosets"
out=$(drive 1 "$TMP/present" 0 "" "" "" "" "$TMP/nosets")
set -- $out
if [ "${1:-x}" = "0" ]; then
	ok "a killswitch without the static sets is rebuilt"
else
	bad "a killswitch without the static sets was left alone (got ${out:-nothing})"
fi
if [ "${2:-x}" = "0" ]; then
	ok "the armed flag is cleared so the rebuild runs"
else
	bad "the flag stayed at ${2:-?}: the rebuild would not run"
fi

# --- case 2c: the set is there but holds more than it should -> rebuild ----
# Narrowing an existing set must rebuild too.  A check that only asks whether
# the set exists leaves the wider contents in place.
: > "$TMP/calls"
touch "$TMP/present"
printf '101.132.101.215, 185.40.234.53' > "$TMP/wide"
out=$(NFT_SET_DERP="$TMP/wide" drive 1 "$TMP/present")
set -- $out
if [ "${1:-x}" = "0" ]; then
	ok "a killswitch whose set holds extra addresses is rebuilt"
else
	bad "a wider set was left in place (got ${out:-nothing})"
fi

# --- case 3: already unarmed -> no nft call at all -----------------------
: > "$TMP/calls"
rm -f "$TMP/present"
out=$(drive 0 "$TMP/present")
set -- $out
if [ "${1:-x}" = "0" ] && [ ! -s "$TMP/calls" ]; then
	ok "an unarmed killswitch installs without a ruleset query"
else
	bad "an unarmed killswitch still queried nft (rc=${1:-?}, calls=$(wc -l < "$TMP/calls"))"
fi

# --- case 4: no repair site may go back to reading the flag alone --------
if grep -E '\[ "\$_killswitch_armed" -eq 0 \]' "$WD" | grep -qv 'return 0'; then
	bad "a repair site still gates on the flag alone"
else
	ok "every repair site asks _killswitch_needs_install"
fi

# nft that cannot answer either question: not the same as a missing chain.
got=$(drive 1 "$TMP/absent" 1)
case "$got" in
"1 1") ok "an unanswerable nft leaves the killswitch armed" ;;
*) bad "an unanswerable nft was read as a missing chain (got $got)" ;;
esac

# table there, forward chain deleted: nothing blocks anything, so this is the
# state the install path exists for.  The table list answers, which is what
# separates it from an nft that cannot talk.
touch "$TMP/present"
rm -f "$TMP/absent"
got=$(drive 1 "$TMP/present" 0 "$TMP/absent")
case "$got" in
"0 0") ok "a deleted forward chain triggers a reinstall" ;;
*) bad "a deleted forward chain left the flag alone (got $got)" ;;
esac

# A chain whose header is there but whose rules were flushed blocks nothing;
# nft prints the header either way, so presence alone is not the question.
touch "$TMP/present"
rm -f "$TMP/none"
got=$(drive 1 "$TMP/present" 0 "" "$TMP/none")
case "$got" in
"0 0") ok "an empty forward chain triggers a reinstall" ;;
*) bad "an empty forward chain read as installed (got $got)" ;;
esac

# The output chain is the router-originated half of the block; losing it while
# forward survives leaves that path open.
got=$(drive 1 "$TMP/present" 0 "" "" "$TMP/none")
case "$got" in
"0 0") ok "a missing output chain triggers a reinstall" ;;
*) bad "a missing output chain read as installed (got $got)" ;;
esac

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]