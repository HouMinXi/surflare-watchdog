#!/bin/bash
# The stop marker was read by the early detector and by the resurrect cron,
# and written by nothing: a deliberate stop was undone by the next five-minute
# tick.  The init script owns it now, and these tests drive the real functions.
set -u
cd "$(dirname "$0")/.." || exit 1
INIT=${INIT:-router/services/procd/surflare-watchdog}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

for fn in start_service stop_service restart; do
	awk -v fn="$fn" '
		$0 ~ "^" fn "\\(\\) \\{" { i = 1 }
		i { print }
		i && /^}$/ { exit }
	' "$INIT" > "$TMP/$fn.sh"
	if [ ! -s "$TMP/$fn.sh" ] || [ "$(wc -l < "$TMP/$fn.sh")" -gt 80 ]; then
		echo "FAIL: could not extract $fn from $INIT"
		echo "RESULT: 0 passed, 1 failed"
		exit 1
	fi
done

drive() { # $1 = function name, $2 = dir holding the markers
	bash -c '
		set -u
		RESTART_MARKER="$2/surflare_watchdog.restart"
		RESTARTING_FLAG="$2/surflare_restarting"
		STOPPED_MARKER="$2/surflare_watchdog.stopped"
		RESTART_MARKER_FILE=""
		procd_open_instance() { :; }
		procd_set_param() { :; }
		procd_close_instance() { :; }
		procd_kill() { :; }
		_full_teardown() { :; }
		_find_orphans() { :; }
		timeout() { shift; "$@"; }
		killall() { :; }
		pgrep() { return 1; }
		surflare() { :; }
		echo $$ > "$2/watchdog.pid"
		. "$1/$3.sh"
		"$3"
	' _ "$TMP" "$2" "$1" >/dev/null 2>&1
}

# --- case 1: an explicit stop records itself -----------------------------
d="$TMP/case1"
mkdir -p "$d"
drive stop_service "$d"
if [ -f "$d/surflare_watchdog.stopped" ]; then
	ok "an explicit stop writes the marker the cron and the detector read"
else
	bad "an explicit stop left no marker: the next cron tick resurrects the stack"
fi

# --- case 2: a restart must not -----------------------------------------
d="$TMP/case2"
mkdir -p "$d"
touch "$d/surflare_restarting"
drive stop_service "$d"
if [ -f "$d/surflare_watchdog.stopped" ]; then
	bad "a restart wrote the stop marker: a restart would take the stack down for good"
else
	ok "a restart leaves no stop marker"
fi

# --- case 3: a start clears a previous stop -----------------------------
d="$TMP/case3"
mkdir -p "$d"
touch "$d/surflare_watchdog.stopped"
drive start_service "$d"
if [ -f "$d/surflare_watchdog.stopped" ]; then
	bad "a start left the stop marker in place: the stack runs while the cron thinks it is stopped"
else
	ok "a start clears the stop marker"
fi

# --- case 4: restart actually restarts ------------------------------------
# The default for the restart flag was written as a self-reference, so it
# expanded to nothing: touch "" failed, restart returned 1, and the deploy
# script -- which uses set -e -- aborted after the scp had already replaced
# the file, leaving the old process running the old code.
d="$TMP/case4"
mkdir -p "$d"
if grep -qE '^RESTARTING_FLAG=\$\{RESTARTING_FLAG:-/run/surflare_restarting\}$' "$INIT"; then
	ok "the restart flag defaults to a real path"
else
	bad "the restart flag default is not a path: $(grep -m1 '^RESTARTING_FLAG=' "$INIT")"
fi
: > "$d/calls"
bash -c '
	set -u
	D="$2"
	RESTARTING_FLAG="$D/surflare_restarting"
	STOPPED_MARKER="$D/surflare_watchdog.stopped"
	logger() { :; }
	procd_kill() { :; }
	stop() { printf "STOP\n" >> "$D/calls"; }
	start() { printf "START\n" >> "$D/calls"; }
	pgrep() { return 1; }
	. "$1/restart.sh"
	restart
' _ "$TMP" "$d" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
	ok "restart returns success"
else
	bad "restart returned ${rc}: the flag it writes is unusable"
fi
# Two stop calls is not a bounce.
if grep -q '^STOP$' "$d/calls" && grep -q '^START$' "$d/calls"; then
	ok "restart invokes both stop and start"
else
	bad "restart did not bounce the service ($(tr '\n' ' ' < "$d/calls"))"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]