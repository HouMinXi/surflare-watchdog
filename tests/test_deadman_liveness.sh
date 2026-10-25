#!/bin/bash
# deadman is the only automatic remover of an orphan killswitch: the daemon is
# dead, its table is not, and the LAN sits behind a block that nothing will
# lift.  It used to decide "the daemon is alive" from a command-line substring,
# which any fork of the daemon satisfies -- including the orphan it is looking
# at -- so the one state it exists for read as healthy.
#
# The lock is the daemon's own answer to "am I the only one", so it is the one
# asked here.  The init script hardcodes /run, so every case runs in a private
# mount namespace with its own /run.
set -u
cd "$(dirname "$0")/.." || exit 1
INIT=${INIT:-router/services/procd/surflare-watchdog}
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

if ! unshare -Urmn true 2>/dev/null; then
	echo "SKIP: user namespaces unavailable, cannot own /run"
	echo "RESULT: SKIP - nothing was verified"
	exit 2
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
sed -n '/^deadman() {/,/^}/p' "$INIT" > "$TMP/deadman.sh"
if [ ! -s "$TMP/deadman.sh" ]; then
	bad "could not extract deadman from $INIT"
	echo "RESULT: $pass passed, $fail failed"
	exit 1
fi

# $1 lock|none   $2 live|dead|none   $3 orphan|none
run_case() {
	: > "$TMP/evidence"
	unshare -Urmn bash -c '
		mount -t tmpfs none /run 2>/dev/null
		printf "%s\n" "_full_teardown() { printf \"TORN\\n\" >> \"$1/evidence\"; }" > /run/td.sh
		printf "%s\n" "log() { :; }" >> /run/td.sh
		. /run/td.sh
		. "$1/deadman.sh"
		if [ "$2" = lock ]; then
			exec 9>/run/surflare_watchdog.singleton.lock
			/usr/bin/flock -n 9 || exit 9
		fi
		case "$3" in
		live) printf "%s\n" "$$" > /run/surflare_watchdog.pid ;;
		dead) printf "%s\n" 999999 > /run/surflare_watchdog.pid ;;
		esac
		# deadman only acts when the killswitch table is there, so the case has
		# to own one; real nft in the net namespace is the honest way.
		nft add table inet killswitch 2>/dev/null
		if [ "$4" = orphan ]; then bash -c "sleep 20" surflare_watchdog.sh & fi
		deadman
	' _ "$TMP" "$1" "$2" "$3" >/dev/null 2>&1
	if [ -s "$TMP/evidence" ]; then echo torn; else echo kept; fi
}

if ! unshare -Urmn sh -c 'nft add table inet killswitch' 2>/dev/null; then
	echo "SKIP: cannot create an nft table in this environment"
	echo "RESULT: SKIP - nothing was verified"
	exit 2
fi

got=$(run_case none dead orphan)
[ "$got" = torn ] && ok "an argv-only orphan gets the killswitch removed" \
	|| bad "an orphan-only machine was read as alive (killswitch kept)"

got=$(run_case lock dead none)
[ "$got" = kept ] && ok "a held lock keeps the killswitch" \
	|| bad "the killswitch was torn down under a live daemon"

got=$(run_case lock none none)
[ "$got" = kept ] && ok "a held lock outranks a missing pidfile" \
	|| bad "a deleted pidfile overrode a live daemon"

got=$(run_case none live none)
[ "$got" = kept ] && ok "a live pid keeps the killswitch" \
	|| bad "a live pidfile did not stop the teardown"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
