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

# What the box would print if it matched this tree exactly.
{
	for f in surflare_watchdog.sh surflare_l4_probe.sh surflare_log_health.sh \
		surflare-update.sh cross_validate_routes.py setup_auth.sh; do
		printf '%s  /usr/local/sbin/%s\n' "$(md5sum "$f" | cut -d' ' -f1)" "$f"
	done
	printf '%s  %s\n' "$(md5sum router/services/procd/surflare-watchdog | cut -d' ' -f1)" \
		/etc/init.d/surflare-watchdog
	printf '%s  %s\n' "$(md5sum router/surflare_route_updater.sh | cut -d' ' -f1)" \
		/usr/local/sbin/surflare_route_updater.sh
	printf '%s  %s\n' "$(md5sum router/ripe_fetch.py | cut -d' ' -f1)" \
		/usr/local/sbin/ripe_fetch.py
	printf '%s  %s\n' "$(md5sum router/rule/surflare-lan-tproxy.nft | cut -d' ' -f1)" \
		/etc/surflare-lan-tproxy.nft
} > "$TMP/match.txt"

drive() { # $1 = remote file, $2 = optional ssh that fails
	PATH="$TMP/bin:$PATH" FAKE_REMOTE="$1" SSH_CMD="${2:-ssh}" bash "$CHECK" > "$TMP/out" 2>&1
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
