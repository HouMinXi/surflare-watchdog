#!/bin/bash
# Exercise the real wrapper in a parent that remains alive after each call.
# This suite writes subject scripts in bash syntax, so it needs bash itself.
[ -n "${BASH_VERSION:-}" ] || { echo "SKIP: tests/test_nft_write_lock.sh requires bash (generates bash subject scripts)"; exit 2; }
set -u
cd "$(dirname "$0")/.." || exit 1
WD=${WD:-surflare_watchdog.sh}
[ -f "$WD" ] || { echo "FAIL: cannot read $WD"; exit 1; }
TMP=$(mktemp -d) || exit 1
holder_pid=''
_killed=''
_cleanup_failed=''
# One EXIT trap, installed before anything that can fail: reap the holder recorded
# above, then remove the temp dir.
reap_holder() {
	# A signal and the exit that follows it both reach this handler. The kill
	# runs once; the temp-dir removal is attempted every time because it is
	# idempotent and must not be skippable by a flag left set from outside.
	if [ -z "${_killed:-}" ]; then
		_killed=1
		[ -n "${_watchdog:-}" ] && kill "$_watchdog" 2>/dev/null
		if [ -n "${holder_pid:-}" ] && [ "$holder_pid" != "$$" ]; then
			kill -0 "$holder_pid" 2>/dev/null && kill -9 "$holder_pid" 2>/dev/null
		fi
	fi
	[ -n "${TMP:-}" ] && rm -rf "$TMP"
	if [ -e "${TMP:-/nonexistent}" ]; then
		echo "WARN: ${TMP} could not be removed" >&2
		_cleanup_failed=1
	fi
	return 0
}
# An exit keeps its status unless the cleanup failed, which turns a green run
# red; a signal always exits 1.
trap 'rc=$?; reap_holder; [ -n "${_cleanup_failed:-}" ] && [ "$rc" -eq 0 ] && rc=1; exit "$rc"' EXIT
trap 'reap_holder; exit 1' INT TERM HUP
# A regression that turns the non-blocking lock into a blocking one would hang
# every case that calls the wrapper while a holder runs. The watchdog turns that
# into a named failure instead of the runner's bare timeout; the deadline is
# overridable so the check itself can be exercised.
_deadline_raw=${_SUITE_DEADLINE_SECS:-}
case "$_deadline_raw" in
'' | *[!0-9]*) _deadline_secs=240 ;; # an unusable value must not abort the run
*) _deadline_secs=$_deadline_raw ;;
esac
_suite_deadline=$(($(date +%s) + _deadline_secs))
(
	while :; do
		sleep 5
		[ "$(date +%s)" -ge "$_suite_deadline" ] || continue
		printf 'FAIL: the suite exceeded its lock deadline\n' >&2
		# A trap cannot run while the shell waits on a foreground child, so the
		# polite signal is only a chance to clean up; the kill is what ends a
		# genuinely blocked lock.
		kill -TERM $$
		sleep 5
		pkill -9 -P $$ 2>/dev/null
		[ -n "${TMP:-}" ] && rm -rf "$TMP"
		kill -9 $$
		exit 0
	done
) &
_watchdog=$!
pass=0
fail=0
ok() { printf 'PASS: %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$*"; fail=$((fail + 1)); }
awk '/^NFT_LOCK_FILE=/ {p=1} p {print} p && /^\)$/ {exit}' \
	"$WD" > "$TMP/helpers"
bash -n "$TMP/helpers" || exit 1
grep -q '^nft_apply_locked() (' "$TMP/helpers" || exit 1
export SURFLARE_NFT_LOCK="$TMP/lock"
. "$TMP/helpers"
log() { printf '%s\n' "$*" >&2; }
mkdir "$TMP/bin"
cat > "$TMP/bin/nft" <<'EOF'
#!/bin/sh
exec 7>>"$SURFLARE_NFT_LOCK"
if flock -n 7; then state=free; else state=held; fi
printf '%s\n' "$state" >> "$FAKE_LOG"
printf 'nft-diagnostic\n' >&2
exit "${FAKE_RC:-0}"
EOF
chmod +x "$TMP/bin/nft"
export PATH="$TMP/bin:$PATH" FAKE_LOG="$TMP/nft.log"

nft_apply_locked test nft -f file 2>"$TMP/err"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(<"$FAKE_LOG")" = held ]; then
	ok 'real command runs under the shared lock'
else bad 'command ran unlocked or failed'; fi

# The calling shell remains alive: kernel cleanup on parent exit cannot help.
if (exec 7>>"$SURFLARE_NFT_LOCK"; flock -n 7) &&
	[ ! -e /proc/self/fd/8 ]; then
	ok 'lock and descriptor are released before the next parent command'
else bad 'lock or descriptor leaked into the live parent'; fi
printf 'parent-stderr\n' 2>"$TMP/parent.err" >&2
# A normal redirected command must not affect subsequent stderr either.
if grep -q nft-diagnostic "$TMP/err" &&
	grep -q parent-stderr "$TMP/parent.err"; then
	ok 'child and parent stderr remain observable'
else bad 'stderr was lost'; fi

# The wrapper bounds the command with timeout -k 1 15; a stub records what it was
# handed so removing the bound fails here rather than going unnoticed.
mkdir -p "$TMP/tstub"
cat >"$TMP/tstub/timeout" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$TIMEOUT_ARGS"
shift 3
exec "$@"
EOF
chmod +x "$TMP/tstub/timeout"
: >"$TMP/timeout.args"
TIMEOUT_ARGS="$TMP/timeout.args" PATH="$TMP/tstub:$PATH" \
	nft_apply_locked bounded nft -f file >/dev/null 2>&1
if [ "$(head -3 "$TMP/timeout.args" | tr '\n' ' ')" = "-k 1 15 " ] &&
	[ "$(sed -n 4p "$TMP/timeout.args")" = nft ]; then
	ok 'the command is bounded by timeout -k 1 15'
else bad "the command bound changed: $(tr '\n' ' ' <"$TMP/timeout.args")"; fi

FAKE_RC=23 nft_apply_locked failing nft -f file 2>"$TMP/err"; rc=$?
if [ "$rc" -eq 23 ] && (exec 7>>"$SURFLARE_NFT_LOCK"; flock -n 7); then
	ok 'failing command status propagates and releases the lock immediately'
else bad 'command failure status or release was lost'; fi

# One argument: the wrapper's own arity check refuses it.
nft_apply_locked empty >"$TMP/empty" 2>&1; rc=$?
if [ "$rc" -eq 70 ]; then ok 'a command name with no arguments is rejected';
else bad 'a command name with no arguments was accepted'; fi
# Two arguments with an empty command: the wrapper passes the command through to
# timeout, which cannot exec it and returns 127. Pinning 127 says which layer failed;
# it is the same code a missing binary gives, so the assertion names the layer rather
# than claiming a wrapper refusal.
nft_apply_locked empty '' >"$TMP/empty2" 2>&1; rc=$?
if [ "$rc" -eq 127 ]; then ok 'an empty command name fails at the exec layer, not in the wrapper';
else bad "an empty command name failed somewhere unexpected [rc=$rc]"; fi
# No flock on PATH: the wrapper refuses instead of running the command unlocked.
mkdir -p "$TMP/noflock"
for t in bash sh timeout sed grep mkdir mktemp cat; do
	bin=$(command -v "$t") && ln -sf "$bin" "$TMP/noflock/$t"
done
PATH="$TMP/noflock" nft_apply_locked noflock nft -f file >"$TMP/noflock.out" 2>&1; rc=$?
# The refusal must come from the wrapper's own check, not from the shell failing to
# find flock: with the guard removed the same run still returns 70, but the shell's
# "not found" diagnostic reaches the caller.
if [ "$rc" -eq 70 ] && ! grep -qi 'not found' "$TMP/noflock.out"; then
	ok 'a missing flock is refused before the shell has to fail'
else bad "a missing flock was not refused cleanly [rc=$rc]"; fi
# Caller already holds descriptor 8: the wrapper must refuse the nested lock.
rc8=$( (exec 8>>"$SURFLARE_NFT_LOCK"; nft_apply_locked nested nft -f file >"$TMP/nested.out" 2>&1; echo $?) )
if [ "$rc8" -eq 70 ] && grep -q 'nested' "$TMP/nested.out"; then
	ok 'a caller already holding descriptor 8 is refused'
else bad "a nested descriptor 8 was not refused [rc=$rc8]"; fi

# A marker-file handshake bounds the holder: a fifo read blocks forever when the
# writer never writes, and a failure between the two ends must not hang the run.
(
	exec 7>>"$SURFLARE_NFT_LOCK"
	flock 7 || exit 1
	: > "$TMP/ready"
	# The only child of this subshell is a 0.05 s sleep, so killing the subshell
	# cannot leave a long-lived grandchild behind.
	while [ ! -e "$TMP/finish" ]; do sleep 0.05; done
) &
holder_pid=$!
_i=0
while [ ! -e "$TMP/ready" ]; do
	_i=$((_i + 1))
	if [ "$_i" -gt 200 ]; then bad 'lock holder never started'; break; fi
	sleep 0.05
done
: > "$FAKE_LOG"
# The call runs under a deadline of its own: a regression that makes the
# acquisition block must fail here, not stall the suite. A blocked bash cannot
# act on a signal while it waits on a child, so the deadline also escalates.
(
	export FAKE_LOG SURFLARE_NFT_LOCK PATH TMP
	_lock_raw=${_LOCK_CALL_SECS:-}
	case "$_lock_raw" in
	'' | *[!0-9]*) _lock_secs=10 ;;
	*) _lock_secs=$_lock_raw ;;
	esac
	timeout -k 2 "$_lock_secs" bash -c '
		. "$TMP/helpers"
		log() { printf "%s\n" "$*" >&2; }
		nft_apply_locked busy nft -f file
	' 2>"$TMP/busy"
); rc=$?
if [ "$rc" -eq 75 ] && [ ! -s "$FAKE_LOG" ] &&
	grep -q 'lock busy' "$TMP/busy"; then
	ok 'contention is distinct from failure and executes no command'
else bad 'contention executed a write or returned the wrong status'; fi
: > "$TMP/finish"
_i=0
while kill -0 "$holder_pid" 2>/dev/null; do
	_i=$((_i + 1))
	if [ "$_i" -gt 200 ]; then
		kill -9 "$holder_pid" 2>/dev/null || true
		bad 'lock holder did not exit'
		break
	fi
	sleep 0.05
done
wait "$holder_pid" 2>/dev/null || true
holder_pid=''

NFT_LOCK_FILE="$TMP/no-directory/lock" \
	nft_apply_locked bad nft -f file 2>"$TMP/open"; rc=$?
if [ "$rc" -eq 70 ]; then ok 'lock open error is not contention';
else bad 'lock open error was misclassified'; fi

if bash scripts/check-nft-locked-writes.sh "$WD" >"$TMP/gate" 2>&1; then
	ok 'exact source inventory matches its reviewed records'
else bad "inventory rejected source: $(<"$TMP/gate")"; fi
cp "$WD" "$TMP/new.sh"
printf '\n_install_killswitch () { nft -f /no/file || log failure; }\n' \
	>> "$TMP/new.sh"
if bash scripts/check-nft-locked-writes.sh "$TMP/new.sh" \
	--manifest scripts/nft-write-sites.json >"$TMP/gate2" 2>&1; then
	bad 'a new write inside an old function was accepted'
elif grep -q 'new site' "$TMP/gate2"; then
	ok 'new write is rejected even inside an old function with a log suffix'
else bad 'gate failed for the wrong reason'; fi
printf 'RESULT: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$pass" -eq 13 ]
