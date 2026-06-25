#!/bin/bash
# capture_surflare_config.sh
# Capture the sing-box JSON config that surflare connect pipes to surflare-proxy.
# Run interactively on N100 (ssh root@192.168.100.1).
# SSH survives because it's LAN (192.168.100.x -> 192.168.100.1), not VPN.

set -euo pipefail

REAL_BIN="/usr/bin/surflare-proxy.real"
WRAPPER="/usr/bin/surflare-proxy"
PID_FILE="/etc/surflare/surflare-proxy.pid"
# Capture filename is determined by the WRAPPER at runtime (date in wrapper, not here).
# We discover it with ls -t in Phase 4.

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { log "FATAL: $*"; exit 1; }

# ── Signal trap: restore binary on Ctrl-C / SIGTERM ───────────────────
_restored=0
_restore_binary() {
	if [ "$_restored" -eq 0 ] && [ -f "$REAL_BIN" ]; then
		_restored=1
		log "CLEANUP: restoring original binary (signal)"
		cp "$REAL_BIN" "$WRAPPER" 2>/dev/null || true
		rm -f "$REAL_BIN" 2>/dev/null || true
		log "Restored $WRAPPER from backup"
	fi
}
trap _restore_binary INT TERM

# ── Phase 0: Pre-flight ──────────────────────────────────────────────
log "=== Phase 0: Pre-flight ==="
[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -f "$WRAPPER" ] || die "$WRAPPER not found"
[ -f "$REAL_BIN" ] && die "$REAL_BIN already exists — cleanup needed first.
  Run: rm $REAL_BIN"
# Detect stale wrapper from a previous interrupted run where REAL_BIN
# was manually deleted but the wrapper was not restored.
if grep -q "Temporary wrapper" "$WRAPPER" 2>/dev/null; then
	die "$WRAPPER is already a wrapper from a previous run.
  Restore the original binary first."
fi
[ -x "$WRAPPER" ] || die "$WRAPPER is not executable"
log "Pre-flight OK"

# ── Phase 1: Backup ──────────────────────────────────────────────────
log "=== Phase 1: Backup ==="
cp "$WRAPPER" "$REAL_BIN"
log "Backed up $WRAPPER -> $REAL_BIN"

# ── Phase 2: Kill surflare-proxy, then write wrapper ──────────────────
# Must kill first: kernel refuses to overwrite an executing binary
# (Text file busy).  cp (read) is safe; cat > (write) is not.
log "=== Phase 2: Kill surflare-proxy ==="
OLD_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
	log "Killing surflare-proxy (pid=$OLD_PID)"
	kill "$OLD_PID"
else
	log "surflare-proxy not running via pid file, trying pkill"
	pkill -f "surflare-proxy run" 2>/dev/null || true
fi

# Wait for old process to actually die before writing wrapper
for i in $(seq 1 10); do
	if [ -n "$OLD_PID" ] && ! kill -0 "$OLD_PID" 2>/dev/null; then
		log "Old surflare-proxy exited"
		break
	fi
	if ! pgrep -f "surflare-proxy run" > /dev/null 2>&1; then
		log "Old surflare-proxy exited (pgrep)"
		break
	fi
	sleep 1
done

# Now safe to overwrite the binary
log "Writing wrapper..."
cat > "$WRAPPER" << 'WRAPPER_EOF'
#!/bin/bash
# Temporary wrapper: captures stdin (sing-box JSON config) then forwards to real binary.
# Installed by capture_surflare_config.sh.
CAPTURE="/tmp/surflare_config_$(date +%Y%m%d_%H%M%S).json"
LOG="/tmp/surflare_config_capture.log"
tee "$CAPTURE" | /usr/bin/surflare-proxy.real "$@"
RC=$?
# 143 = SIGTERM (normal on shutdown), not an error
if [ $RC -ne 0 ] && [ $RC -ne 143 ]; then
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: surflare-proxy.real exit=$RC" >> "$LOG"
fi
exit $RC
WRAPPER_EOF
chmod +x "$WRAPPER"
log "Wrapper installed"

# ── Phase 3: Wait for reconnection ───────────────────────────────────
# Watchdog health check cycle is ~10 min (CHECK_INTERVAL=30s but
# check_vpn_health() probe timeouts stack to ~10m30s).  960s (16 min)
# covers the worst case: 10.5 min cycle + connect_vpn + margin.
log "=== Phase 3: Wait for watchdog to restart surflare-proxy ==="
log "Watchdog health check cycle is ~10 min; may take up to 15 min."
RECONNECTED=0
for i in $(seq 1 480); do
	sleep 2
	if pgrep -f "surflare-proxy run" > /dev/null 2>&1; then
		log "surflare-proxy restarted (waited $((i*2))s)"
		RECONNECTED=1
		break
	fi
	if [ $((i % 30)) -eq 0 ]; then
		log "Still waiting... ($((i*2))s/960s)"
	fi
done
[ "$RECONNECTED" -eq 1 ] || die "surflare-proxy did not restart after 16 min.
  Wrapper is still in place — watchdog will restart on its next cycle.
  Restore manually: cp $REAL_BIN $WRAPPER"

# ── Phase 4: Verify config capture ───────────────────────────────────
log "=== Phase 4: Verify capture ==="
sleep 3  # give surflare-proxy time to read config through wrapper
# shellcheck disable=SC2012  # filenames are machine-generated, no special chars
CAPTURED=$(ls -t /tmp/surflare_config_*.json 2>/dev/null | head -1 || echo "")
if [ -z "$CAPTURED" ]; then
	log "No config captured at /tmp/surflare_config_*.json"
	log "Wrapper is still in place — next watchdog reconnect will capture."
	log "Check back after watchdog's next health check cycle."
	exit 0
fi

SIZE=$(wc -c < "$CAPTURED" 2>/dev/null || echo 0)
log "Captured: $CAPTURED ($SIZE bytes)"

# Quick sanity: valid JSON starts with { or [
HEAD_CHAR=$(head -c 1 "$CAPTURED" 2>/dev/null || echo "")
case "$HEAD_CHAR" in
	'{'|'[') log "Config looks like valid JSON" ;;
	*) log "WARN: config does not start with '{' or '[' — may be incomplete" ;;
esac

# ── Cleanup instructions ─────────────────────────────────────────────
echo ""
log "=== Done ==="
log "Config file: $CAPTURED"
log ""
log "=== RESTORE (run after reviewing config) ==="
log "  cp $REAL_BIN $WRAPPER"
log "  kill \$(cat $PID_FILE 2>/dev/null || pgrep -f 'surflare-proxy run')"
log "  # watchdog will restart with real surflare-proxy"
log ""
log "Wrapper errors (if any): /tmp/surflare_config_capture.log"
log "Wrapper at $WRAPPER remains active until restored."
