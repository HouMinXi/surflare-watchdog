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
if [ "$(wc -l < "$TMP/fn.sh")" -gt 40 ]; then
	echo "FAIL: extraction ran away ($(wc -l < "$TMP/fn.sh") lines)"
	echo "RESULT: 0 passed, 1 failed"
	exit 1
fi

# stub nft: PRESENT_FILE decides whether the forward chain exists
mkdir -p "$TMP/bin"
cat > "$TMP/bin/nft" <<'EOS'
#!/bin/bash
printf '%s\n' "$*" >> "$NFT_CALLS"
[ -f "$NFT_PRESENT" ] || exit 1
printf 'table inet killswitch {\n\tchain forward {\n\t\tcounter packets 0 bytes 0\n\t}\n}\n'
exit 0
EOS
chmod +x "$TMP/bin/nft"

drive() { # $1 = initial armed flag, $2 = present file, prints "<rc> <armed>"
	PATH="$TMP/bin:$PATH" NFT_CALLS="$TMP/calls" NFT_PRESENT="$2" \
		bash -c '
		. "$1/fn.sh"
		_killswitch_armed=$2
		if _killswitch_needs_install; then rc=0; else rc=1; fi
		echo "$rc $_killswitch_armed"
	' _ "$TMP" "$1" 2>/dev/null
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

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]