#!/bin/sh
# Run the i226 NVM verifier against a fake board.
#
# The failures this test exists for are not arithmetic: they are the
# ones where the tool answered a different question than the operator
# asked -- a LAN port whose peer rebooted called an NVM regression, or a
# failing hourly run that left no trace because the cron line redirects
# to nothing and the script wrote its verdict to stdout only.
set -u
cd "$(dirname "$0")/.." || exit 1

SUT=./scripts/i226-verify
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# --- fake board -------------------------------------------------------
mkboard() {
	rm -rf "$TMP/net"
	for p in eth0 eth1 eth2 eth3; do
		mkdir -p "$TMP/net/$p/device"
		ln -sf "/drivers/igc" "$TMP/net/$p/device/driver"
		echo 0 > "$TMP/net/$p/carrier_changes"
	done
}
mkboard

mkdir -p "$TMP/bin"
cat > "$TMP/bin/ethtool" <<'EOS'
#!/bin/sh
case "$1" in
-i) echo "driver: igc"; echo "firmware-version: ${FW_OVERRIDE:-2032:88b6}" ;;
-S) case "$2" in *missing*) echo "" ;; *) echo "rx_crc_errors: 0"; echo "tx_errors: 0" ;; esac ;;
*) printf 'Speed: 2500Mb/s\nDuplex: Full\nLink detected: yes\n' ;;
esac
EOS
cat > "$TMP/bin/dmesg" <<'EOS'
#!/bin/sh
[ -f "$DMESG_FILE" ] && cat "$DMESG_FILE"
exit 0
EOS
cat > "$TMP/bin/logger" <<'EOS'
#!/bin/sh
# record priority and message, one per line
printf '%s\n' "$*" >> "$LOGGER_FILE"
EOS
chmod +x "$TMP/bin/ethtool" "$TMP/bin/dmesg" "$TMP/bin/logger"

run() {
	: > "$TMP/logger"
	PATH="$TMP/bin:$PATH" \
	NET_DIR="$TMP/net" \
	STATE="$TMP/state" \
	DMESG_FILE="$TMP/dmesg" \
	LOGGER_FILE="$TMP/logger" \
	sh "$SUT" --window 30 "$@" > "$TMP/out" 2>&1
	echo $?
}
logged() { grep -c "$1" "$TMP/logger" 2>/dev/null || true; }
set_dmesg() { : > "$TMP/dmesg"; for l in "$@"; do printf '[999999999.000000] igc 0000:0%s:00.0 %s: NIC Link is Down\n' "$l" "$l" >> "$TMP/dmesg"; done; }

# --- T1: quiet board --------------------------------------------------
rm -f "$TMP/state"
set_dmesg
rc=$(run)
if [ "$rc" -eq 0 ] && grep -q 'RESULT: PASS' "$TMP/out" && [ "$(logged .)" = "0" ]; then
	ok "a board with no flaps passes and says nothing to syslog"
else
	bad "a clean board produced rc=$rc, syslog=$(cat "$TMP/logger" 2>/dev/null)"
fi

# --- T2: the WAN port flapped ----------------------------------------
rm -f "$TMP/state"
set_dmesg eth0 eth0
rc=$(run)
if [ "$rc" -eq 1 ] && grep -q 'NVM regression signal' "$TMP/out" && [ "$(logged 'NVM regression')" -ge 1 ]; then
	ok "a WAN flap fails the run and reaches syslog"
else
	bad "a WAN flap gave rc=$rc, syslog=[$(cat "$TMP/logger" 2>/dev/null)]"
fi

# --- T3: a LAN port flapped (somebody rebooted the AP) ----------------
rm -f "$TMP/state"
set_dmesg eth2 eth2 eth2
rc=$(run)
if [ "$rc" -eq 0 ] && grep -q 'not an NVM signal' "$TMP/out" && [ "$(logged eth2)" -ge 1 ]; then
	ok "a LAN flap is reported and logged but does not fail the run"
else
	bad "a LAN flap gave rc=$rc, out=$(tail -1 "$TMP/out")"
fi

# --- T4: the same LAN port flaps in three consecutive runs ------------
# The first run has no previous sample, so it can only record a baseline;
# the streak counts runs that observed a flap.
rm -f "$TMP/state"
set_dmesg
third=""
fourth=""
for n in 1 2 3 4; do
	echo $((n * 2)) > "$TMP/net/eth2/carrier_changes"
	rc=$(run)
	[ "$n" -eq 3 ] && third=$rc
	[ "$n" -eq 4 ] && fourth=$rc
done
if [ "$third" -eq 0 ] && [ "$fourth" -eq 1 ] && grep -q 'repeated LAN flapping' "$TMP/out"; then
	ok "two observed LAN flaps pass, three in a row fail: no single reboot explains that"
else
	bad "LAN streak escalated at the wrong point (run3 rc=$third, run4 rc=$fourth)"
fi

# --- T5: firmware mismatch -------------------------------------------
rm -f "$TMP/state"
set_dmesg
rc=$(PATH="$TMP/bin:$PATH" FW_OVERRIDE=2017:888d NET_DIR="$TMP/net" STATE="$TMP/state" \
	DMESG_FILE="$TMP/dmesg" LOGGER_FILE="$TMP/logger" sh "$SUT" --window 30 > "$TMP/out" 2>&1; echo $?)
if [ "$rc" -eq 1 ] && grep -q 'MISMATCH' "$TMP/out"; then
	ok "the pre-fix firmware fails the check"
else
	bad "a stale firmware gave rc=$rc"
fi

# --- T6: --wan naming a port that is not an igc port ------------------
rc=$(run --wan eth9)
if [ "$rc" -eq 2 ] && grep -q 'is not one of' "$TMP/out"; then
	ok "a --wan typo is refused instead of demoting every flap to LAN"
else
	bad "--wan eth9 gave rc=$rc (silently reclassified flaps)"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
