#!/bin/bash
# A background child that inherits the singleton lock keeps it held after the
# parent dies, so the next watchdog start is denied until that child exits.
# The watchdog takes fd 9 (singleton) and fd 200 (instance); every background
# spawn must close both.
set -u
cd "$(dirname "$0")/.." || exit 1
SRC=${SRC:-surflare_watchdog.sh}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass+1)); }
bad() { echo "FAIL: $*"; fail=$((fail+1)); }

# --- case 1: the mechanism, demonstrated ------------------------------------
# A holder takes the lock, spawns a child the old way, then dies. The child
# outlives it and still holds the lock.
cat > "$TMP/holder_naive.sh" <<'EOS'
exec 9>"$1"
flock -n 9 || exit 3
sleep 3 &
echo $! > "$2"
exit 0
EOS
cat > "$TMP/holder_closed.sh" <<'EOS'
exec 9>"$1"
flock -n 9 || exit 3
sleep 3 9>&- &
echo $! > "$2"
exit 0
EOS

bash "$TMP/holder_naive.sh" "$TMP/l1" "$TMP/c1" || bad "naive holder could not take the lock"
sleep 0.3
if flock -n "$TMP/l1" true 2>/dev/null; then
	bad "a child WITHOUT the fd close did not keep the lock -- test is not measuring inheritance"
else
	ok "a background child without 9>&- keeps the singleton lock after the parent exits"
fi

bash "$TMP/holder_closed.sh" "$TMP/l2" "$TMP/c2" || bad "closed holder could not take the lock"
sleep 0.3
if flock -n "$TMP/l2" true 2>/dev/null; then
	ok "closing fd 9 before backgrounding releases the lock with the parent"
else
	bad "closing fd 9 did not release the lock"
fi

# --- case 2: the source invariant ------------------------------------------
# Every background spawn in the script must close both fds. `&&` at the end of
# a line is a chain, not a background spawn, so it is excluded.
# Mid-line backgrounds count too: `sleep 30 & pid=$!` is the shape the first
# version of this test missed, and it is the shape of the main tick sleep.
offenders=$(awk '
	{
		code = $0
		sub(/#.*/, "", code)
		gsub(/&&/, "\001", code)
		if (cont) {
			# the `&` may sit on the continuation line; the closes are above it
			# only when the split happened right before the operator: an
			# ampersand inside a URL or a JSON body is not a background job
			if (code ~ /^[ \t]*&/ && (prevcode !~ /9>&-/ || prevcode !~ /200>&-/))
				printf "%d: %s\n", NR - 1, prevcode
			cont = (code ~ /\\$/); prevcode = code; next
		}
		prevcode = code
		cont = (code ~ /\\$/)
		if (code ~ /^[ \t]*&[ \t]*$/) next
		if (code ~ /[^&]&([ \t]+[a-zA-Z_]+=\$!)?[ \t]*(;.*|disown.*)?$/ &&
		    (code !~ /9>&-/ || code !~ /200>&-/))
			printf "%d: %s\n", NR, code
	}
' "$SRC")
if [ -z "$offenders" ]; then
	ok "every background spawn closes fd 9 and fd 200"
else
	bad "background spawns without the closes:"
	printf '%s\n' "$offenders" | sed 's/^/    /'
fi

# --- case 3: the invariant is not vacuous ----------------------------------
# If the grep pattern stopped matching anything, case 2 would pass for the
# wrong reason. Demand that it still finds the guarded spawns.
# order-insensitive: `200>&- 9>&-` closes the same two descriptors
guarded=$(grep -cE '9>&-[^\n]*200>&-|200>&-[^\n]*9>&-' "$SRC")
if [ "$guarded" -ge 24 ]; then
	ok "the pattern still matches the guarded spawns ($guarded sites)"
else
	bad "only $guarded guarded spawns found -- the pattern or the code changed shape"
fi

# fd 9 is the singleton lock and fd 200 the instance lock.  A subshell that
# re-points fd 9 -- the reconnect mutex does -- must not carry fd 200 into it:
# a SIGKILL there leaves an orphan holding the instance lock, which the next
# daemon needs and which also gates the reaper that would have killed it.
unguarded=$(awk '
	/) 9>"/ && $0 !~ /200>&-/ { print FNR ": " $0 }
' "$SRC")
if [ -z "$unguarded" ]; then
	ok "every subshell that re-points fd 9 closes the instance descriptor"
else
	bad "a subshell re-points fd 9 without closing fd 200: $unguarded"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]