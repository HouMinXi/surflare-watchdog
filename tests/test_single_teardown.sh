#!/bin/bash
# _full_teardown existed twice: once in the daemon and once in the procd init
# script, with a comment asking whoever came next to keep them in sync.  They
# drifted -- the copy still deleted one fwmark rule where the daemon drains a
# loop, and it left the 503 counter for the next run to inherit.
set -u
cd "$(dirname "$0")/.." || exit 1
WD=${WD:-surflare_watchdog.sh}
INIT=${INIT:-router/services/procd/surflare-watchdog}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

# --- case 1: the init script keeps no copy ------------------------------
if grep -qE 'nft (delete table|flush ruleset)' "$INIT"; then
	bad "the init script still carries its own teardown (nft lines present)"
else
	ok "the init script has no teardown of its own"
fi
if grep -q '"\$SCRIPT" --teardown' "$INIT"; then
	ok "the init script asks the daemon to tear down"
else
	bad "the init script does not call the daemon's --teardown"
fi

# The daemon has to offer the entry point the init script now calls, and it
# has to survive the singleton lock the live daemon is holding when it runs.
if grep -q '_TEARDOWN_REQUESTED=1' "$WD" && grep -q '_TEARDOWN_REQUESTED:-0' "$WD"; then
	ok "the daemon exposes --teardown"
else
	bad "the daemon has no --teardown entry point"
fi
# The guard has to be code.  A substring grep is satisfied by the comment
# that explains it, so deleting the guard itself stayed green.
# Drive the guard instead of reading it: with the lock held, --teardown must
# return 0.  A text assertion was satisfied by an unrelated `return 0` in the
# same function, so changing the guard to `return 1` stayed green.
awk '/^_enforce_singleton\(\) \{/{i=1} i{print} i && /^}$/{exit}' "$WD" > "$TMP/guard.sh"
if [ -s "$TMP/guard.sh" ]; then
	( exec 8>"$TMP/g.lock"; flock -n 8 || exit 9
	  _SINGLETON_LOCK="$TMP/g.lock" _SINGLETON_PIDFILE="$TMP/g.pid" \
		bash -c '. "$1/guard.sh"; _enforce_singleton --teardown' _ "$TMP" >/dev/null 2>&1 ) 2>/dev/null
	if [ "$?" -eq 0 ]; then
		ok "the singleton guard lets --teardown through"
	else
		bad "the singleton guard refuses --teardown while the daemon holds the lock"
	fi
else
	bad "could not extract _enforce_singleton"
fi

# --- case 2: the daemon's teardown still does the work ------------------
awk -v fn="_full_teardown" '
	index($0, fn "() {") == 1 { i = 1 }
	i { print }
	i && /^}$/ { exit }
' "$WD" > "$TMP/td.sh"
if [ ! -s "$TMP/td.sh" ] || [ "$(wc -l < "$TMP/td.sh")" -gt 40 ]; then
	bad "could not extract _full_teardown from $WD"
else
	mkdir -p "$TMP/bin" "$TMP/run"
	cat > "$TMP/bin/nft" <<EOS
#!/bin/bash
printf 'NFT %s\n' "\$*" >> "$TMP/calls"
exit 0
EOS
	cat > "$TMP/bin/ip" <<EOS
#!/bin/bash
[ "\$1 \$2" = "rule del" ] || exit 1
n=\$(wc -l < "$TMP/rules")
[ "\$n" -gt 0 ] || exit 1
sed -i '\$d' "$TMP/rules"
exit 0
EOS
	chmod +x "$TMP/bin/"*
	# the state-file paths are absolute in production; point them here
	sed -i "s|/run/|$TMP/run/|g" "$TMP/td.sh"
	printf 'rule\nrule\n' > "$TMP/rules"
	printf 'x\n' > "$TMP/run/surflare_watchdog.killswitch_ready"
	printf 'x\n' > "$TMP/run/surflare_watchdog.storm_cool_until"
	printf 'x\n' > "$TMP/run/surflare_503_state"
	printf 'x\n' > "$TMP/run/surflare_503_state.tmp"
	: > "$TMP/calls"
	PATH="$TMP/bin:$PATH" STORM_503_STATE="$TMP/run/surflare_503_state" \
		bash -c '. "$1/td.sh"; _full_teardown' _ "$TMP" 2>/dev/null
	if [ "$(grep -c '^NFT delete table' "$TMP/calls")" -eq 6 ]; then
		ok "the teardown removes all six tables"
	else
		bad "expected 6 table deletes, saw $(grep -c '^NFT delete table' "$TMP/calls")"
	fi
	if [ "$(wc -l < "$TMP/rules")" -eq 0 ]; then
		ok "the teardown drains every stale fwmark rule"
	else
		bad "fwmark rules survived the teardown"
	fi
	left=$(find "$TMP/run" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
	if [ "$left" -eq 0 ]; then
		ok "the teardown clears the state files the next run would inherit"
	else
		bad "${left} state file(s) survived: $(ls "$TMP/run" | tr '\n' ' ')"
	fi
fi

# --- case 3: the entry point is reachable, which is about line order ------
# It existed once before, 900 lines below the argument gate that rejects every
# argument, and after the instance lock and the pidfile write: dead code that
# logged success.
gate=$(grep -n '^--teardown)$' "$WD" | head -1 | cut -d: -f1)
handler=$(grep -n '_TEARDOWN_REQUESTED:-0' "$WD" | head -1 | cut -d: -f1)
lock=$(grep -n '^exec 200>' "$WD" | head -1 | cut -d: -f1)
pidw=$(grep -n 'echo \$\$ >"\$PIDFILE"' "$WD" | head -1 | cut -d: -f1)
if [ -z "$gate" ] || [ -z "$handler" ]; then
	bad "the argument gate does not accept --teardown, or nothing answers it"
else
	ok "the argument gate accepts --teardown and something answers it"
	if [ -n "$lock" ] && [ "$handler" -lt "$lock" ]; then
		ok "teardown runs before the instance lock the daemon holds"
	else
		bad "teardown runs after the instance lock (handler ${handler:-?}, lock ${lock:-?})"
	fi
	if [ -n "$pidw" ] && [ "$handler" -lt "$pidw" ]; then
		ok "teardown runs before the pidfile is rewritten"
	else
		bad "teardown rewrites the live daemon's pidfile (handler ${handler:-?}, pid ${pidw:-?})"
	fi
fi

# --- case 4: a teardown that cannot run must not be reported as one that did
# The daemon's dependency gate names tools the daemon needs at runtime; a stop
# after a broken install is exactly when one is missing, and the teardown only
# needs nft and ip.
if awk '/for cmd in curl killall/,/^fi$/' "$WD" | head -1 >/dev/null 2>&1; then
	:
fi
# The gate must read the argument itself: keying it on a variable that is
# assigned 6000 lines later meant the exemption never applied at all.
if grep -qE '^if \[ "\$\{1:-\}" !?= "--teardown" \]; then' "$WD"; then
	ok "the dependency gate does not apply to --teardown"
else
	bad "a missing daemon dependency makes --teardown a silent no-op"
fi
if grep -q '"\$SCRIPT" --teardown ||' "$INIT"; then
	ok "the init script checks the teardown's status"
else
	bad "the init script ignores a failed teardown and logs success"
fi
if grep -q 'TEARDOWN FAILED' "$INIT"; then
	ok "a failed teardown is logged as a failure"
else
	bad "a failed teardown is logged as a clean stop"
fi

# --- case 5: a surviving table is a failed teardown ----------------------
mkdir -p "$TMP/bin3"
cat > "$TMP/bin3/nft" <<EOS
#!/bin/bash
case "\$1 \$2" in
"list tables") echo "table inet killswitch" ;;
esac
exit 0
EOS
chmod +x "$TMP/bin3/nft"
PATH="$TMP/bin3:$PATH" STORM_503_STATE="$TMP/run/surflare_503_state" \
	bash -c '. "$1/td.sh"; _full_teardown' _ "$TMP" >/dev/null 2>&1
if [ "$?" -ne 0 ]; then
	ok "a table that survives makes the teardown fail"
else
	bad "the teardown reports success with a table still installed"
fi

# --- case 6: the singleton guard is actually called ----------------------
# Every other assertion here extracts the function and calls it itself, so
# deleting the call site in production left the whole suite green.
gline=$(grep -n '^_enforce_singleton "' "$WD" | head -1 | cut -d: -f1)
lline=$(grep -n '^exec 200>' "$WD" | head -1 | cut -d: -f1)
if [ -n "$gline" ] && [ -n "$lline" ] && [ "$gline" -lt "$lline" ]; then
	ok "the daemon calls _enforce_singleton before taking the instance lock"
else
	bad "the singleton guard is not called (line ${gline:-?}, lock ${lline:-?})"
fi

# --- case 7: the answer has to leave the process ------------------------
# The check inside _full_teardown is worthless if the caller exits 0 anyway:
# that is exactly how a surviving table was reported as a clean stop.
if grep -q '_full_teardown || exit 1' "$WD"; then
	ok "the --teardown branch propagates the teardown status"
else
	bad "the --teardown branch exits 0 whatever the teardown achieved"
fi
# "no tables left" and "nft cannot answer" must not look the same
if grep -q 'if ! _tables=$(nft list tables' "$WD"; then
	ok "an unanswerable nft query is not read as an empty ruleset"
else
	bad "a missing or failing nft reads as 'nothing left'"
fi
mkdir -p "$TMP/bin4"
printf '#!/bin/bash\nexit 1\n' > "$TMP/bin4/nft"
chmod +x "$TMP/bin4/nft"
PATH="$TMP/bin4:$PATH" STORM_503_STATE="$TMP/run/surflare_503_state" \
	bash -c '. "$1/td.sh"; _full_teardown' _ "$TMP" >/dev/null 2>&1
if [ "$?" -ne 0 ]; then
	ok "a teardown that cannot verify its work reports failure"
else
	bad "a teardown with no working nft reported success"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]