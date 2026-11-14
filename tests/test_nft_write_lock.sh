#!/bin/bash
# The daemon's whole-table nft writes share a lock with zoro-exit.  This drives
# the real helpers out of the production script against a fake nft that records
# whether the lock was held when it ran, and checks that a busy lock is a
# skipped write rather than a corrupt one.
set -u
cd "$(dirname "$0")/.." || exit 1
WD=${WD:-surflare_watchdog.sh}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

# Extract the lock helpers: NFT_LOCK_FILE= ... nft_apply_locked's closing brace.
awk '
	/^NFT_LOCK_FILE=/ { grab = 1 }
	grab { print }
	grab && /^nft_apply_locked\(\) \{/ { inapply = 1 }
	inapply && /^}$/ { exit }
' "$WD" > "$TMP/lock.sh"
if [ ! -s "$TMP/lock.sh" ] || ! grep -q 'nft_apply_locked' "$TMP/lock.sh"; then
	echo "FAIL: could not extract the lock helpers from $WD"
	echo "RESULT: 0 passed, 1 failed"
	exit 1
fi

mkdir -p "$TMP/bin"
cat > "$TMP/bin/nft" <<'EOS'
#!/bin/sh
# Answer the one question the test cares about: was the shared lock held while
# this ran?  A fresh fd on the same file conflicts with the holder, so a
# successful lock here means nobody was holding it.
exec 7>>"${FAKE_LOCK:?}" 2>/dev/null || exit 1
if flock -n 7 2>/dev/null; then
	_state=free
	flock -u 7 2>/dev/null
else
	_state=held
fi
exec 7>&-
printf 'nft %s lock=%s\n' "$*" "$_state" >> "${FAKE_LOG:?}"
exit "${FAKE_NFT_RC:-0}"
EOS
chmod +x "$TMP/bin/nft"

run_locked() { # $1 = label, rest = command; runs inside the extracted helpers
	PATH="$TMP/bin:$PATH" FAKE_LOG="$TMP/log" FAKE_LOCK="$TMP/lock" \
		SURFLARE_NFT_LOCK="$TMP/lock" bash -c '
		_dir=$2
		. "$1/lock.sh"
		# The script logs through log(); keep that going to the test log so the
		# WARN for a busy lock is observable.
		log() { printf "%s\n" "$*" >> "$_dir/log"; }
		shift 2
		nft_apply_locked "$@"
	' _ "$TMP" "$TMP" "$@" 2>"$TMP/err"
}

# 1: the command runs while the lock is held.
: > "$TMP/log"; : > "$TMP/err"
if run_locked "install" nft add rule inet t c; then
	if grep -q 'lock=held' "$TMP/log"; then
		ok "a locked write runs with the lock held"
	else
		bad "the write ran without the lock [$(cat "$TMP/log")]"
	fi
else
	bad "a locked write failed outright [$(cat "$TMP/err")]"
fi

# 2: a held lock means the write is skipped, not attempted anyway.
: > "$TMP/log"; : > "$TMP/err"
(
	flock -x 9
	sleep 8
) 9>>"$TMP/lock" &
_holder=$!
sleep 1
if run_locked "install" nft add rule inet t c; then
	bad "a busy lock still reported success"
else
	if grep -q '^nft ' "$TMP/log"; then
		bad "a busy lock let the write through [$(grep '^nft ' "$TMP/log")]"
	elif grep -q 'nft lock busy' "$TMP/log"; then
		ok "a busy lock skips the write and says so"
	else
		bad "a busy lock skipped the write silently [$(cat "$TMP/err")]"
	fi
fi
kill "$_holder" 2>/dev/null; wait "$_holder" 2>/dev/null

# 3: the fd is closed afterwards, so nothing inherits the lock.
: > "$TMP/log"
run_locked "install" nft add rule inet t c
if ( exec 9>>"$TMP/lock"; flock -n 9 ); then
	ok "the lock is released after the block"
else
	bad "the lock outlived the block"
fi

# 4: a failing command still releases the lock.
: > "$TMP/log"
FAKE_NFT_RC=1 run_locked "install" nft add rule inet t c
if ( exec 9>>"$TMP/lock"; flock -n 9 ); then
	ok "a failing write still releases the lock"
else
	bad "a failing write left the lock held"
fi

# 5: the ratchet gate still accounts for every destructive write.
if bash scripts/check-nft-locked-writes.sh "$WD" >"$TMP/gate" 2>&1; then
	ok "every destructive write is locked or accounted for [$(head -1 "$TMP/gate")]"
else
	bad "an unaccounted destructive write appeared: $(head -1 "$TMP/gate")"
fi

# 6: the gate notices a new unlocked site.
cp "$WD" "$TMP/wd_mut.sh"
printf '\n_new_writer() {\n\tnft -f /tmp/whatever.nft\n}\n' >> "$TMP/wd_mut.sh"
if bash scripts/check-nft-locked-writes.sh "$TMP/wd_mut.sh" >"$TMP/gate2" 2>&1; then
	bad "the gate accepted a new unlocked writer"
else
	ok "the gate rejects a new unlocked writer"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
