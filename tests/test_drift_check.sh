#!/bin/bash
# The drift check exists because a routine deploy reported success while the
# router ran an updater four months older than the tree.  It is worth nothing
# if it cannot see that, so each case below hands it a remote that is wrong in
# exactly one way.
set -u
cd "$(dirname "$0")/.." || exit 1
CHECK=${CHECK:-scripts/surflare_drift_check.sh}
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# A remote that answers whatever the case file says.
cat > "$TMP/bin/ssh" <<'EOS'
#!/bin/bash
cat "$FAKE_REMOTE"
EOS
chmod +x "$TMP/bin/ssh"

# The same remote, but reporting the way a real md5sum does when one path is
# absent: it prints the rest and exits 1.
cat > "$TMP/bin/ssh_partial" <<'EOS'
#!/bin/bash
cat "$FAKE_REMOTE"
exit 1
EOS
chmod +x "$TMP/bin/ssh_partial"

# What the box would print if it matched this tree exactly -- derived from the
# list the tool itself reads.  A hand-written mirror here went stale the moment
# a file was added to the list, and it made the test lie about a correct tool.
: > "$TMP/match.txt"
while IFS= read -r line; do
	case "$line" in ''|'#'*) continue ;; esac
	local_path=${line%%:*}
	rest=${line#*:}
	remote_path=${rest%%:*}
	local_path=${local_path//@MODE@/rule}
	[ -f "$local_path" ] || continue
	printf '%s  %s\n' "$(md5sum "$local_path" | cut -d' ' -f1)" "$remote_path" >> "$TMP/match.txt"
done < scripts/installed-files.list

drive() { # $1 = remote file, $2 = optional ssh that fails
	# MODE is explicit: the checksums above are built from router/rule/, and
	# relying on the SUT default would make a changed default look like drift.
	PATH="$TMP/bin:$PATH" FAKE_REMOTE="$1" SSH_CMD="${2:-ssh}" MODE=rule bash "$CHECK" > "$TMP/out" 2>&1
	echo $?
}

rc=$(drive "$TMP/match.txt")
if [ "$rc" -eq 0 ] && grep -q 'box matches this tree' "$TMP/out"; then
	ok "a box that matches is reported as matching"
else
	bad "a matching box was reported as drifted (rc=$rc): $(tail -1 "$TMP/out")"
fi

# One file four months behind: exactly what was found on the router.
sed 's|^[0-9a-f]*  /usr/local/sbin/surflare-update.sh|00000000000000000000000000000000  /usr/local/sbin/surflare-update.sh|' \
	"$TMP/match.txt" > "$TMP/drift.txt"
rc=$(drive "$TMP/drift.txt")
if [ "$rc" -eq 1 ] && grep -q 'DRIFT' "$TMP/out" && grep -q 'surflare-update.sh' "$TMP/out"; then
	ok "a stale updater is reported as drift"
else
	bad "a stale updater was not reported (rc=$rc)"
fi

# A file the box does not have at all.
grep -v '/etc/surflare-lan-tproxy.nft' "$TMP/match.txt" > "$TMP/missing.txt"
rc=$(drive "$TMP/missing.txt")
if [ "$rc" -eq 1 ] && grep -q 'MISSING-ON-BOX' "$TMP/out"; then
	ok "a file that is not installed is reported as missing"
else
	bad "an absent file was not reported (rc=$rc)"
fi

# The same absent file, reported by a remote that exits non-zero the way a real
# md5sum does.  The verdict must still be MISSING-ON-BOX: a tool that answers
# "could not check" here answers that on every box that is actually damaged.
rc=$(drive "$TMP/missing.txt" "$TMP/bin/ssh_partial")
if [ "$rc" -eq 1 ] && grep -q 'MISSING-ON-BOX' "$TMP/out"; then
	ok "a partial answer from a real md5sum still names the missing file"
else
	bad "a partial md5sum output became a tool failure (rc=$rc): $(tail -1 "$TMP/out")"
fi

# A remote that cannot answer must not look like a clean box.
printf '#!/bin/bash\nexit 255\n' > "$TMP/bin/ssh_fail"
chmod +x "$TMP/bin/ssh_fail"
rc=$(drive "$TMP/match.txt" "$TMP/bin/ssh_fail")
if [ "$rc" -eq 2 ]; then
	ok "an unreachable box is an error, not a pass"
else
	bad "an unreachable box returned rc=$rc"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
