#!/bin/bash
# The systemd-sleep wake hook must not be a no-op, and must not become a second
# writer next to the daemon.  This drives the real _enforce_singleton extracted
# from the production script against a private lock and pidfile.
set -u
cd "$(dirname "$0")/.." || exit 1
WD=${WD:-surflare_watchdog.sh}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass+1)); }
bad() { echo "FAIL: $*"; fail=$((fail+1)); }

FUNC=_enforce_singleton
awk -v fn="$FUNC" '
	index($0, fn "() {") == 1 { inside = 1 }
	inside { print }
	inside && /^}$/ { exit }
' "$WD" > "$TMP/funcs.sh"
if [ -s "$TMP/funcs.sh" ] && grep -q "^$FUNC() {" "$TMP/funcs.sh"; then
	ok "extracted $FUNC from $WD ($(wc -l < "$TMP/funcs.sh") lines)"
else
	bad "could not extract $FUNC"
	echo "RESULT: $pass passed, $fail failed"
	exit 1
fi

# Same guard, but with a canary in its own process group: a signal sent to
# group 0 lands here, so "the canary is alive" is the property under test.
cat > "$TMP/probe.sh" <<'EOS'
#!/bin/bash
sleep 300 &
canary=$!
_SINGLETON_LOCK="$1/lock" _SINGLETON_PIDFILE="$1/pid" \
	bash -c '. "$1/funcs.sh"; _enforce_singleton "$2"' _ "$1" "$2" >/dev/null 2>&1
if kill -0 "$canary" 2>/dev/null; then echo CANARY-ALIVE; else echo CANARY-KILLED; fi
kill "$canary" 2>/dev/null
EOS
chmod +x "$TMP/probe.sh"

run_guard() { # $1 = hook argument, cwd for the child is this test dir
	_SINGLETON_LOCK="$TMP/lock" _SINGLETON_PIDFILE="$TMP/pid" \
		bash -c '. "$1/funcs.sh"; _enforce_singleton "$2"' _ "$TMP" "$1"
}

# --- case 1: free lock, any argument -> proceeds ---------------------------
rm -f "$TMP/lock"
if run_guard "" >/dev/null 2>&1; then
	ok "a free lock lets the daemon start"
else
	bad "a free lock refused the daemon"
fi

# --- case 2: lock held, ordinary start -> refuse ---------------------------
exec 8>"$TMP/lock"
flock -n 8 || bad "test could not take the lock"
if run_guard "" >/dev/null 2>&1; then
	bad "a second daemon was allowed to start"
else
	ok "a held lock refuses a second daemon"
fi

# --- case 3: lock held, wake hook -> hand off and exit 0 -------------------
# The daemon is simulated by a reader that records the signal instead of dying.
cat > "$TMP/fake_daemon.sh" <<'EOS'
trap 'echo usr1 > "$1"' USR1
echo $$ > "$2"
while :; do sleep 0.2; done
EOS
mkdir -p "$TMP/wd"
cp "$TMP/fake_daemon.sh" "$TMP/wd/surflare_watchdog_fake.sh"
bash "$TMP/wd/surflare_watchdog_fake.sh" "$TMP/got" "$TMP/pid" &
daemon_pid=$!
sleep 0.5
if run_guard post >/dev/null 2>&1; then
	ok "the wake hook exits 0 instead of dying on the lock"
else
	bad "the wake hook still exits non-zero when the daemon holds the lock"
fi
sleep 0.5
if [ "$(cat "$TMP/got" 2>/dev/null)" = "usr1" ]; then
	ok "the wake hook handed the wake-up to the running instance"
else
	bad "the wake hook did not signal the running instance"
fi
kill "$daemon_pid" 2>/dev/null
wait "$daemon_pid" 2>/dev/null

# --- case 4: a bogus pidfile must not turn into a signal to nowhere -------
printf 'not-a-pid\n' > "$TMP/pid"
if run_guard post >/dev/null 2>&1; then
	ok "a malformed pidfile still exits 0 without signalling"
else
	bad "a malformed pidfile broke the wake hook"
fi

# --- case 5: the pre hook behaves the same way ----------------------------
printf '%s\n' "$daemon_pid" > "$TMP/pid"
: > "$TMP/got"
if run_guard pre >/dev/null 2>&1; then
	ok "the pre hook exits 0 when the daemon holds the lock"
else
	bad "the pre hook exits non-zero when the daemon holds the lock"
fi
sleep 0.5
if [ -s "$TMP/got" ]; then
	bad "the pre hook signalled the daemon (a health check can restart a reconnect mid-suspend)"
else
	ok "the pre hook leaves the daemon alone; only post delegates"
fi

# --- case 6: a stale pidfile must not become a signal to a stranger ------
# SIGUSR1 terminates by default, and the pidfile is rewritten late in startup
# while this guard runs early, so a stale pid is a real case.
sleep 30 &
stranger=$!
printf '%s\n' "$stranger" > "$TMP/pid"
if run_guard post >/dev/null 2>&1; then
	ok "a stale pidfile does not fail the hook"
else
	bad "a stale pidfile broke the hook"
fi
sleep 0.3
if kill -0 "$stranger" 2>/dev/null; then
	ok "an unrelated process holding the stale pid is not signalled"
else
	bad "the hook killed an unrelated process through a stale pidfile"
fi
kill "$stranger" 2>/dev/null

# --- case 7: pid 0 would signal the caller's whole process group ---------
# pid 0 makes kill signal the caller's own process group, so "exit 0" is not
# the property that matters: a canary in the hook's group has to survive.
for bogus in 0 1; do
	printf '%s\n' "$bogus" > "$TMP/pid"
	out=$(setsid --wait bash "$TMP/probe.sh" "$TMP" post 2>/dev/null)
	if printf '%s' "$out" | grep -q 'CANARY-ALIVE'; then
		ok "pid ${bogus} is refused rather than signalled"
	else
		bad "pid ${bogus} signalled the caller's process group"
	fi
done

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]