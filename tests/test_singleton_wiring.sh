#!/bin/bash
# The singleton guard is the only thing between one watchdog and two writing
# nft state at the same time.  Every other assertion extracts _enforce_singleton
# and calls it directly, so the wiring -- that the daemon calls it, and that its
# refusal ends the process -- went unchecked: turning the body's exit 1 into
# return 1 and appending `|| true` at the call site started a second daemon with
# the whole suite green.
#
# This starts the real script in daemon mode while the test holds the lock.  A
# non-zero exit alone would also come from the dependency gate, so the refusal
# has to be identified, and the daemon's first act after the guard is used as a
# probe that it never got past it.
set -u
cd "$(dirname "$0")/.." || exit 1
WD=${WD:-surflare_watchdog.sh}
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

if ! unshare -Urmn true 2>/dev/null; then
	echo "SKIP: user namespaces unavailable, cannot exercise the daemon"
	echo "RESULT: SKIP - nothing was verified"
	exit 2
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Everything the dependency gate names that the box may not have.  flock and
# timeout stay real: a stubbed timeout returns 0 without running the daemon,
# and a stubbed flock takes the lock out of the test.  nm-online is left absent
# on purpose -- the daemon announces its absence right after the guard.
for stub in logger killall pgrep curl surflare surflare-proxy ss jq; do
	printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/$stub"
done
printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/nft"
printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/ip"
chmod +x "$TMP/bin/"*

cp "$WD" "$TMP/wd.sh"

cat > "$TMP/inner.sh" <<'EOS'
mount -t tmpfs none /run 2>/dev/null
: > "$1/kmsg"
mount --bind "$1/kmsg" /dev/kmsg 2>/dev/null
exec 9>/run/surflare_watchdog.singleton.lock
/usr/bin/flock -n 9 || { echo "HARNESS: could not take the lock"; exit 9; }
export PATH="$1/bin:/usr/bin:/bin"
timeout 6 bash "$1/wd.sh" > "$1/start.log" 2>&1
echo "rc=$?"
[ -f /run/surflare_watchdog.pid ] && echo "pidfile=written" || echo "pidfile=absent"
EOS

out=$(unshare -Urmn bash "$TMP/inner.sh" "$TMP" 2>/dev/null)
rc=$(printf '%s\n' "$out" | sed -n 's/^rc=//p')
echo "  harness: $(printf '%s' "$out" | tr '\n' ' ')"

if printf '%s' "$out" | grep -q 'HARNESS:'; then
	bad "the harness could not take the lock, nothing was tested"
else
	if [ -n "$rc" ] && [ "$rc" != 0 ] && [ "$rc" != 124 ]; then
		ok "a second daemon does not start while the lock is held"
	else
		bad "a second daemon ran with the lock held (rc=${rc:-?})"
	fi
	if grep -q 'another instance is running' "$TMP/kmsg" "$TMP/start.log" 2>/dev/null; then
		ok "the refusal came from the singleton guard, not from the dependency gate"
	else
		bad "no singleton refusal in the log: $(grep -v '^+' "$TMP/start.log" 2>/dev/null | tail -2)"
	fi
	if grep -q 'missing dependency' "$TMP/kmsg" "$TMP/start.log" 2>/dev/null; then
		bad "the dependency gate refused before the guard was reached"
	else
		ok "the dependency gate did not pre-empt the guard"
	fi
	if printf '%s' "$out" | grep -q 'pidfile=absent'; then
		ok "the refused instance wrote no pidfile"
	else
		bad "the refused instance wrote the pidfile"
	fi
	# Anything after the refusal means the process survived it: the guard's
	# exit is terminal, a guard that returns is not.
	last=$(grep 'surflare_watchdog:' "$TMP/kmsg" 2>/dev/null | tail -1)
	case "$last" in
	*'another instance is running'*)
		ok "the refusal ended the process: nothing follows it in the log" ;;
	*)
		bad "the daemon carried on after the guard refused: ${last:-no log}" ;;
	esac
	if grep -q 'nm-online not found' "$TMP/kmsg" 2>/dev/null; then
		bad "the daemon continued past the guard into startup"
	else
		ok "the daemon never reached startup after the guard refused"
	fi
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]