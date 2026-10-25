#!/bin/bash
# After a clean flash, "did every file land, with the right mode, and did the
# services get enrolled" is the whole question. A file that is present but not
# enabled is exactly the state this box sat in for months.
set -u
cd "$(dirname "$0")/.." || exit 1
SUT=${SUT:-scripts/surflare_reinstall_router.sh}
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/scp" <<'EOS'
#!/bin/bash
printf 'scp %s\n' "$*" >> "$CALLS"
EOS
cat > "$TMP/bin/ssh" <<'EOS'
#!/bin/bash
printf 'ssh %s\n' "$*" >> "$CALLS"
EOS
chmod +x "$TMP/bin/scp" "$TMP/bin/ssh"

drive() { # extra args
	CALLS="$TMP/calls" PATH="$TMP/bin:$PATH" SCP_CMD=scp SSH_CMD=ssh \
		bash "$SUT" "$@" > "$TMP/out" 2>&1
	echo $?
}

: > "$TMP/calls"
rc=$(drive --dry-run)
n_list=$(grep -vc '^#\|^$' scripts/installed-files.list)
n_out=$(grep -c '^would install' "$TMP/out")
if [ "$rc" -eq 0 ] && [ "$n_out" -eq "$n_list" ]; then
	ok "the dry run covers every file in the shared list ($n_out)"
else
	bad "dry run planned $n_out of $n_list files (rc=$rc)"
fi
if [ ! -s "$TMP/calls" ]; then
	ok "a dry run touches nothing"
else
	bad "a dry run still ran remote commands"
fi

: > "$TMP/calls"
rc=$(drive)
if [ "$rc" -eq 0 ]; then
	ok "a clean install reports success"
else
	bad "a clean install returned rc=$rc"
fi

n_scp=$(grep -c '^scp ' "$TMP/calls")
if [ "$n_scp" -eq "$n_list" ]; then
	ok "every file is copied exactly once ($n_scp)"
else
	bad "copied $n_scp files for a $n_list file list"
fi

if grep 'chmod 644' "$TMP/calls" | grep -q '13-netdev-backlog.conf'; then
	ok "the sysctl drop-in is installed as data, not as a program"
else
	bad "the sysctl drop-in got the executable mode"
fi

for want in 'surflare-watchdog enable' 'surflare-rps-assert enable' \
	'surflare_rps_assert' 'sysupgrade.conf' 'surflare-watchdog restart'; do
	if grep -q "$want" "$TMP/calls"; then
		ok "the install enrols: $want"
	else
		bad "the install never enrols: $want"
	fi
done

: > "$TMP/calls"
rc=$(drive --no-restart)
if [ "$rc" -eq 0 ] && ! grep -q 'restart' "$TMP/calls"; then
	ok "--no-restart leaves a running proxy alone"
else
	bad "--no-restart still restarted something"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]