#!/bin/bash
# procd scans every file in /etc/init.d. A backup left there with START=99 is
# a second copy of a service, and enable or an upgrade that re-reads the
# directory will start the old one next to the current one. The cleaner has
# to remove those and leave the live script, which has the same name without
# the .bak suffix.
set -u
cd "$(dirname "$0")/.." || exit 1
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

SUT=scripts/surflare_drop_init_backups.sh
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

if [ -f "$SUT" ] && sh -n < "$SUT"; then
	ok "the cleaner parses"
else
	bad "the cleaner is missing or does not parse"
	echo "RESULT: $pass passed, $fail failed"
	exit 1
fi

mkdir -p "$TMP/init.d"
printf '#!/bin/sh\nSTART=99\n# live\n' > "$TMP/init.d/surflare-dedicated"
printf '#!/bin/sh\nSTART=99\n# old forwarder\n' > "$TMP/init.d/surflare-dedicated.bak-20812-20261016"
printf '#!/bin/sh\nSTART=99\n# old supervisor\n' > "$TMP/init.d/surflare-dedicated.bak-supervisor-20261018"
printf '#!/bin/sh\n# unrelated\n' > "$TMP/init.d/firewall"
chmod 755 "$TMP/init.d/"*

cat > "$TMP/ssh" <<EOS
#!/bin/bash
# Stand in for the router's ssh. Dropbear joins every argument after the
# host into one string and runs that, so a trailing word never becomes \\\$1
# of the remote script. OpenSSH would pass it separately; this stub must
# not, or the test passes a behaviour the router does not have.
cd "$TMP" || exit 1
shift 2
sh -c "\$*"
EOS
chmod +x "$TMP/ssh"

PATH="$TMP:$PATH" SSH_CMD="$TMP/ssh" REMOTE=fixture \
	sh "$SUT" --dir init.d > "$TMP/out" 2>&1
rc=$?
left=$(find "$TMP/init.d" -type f -printf '%f\n' | sort)
want=$(printf '%s\n' firewall surflare-dedicated)
if [ "$rc" -eq 0 ] && [ "$left" = "$want" ]; then
	ok "backups go, the live script and unrelated init scripts stay"
else
	bad "cleanup left [$left] rc=$rc"
fi

# A second run must be a no-op, and must still succeed.
PATH="$TMP:$PATH" SSH_CMD="$TMP/ssh" REMOTE=fixture \
	sh "$SUT" --dir init.d > "$TMP/out" 2>&1
rc=$?
left2=$(find "$TMP/init.d" -type f -printf '%f\n' | sort)
if [ "$rc" -eq 0 ] && [ "$left2" = "$want" ]; then
	ok "running it again changes nothing"
else
	bad "the second run changed the directory: [$left2] rc=$rc"
fi

# A directory whose name looks like a backup must not stop the cleanup.
# rm refuses a directory, and exiting there would leave the later file.
mkdir -p "$TMP/init.d/sub.bak-dir"
printf 'later\n' > "$TMP/init.d/surflare-dedicated.bak-later"
PATH="$TMP:$PATH" SSH_CMD="$TMP/ssh" REMOTE=fixture \
	sh "$SUT" --dir init.d > "$TMP/out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$TMP/init.d/surflare-dedicated.bak-later" ] \
	&& [ -d "$TMP/init.d/sub.bak-dir" ]; then
	ok "a same-named directory is left, and the backup after it is still removed"
else
	bad "a directory stopped the cleanup: rc=$rc $(ls "$TMP/init.d")"
fi

# A missing option argument is bad use, not an unbound-variable crash.
sh "$SUT" --dir > "$TMP/out" 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
	ok "an option without its value exits 2"
else
	bad "an option without its value exited $rc: $(cat "$TMP/out")"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
