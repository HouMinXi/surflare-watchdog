#!/bin/bash
# Invariants that keep the CLI and the upgrade precheck from stalling the loop
# or from executing an unrecorded binary.
set -u
cd "$(dirname "$0")/.." || exit 1
WD=${WD:-surflare_watchdog.sh}
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass+1)); }
bad() { echo "FAIL: $*"; fail=$((fail+1)); }

# --- every CLI disconnect is bounded -------------------------------------
# An unbounded disconnect sits after the tproxy tombstone: the LAN stays
# blocked for as long as the CLI hangs.
# Strip comments first: the constant's own comment mentions the phrase, and a
# grep that counts comments would either flag it or, worse, hide a real call
# behind a line that also has a comment.
unbounded=$(awk '
	{ code = $0; sub(/#.*/, "", code) }
	code ~ /surflare disconnect/ && code !~ /timeout -k .*surflare disconnect/ {
		printf "%d: %s\n", NR, code
	}
' "$WD")
if [ -z "$unbounded" ]; then
	ok "every surflare disconnect runs under a timeout"
else
	bad "unbounded disconnect call(s):"
	printf '%s\n' "$unbounded" | sed 's/^/    /'
fi

# The timeout constant must exist and be sane.
tval=$(sed -n 's/^DISCONNECT_TIMEOUT=\([0-9]*\).*/\1/p' "$WD")
if [ -n "$tval" ] && [ "$tval" -ge 5 ] && [ "$tval" -le 300 ]; then
	ok "DISCONNECT_TIMEOUT is set to a sane bound (${tval}s)"
else
	bad "DISCONNECT_TIMEOUT missing or out of range: '${tval:-unset}'"
fi

# --- the upgrade precheck records what it is about to run -----------------
# The manifest is unsigned, so the log must name the exact binary; a digest
# taken after the run would describe something that may already have changed.
sha_line=$(grep -n '_candidate_sha=\$(sha256sum' "$WD" | head -1 | cut -d: -f1)
run_line=$(grep -n '"\$_new_real" check -c' "$WD" | head -1 | cut -d: -f1)
if [ -n "$sha_line" ] && [ -n "$run_line" ] && [ "$sha_line" -lt "$run_line" ]; then
	ok "the candidate digest is recorded before the candidate runs"
else
	bad "digest recorded after execution (sha at ${sha_line:-?}, run at ${run_line:-?})"
fi

# A bare `timeout` waits for a child that ignores TERM, so the bound it
# appears to give is not one.  Require the hard kill.
if grep -q 'timeout -k "\$DISCONNECT_KILL_GRACE" "\$DISCONNECT_TIMEOUT" surflare disconnect' "$WD"; then
	ok "the disconnect timeout carries a SIGKILL fallback"
else
	bad "the disconnect timeout has no -k: a TERM-ignoring CLI would wait forever"
fi

if grep -q 'for cmd in curl killall pgrep flock timeout surflare' "$WD"; then
	ok "timeout is part of the dependency self-check"
else
	bad "timeout is used but not checked at startup"
fi

if grep -q 'timeout 60 "\$_new_real" check -c' "$WD"; then
	ok "the candidate config check is bounded"
else
	bad "the candidate config check has no timeout"
fi

if grep -q 'manifest is unsigned' "$WD"; then
	ok "the upgrade path states that the manifest carries no signature"
else
	bad "the upgrade path does not admit the manifest is unsigned"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]