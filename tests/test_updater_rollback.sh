#!/bin/bash
# The daily updater runs a vendor installer as root and replaces both binaries
# in place.  These tests drive the real script with stubs on PATH and assert
# the three properties that keep a bad release from leaving a headless box
# without a working proxy.
set -u
cd "$(dirname "$0")/.." || exit 1
SUT=${SUT:-surflare-update.sh}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

make_stubs() { # $1 = installer body file
	mkdir -p "$TMP/bin"
	cat > "$TMP/bin/curl" <<EOS
#!/bin/bash
while [ "\$#" -gt 0 ]; do
	case "\$1" in
	-o) shift; out="\$1" ;;
	esac
	shift
done
cp "$TMP/installer.sh" "\$out" || exit 22
exit 0
EOS
	cat > "$TMP/bin/logger" <<EOS
#!/bin/bash
printf 'LOG: %s\n' "\$*" >> "$TMP/events"
EOS
	cat > "$TMP/bin/systemctl" <<EOS
#!/bin/bash
printf 'SYSTEMCTL: %s\n' "\$*" >> "$TMP/events"
case "\$*" in
*restart*) [ -f "$TMP/restart_fail" ] && exit 1 ;;
esac
exit 0
EOS
	cat > "$TMP/bin/pgrep" <<EOS
#!/bin/bash
[ -f "$TMP/proxy_up" ]
EOS
	chmod +x "$TMP/bin/"*
}

write_installer() { # $1 = what the "new" proxy binary should contain
	cat > "$TMP/installer.sh" <<EOS
#!/bin/bash
printf 'INSTALLER-RAN\\n' >> "$TMP/events"
printf '%s\\n' '$1' > "\$PROXY_BIN"
printf '%s\\n' 'cli-new' > "\$CLI_BIN"
EOS
	# the updater refuses a script under 500 bytes
	while [ "$(stat -c%s "$TMP/installer.sh")" -lt 520 ]; do
		echo "# padding to clear the minimum size check" >> "$TMP/installer.sh"
	done
	chmod +x "$TMP/installer.sh"
}

run_updater() {
	PATH="$TMP/bin:$PATH" \
	PROXY_BIN="$TMP/proxy" CLI_BIN="$TMP/cli" PATCHED_BIN="$TMP/patched" REAL_BIN="$TMP/real" \
	SNAP_ROOT="$TMP/snaps" SERVICE=surflare-watchdog READY_TIMEOUT=2 \
	SURFLARE_UPDATE_ALLOW_NONROOT=1 \
	bash "$SUT" > "$TMP/stdout" 2>&1
}

reset_state() {
	: > "$TMP/events"
	rm -rf "$TMP/snaps" "$TMP/proxy_orig"
	printf '%s\n' 'proxy-original' > "$TMP/proxy"
	printf '%s\n' 'cli-original' > "$TMP/cli"
	cp "$TMP/proxy" "$TMP/proxy_orig"
	rm -f "$TMP/proxy_up" "$TMP/restart_fail"
	printf '%s\n' 'real-original' > "$TMP/real"
}

# --- case 1: a good release is installed and the proxy comes up -----------
reset_state
write_installer "proxy-new"
make_stubs "$TMP/installer.sh"
touch "$TMP/proxy_up"
if run_updater; then
	ok "a good release completes"
else
	bad "a good release failed: $(tail -2 "$TMP/events")"
fi
if grep -q 'Update complete, proxy is running' "$TMP/events"; then
	ok "the run reports the proxy is running"
else
	bad "no success line: $(cat "$TMP/events")"
fi
if [ "$(cat "$TMP/proxy")" = "proxy-new" ]; then
	ok "the new binary is in place"
else
	bad "the binary was not replaced"
fi
if [ -d "$TMP/snaps" ] && [ -n "$(ls -A "$TMP/snaps" 2>/dev/null)" ]; then
	ok "a snapshot was kept for the next run"
else
	bad "no snapshot was kept"
fi
if grep -q 'rolling back' "$TMP/events"; then
	bad "a good release was rolled back"
else
	ok "no rollback on a good release"
fi

# --- case 2: the digest is logged before the installer runs --------------
sha_line=$(grep -n 'Installer .* sha256=' "$TMP/events" | head -1 | cut -d: -f1)
ran_line=$(grep -n 'INSTALLER-RAN' "$TMP/events" | head -1 | cut -d: -f1)
if [ -n "$sha_line" ] && [ -n "$ran_line" ] && [ "$sha_line" -lt "$ran_line" ]; then
	ok "the installer digest is recorded before the installer runs"
else
	bad "digest logged after execution (sha at ${sha_line:-?}, ran at ${ran_line:-?})"
fi
if grep -q 'unsigned; vendor publishes no digest' "$TMP/events"; then
	ok "the log states the installer is unsigned"
else
	bad "the log does not admit the installer is unsigned"
fi

# --- case 3: a release that never comes up is rolled back ----------------
reset_state
write_installer "proxy-broken"
make_stubs "$TMP/installer.sh"
# proxy_up stays absent: the new binary starts and dies, which looks like a
# successful install from the exit code alone
if run_updater; then
	bad "the updater reported success for a proxy that never came up"
else
	ok "the updater fails when the proxy does not come up"
fi
if grep -q 'rolling back' "$TMP/events"; then
	ok "the rollback path ran"
else
	bad "no rollback: $(cat "$TMP/events")"
fi
if [ "$(cat "$TMP/proxy")" = "$(cat "$TMP/proxy_orig")" ]; then
	ok "the previous binary was restored"
else
	bad "the broken binary was left in place"
fi
if [ "$(grep -c 'SYSTEMCTL: restart' "$TMP/events")" -ge 2 ]; then
	ok "the service was restarted again after the rollback"
else
	bad "no restart after rollback"
fi

# --- case 4: an unchanged release keeps no snapshot ----------------------
reset_state
cat > "$TMP/installer.sh" <<EOS
#!/bin/bash
printf 'INSTALLER-RAN\n' >> "$TMP/events"
EOS
while [ "$(stat -c%s "$TMP/installer.sh")" -lt 520 ]; do
	echo "# padding to clear the minimum size check" >> "$TMP/installer.sh"
done
make_stubs "$TMP/installer.sh"
touch "$TMP/proxy_up"
if run_updater; then
	ok "an unchanged release exits cleanly"
else
	bad "an unchanged release failed"
fi
if grep -q 'No change' "$TMP/events"; then
	ok "an unchanged release reports no change"
else
	bad "no 'No change' line: $(cat "$TMP/events")"
fi
if [ -n "$(ls -A "$TMP/snaps" 2>/dev/null)" ]; then
	bad "a snapshot was kept for a run that changed nothing"
else
	ok "no snapshot is left behind when nothing changed"
fi

# --- case 5: a restart that fails must not read as a successful update ----
# The old proxy is still alive after a failed restart, so a liveness check
# passes and the update would report success over a restart that never ran.
reset_state
write_installer "proxy-broken"
make_stubs "$TMP/installer.sh"
touch "$TMP/proxy_up" "$TMP/restart_fail"
if run_updater; then
	bad "the updater reported success although the restart failed"
else
	ok "a failed restart fails the update"
fi
if [ "$(cat "$TMP/proxy")" = "$(cat "$TMP/proxy_orig")" ]; then
	ok "a failed restart rolls the binaries back"
else
	bad "the new binary stayed after a failed restart"
fi
if grep -q 'rc=0' "$TMP/events"; then
	bad "the failure was logged as rc=0"
else
	ok "the restart failure is logged with its real status"
fi

# --- case 6: the snapshot covers the binary the wrapper execs ------------
reset_state
write_installer "proxy-new"
make_stubs "$TMP/installer.sh"
touch "$TMP/proxy_up"
run_updater || true
snap=$(ls -d "$TMP"/snaps/* 2>/dev/null | head -1)
if [ -n "$snap" ] && [ -f "$snap/real" ]; then
	ok "the snapshot holds the real proxy binary"
else
	bad "the snapshot omits the binary the wrapper execs"
fi

# --- case 7: no snapshot at all must say so -----------------------------
# set -e made the bare restore call exit the script, so every branch that
# reports the outcome was dead code and the run died with status 2.
reset_state
write_installer "proxy-broken"
make_stubs "$TMP/installer.sh"
touch "$TMP/restart_fail"
printf 'x\n' > "$TMP/blocker"
PATH="$TMP/bin:$PATH" \
PROXY_BIN="$TMP/proxy" CLI_BIN="$TMP/cli" PATCHED_BIN="$TMP/patched" REAL_BIN="$TMP/real" \
SNAP_ROOT="$TMP/blocker/snaps" SERVICE=surflare-watchdog READY_TIMEOUT=1 \
SURFLARE_UPDATE_ALLOW_NONROOT=1 \
	bash "$SUT" > "$TMP/stdout" 2>&1
rc=$?
if [ "$rc" -eq 1 ]; then
	ok "a run with no rollback point exits 1"
else
	bad "a run with no rollback point exited ${rc}"
fi
if grep -q 'no snapshot to roll back to' "$TMP/events"; then
	ok "the log says there was no snapshot"
else
	bad "the absent-snapshot path logged nothing: $(tail -2 "$TMP/events")"
fi

# --- case 8: a failed restart ends with a start attempt -----------------
# restart is stop then start; when it fails inside the start the unit is
# inactive with the old binaries back on disk and nothing running.
reset_state
write_installer "proxy-new"
make_stubs "$TMP/installer.sh"
touch "$TMP/restart_fail"
rm -f "$TMP/proxy_up"
run_updater
if grep -q 'SYSTEMCTL: start surflare-watchdog' "$TMP/events"; then
	ok "a start is attempted after the rollback"
else
	bad "the box was left with no daemon after a failed restart: $(grep SYSTEMCTL "$TMP/events" | tr '\n' ' ')"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]