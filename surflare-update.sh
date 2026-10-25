#!/bin/bash
# Auto-update surflare binaries and restart watchdog if changed.
# Deployed to /usr/local/sbin/surflare-update.sh
# Triggered by surflare-update.timer (daily 03:00)

set -euo pipefail

INSTALL_URL="https://www.surflare.com/static/linux-setup.sh"
PROXY_BIN="${PROXY_BIN:-/usr/bin/surflare-proxy}"
CLI_BIN="${CLI_BIN:-/usr/bin/surflare}"
PATCHED_BIN="${PATCHED_BIN:-/usr/local/lib/surflare-proxy-patched}"
REAL_BIN="${REAL_BIN:-/usr/bin/surflare-proxy.real}"
SNAP_ROOT="${SNAP_ROOT:-/var/backups/surflare}"
SERVICE="${SERVICE:-surflare-watchdog}"
READY_TIMEOUT="${READY_TIMEOUT:-90}"
MIN_SCRIPT_SIZE=500

log() { logger -t surflare-update "$*"; }

if [ "${SURFLARE_UPDATE_ALLOW_NONROOT:-0}" != "1" ] && [ "$(id -u)" -ne 0 ]; then
	echo "Must run as root" >&2
	exit 1
fi

if [ ! -f "$PROXY_BIN" ]; then
	log "surflare-proxy not found, skipping"
	exit 0
fi

file_hash() { [ -f "$1" ] && sha256sum "$1" | awk '{print $1}' || echo "missing"; }

hash_proxy_before=$(file_hash "$PROXY_BIN")
hash_cli_before=$(file_hash "$CLI_BIN")

tmp_script=$(mktemp /tmp/surflare-setup-XXXXXX.sh)
snap_dir=""
snap_keep=0
cleanup() {
	rm -f "$tmp_script"
	# A failed run must not leave a half-populated snapshot behind; a
	# successful one keeps it, and that is the rollback point.
	if [ -n "$snap_dir" ] && [ "$snap_keep" -ne 1 ]; then
		rm -rf "$snap_dir"
	fi
}
trap cleanup EXIT

if ! curl -fsSL --connect-timeout 15 --max-time 60 "$INSTALL_URL" -o "$tmp_script"; then
	log "Download failed"
	exit 1
fi

script_size=$(stat -c%s "$tmp_script")
if [ "$script_size" -lt "$MIN_SCRIPT_SIZE" ]; then
	log "Downloaded script too small (${script_size} bytes), aborting"
	exit 1
fi

# The vendor publishes no digest or signature for this installer, so the fetch
# is trusted because it arrives over TLS and for no other reason.  Recording
# what is about to run as root does not make it trustworthy; it makes the log
# able to say which installer replaced the binaries.
script_sha=$(sha256sum "$tmp_script" | awk '{print $1}')
log "Installer ${script_size} bytes sha256=${script_sha} (unsigned; vendor publishes no digest)"

# Snapshot before touching anything: the installer replaces both binaries in
# place, and a bad release on a headless box otherwise means a hand repair.
snap_dir="$SNAP_ROOT/$(date +%Y%m%d-%H%M%S)"
if mkdir -p "$snap_dir" 2>/dev/null; then
	# The wrapper is not what runs: it execs $REAL_BIN.  Snapshotting only the
	# wrapper leaves the actual binary unrollbackable.
	for f in "$PROXY_BIN" "$REAL_BIN" "$CLI_BIN" "$PATCHED_BIN"; do
		if [ -f "$f" ]; then
			cp -a "$f" "$snap_dir/$(basename "$f")" 2>/dev/null || true
		fi
	done
	log "Snapshot saved to ${snap_dir}"
else
	snap_dir=""
	log "WARN: could not create ${SNAP_ROOT}, continuing without a rollback point"
fi

# From here the binaries are about to change: this is the run whose snapshot
# has rollback value, so keep it even if the install fails halfway.
snap_keep=1
if ! bash "$tmp_script" 2>&1 | logger -t surflare-update; then
	log "Install script failed"
	exit 1
fi

hash_proxy_after=$(file_hash "$PROXY_BIN")
hash_cli_after=$(file_hash "$CLI_BIN")

proxy_running() {
	local i=0
	while [ "$i" -lt "$READY_TIMEOUT" ]; do
		# Anything whose argv mentions the name answers a substring match: the
		# watchdog's own log tail, the log health check, an operator watching
		# the log.  Ask the proxy's port instead, which is what "running"
		# means for a service the updater has just replaced.
		# The port is the service's identity; the exact process name covers the
		# moment between exec and listen.  `pgrep -f` would also count a log
		# tail or the watchdog's own monitor, which is how a dead proxy kept a
		# broken release.
		if (exec 3<>/dev/tcp/127.0.0.1/10800) 2>/dev/null ||
			pgrep -x surflare-proxy >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done
	return 1
}

restore_snapshot() {
	local f base restored=0 failed=0
	[ -n "$snap_dir" ] || return 2
	for f in "$PROXY_BIN" "$REAL_BIN" "$CLI_BIN" "$PATCHED_BIN"; do
		base=$(basename "$f")
		if [ -f "$snap_dir/$base" ]; then
			# A rollback that reports success without checking the copy is
			# worse than no rollback: the log says the box is back while it
			# keeps running the release it could not hold.
			if cp -a "$snap_dir/$base" "$f" 2>/dev/null; then
				chmod +x "$f" 2>/dev/null || true
				restored=$((restored + 1))
			else
				failed=$((failed + 1))
			fi
		fi
	done
	if [ "$failed" -gt 0 ] || [ "$restored" -eq 0 ]; then
		log "ERROR: rollback incomplete (${restored} restored, ${failed} failed) from ${snap_dir}"
		return 1
	fi
	return 0
}

if [ "$hash_proxy_before" != "$hash_proxy_after" ] || [ "$hash_cli_before" != "$hash_cli_after" ]; then
	new_ver=$("$CLI_BIN" --version 2>/dev/null || echo "unknown")
	log "Binary changed (${new_ver}), restarting watchdog"
	# `if ! cmd` makes $? the status of the negation, so the real code has to
	# be captured here or the log says rc=0 for every failure.
	_restart_rc=0
	systemctl restart "$SERVICE" || _restart_rc=$?
	if [ "$_restart_rc" -ne 0 ]; then
		# The old proxy is still running the old binary, so a liveness check
		# would pass and report success over a restart that never happened.
		log "ERROR: watchdog restart failed (rc=${_restart_rc}); rolling back"
		_rb=0
		restore_snapshot || _rb=$?
		case "$_rb" in
		0)
			log "Restored binaries from ${snap_dir}"
			# restart is stop then start: when it fails inside the start the
			# unit is left inactive, with the binaries rolled back and nothing
			# running.  The daily timer is a day away.
			systemctl start "$SERVICE" || log "ERROR: could not start the watchdog after rollback"
			;;
		2) log "ERROR: no snapshot to roll back to" ;;
		*) : ;;  # restore_snapshot already logged what failed
		esac
		exit 1
	fi
	# The update is only done when the proxy is running again.  A release that
	# starts and cannot hold a tunnel looks identical to a good one from here,
	# so this checks the process rather than the exit status.
	if ! proxy_running; then
		log "ERROR: proxy did not come up after update; rolling back"
		_rb=0
		restore_snapshot || _rb=$?
		case "$_rb" in
		0)
			log "Restored binaries from ${snap_dir}"
			systemctl restart "$SERVICE" || log "ERROR: restart after rollback failed"
			;;
		2) log "ERROR: no snapshot to roll back to" ;;
		*) : ;;
		esac
		exit 1
	fi
	log "Update complete, proxy is running"
else
	# Nothing was replaced, so the snapshot has no rollback value; leave it
	# behind and the directory fills with empty timestamped copies.
	if [ -n "$snap_dir" ]; then
		rm -rf "$snap_dir"
		snap_dir=""
	fi
	log "No change"
fi
