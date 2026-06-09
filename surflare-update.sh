#!/bin/bash
# Auto-update surflare binaries and restart watchdog if changed.
# Deployed to /usr/local/sbin/surflare-update.sh
# Triggered by surflare-update.timer (daily 03:00)

set -euo pipefail

INSTALL_URL="https://www.surflare.com/static/linux-setup.sh"
PROXY_BIN="/usr/bin/surflare-proxy"
CLI_BIN="/usr/bin/surflare"
MIN_SCRIPT_SIZE=500

log() { logger -t surflare-update "$*"; }

if [ "$(id -u)" -ne 0 ]; then
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
trap 'rm -f "$tmp_script"' EXIT

if ! curl -fsSL --connect-timeout 15 --max-time 60 "$INSTALL_URL" -o "$tmp_script"; then
	log "Download failed"
	exit 1
fi

script_size=$(stat -c%s "$tmp_script")
if [ "$script_size" -lt "$MIN_SCRIPT_SIZE" ]; then
	log "Downloaded script too small (${script_size} bytes), aborting"
	exit 1
fi

if ! bash "$tmp_script" 2>&1 | logger -t surflare-update; then
	log "Install script failed"
	exit 1
fi

hash_proxy_after=$(file_hash "$PROXY_BIN")
hash_cli_after=$(file_hash "$CLI_BIN")

if [ "$hash_proxy_before" != "$hash_proxy_after" ] || [ "$hash_cli_before" != "$hash_cli_after" ]; then
	new_ver=$("$CLI_BIN" --version 2>/dev/null || echo "unknown")
	log "Binary changed (${new_ver}), restarting watchdog"
	if systemctl restart surflare-watchdog; then
		log "Watchdog restarted"
	else
		log "ERROR: watchdog restart failed (rc=$?)"
	fi
else
	log "No change"
fi
