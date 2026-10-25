#!/bin/bash
# Every file the tree installs has to survive the next sysupgrade. Before this
# existed, three of them did not, and a reboot test could never have shown it:
# reboots keep everything, upgrades keep a list.
set -u
cd "$(dirname "$0")/.." || exit 1
SUT=${SUT:-scripts/surflare_upgrade_audit.sh}
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/ssh" <<'EOS'
#!/bin/bash
cat "$FAKE_KEEP"
EOS
chmod +x "$TMP/bin/ssh"
printf '#!/bin/bash\nexit 255\n' > "$TMP/bin/ssh_fail"
chmod +x "$TMP/bin/ssh_fail"

drive() { # $1 = keep file, $2 = ssh command
	PATH="$TMP/bin:$PATH" FAKE_KEEP="$1" SSH_CMD="${2:-ssh}" bash "$SUT" > "$TMP/out" 2>&1
	echo $?
}

# A box that keeps the whole of /usr/local/sbin and the three /etc paths.
cat > "$TMP/keep-all" <<'EOF'
# comment
/usr/local/sbin/
/etc/init.d/surflare-watchdog
/etc/init.d/surflare-rps-assert
/etc/hotplug.d/net/30-rps-wan-eth0
/etc/sysctl.d/13-netdev-backlog.conf
/etc/surflare-lan-tproxy.nft
EOF
rc=$(drive "$TMP/keep-all")
if [ "$rc" -eq 0 ] && grep -q 'would keep all' "$TMP/out"; then
	ok "a box that keeps everything is reported as safe"
else
	bad "a fully covered box returned rc=$rc: $(tail -1 "$TMP/out")"
fi

# The exact state found on 2026-10-25: the init script and the two tuning files
# were on no list at all.
grep -v -e '/etc/init.d/surflare-rps-assert' -e 'hotplug' -e 'sysctl.d' \
	"$TMP/keep-all" > "$TMP/keep-old"
rc=$(drive "$TMP/keep-old")
if [ "$rc" -eq 1 ] && [ "$(grep -c 'WOULD-BE-LOST' "$TMP/out")" -eq 3 ]; then
	ok "the three files that were missing from the keep list are named"
else
	bad "expected 3 lost files, got rc=$rc and $(grep -c 'WOULD-BE-LOST' "$TMP/out")"
fi

# A file kept by an exact directory entry must not be counted twice or missed.
: > "$TMP/keep-dir"
rc=$(drive "$TMP/keep-dir" 2>/dev/null)
if [ "$rc" -eq 2 ]; then
	ok "an empty keep list is treated as unreadable, not as a pass"
else
	bad "an empty keep list returned rc=$rc"
fi

rc=$(drive "$TMP/keep-all" "$TMP/bin/ssh_fail")
if [ "$rc" -eq 2 ]; then
	ok "an unreachable box cannot report itself as upgrade-safe"
else
	bad "an unreachable box returned rc=$rc"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
