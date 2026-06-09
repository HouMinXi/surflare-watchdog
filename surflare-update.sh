#!/bin/bash
# Auto-update surflare binaries and restart watchdog if changed.
# Deployed to /usr/local/sbin/surflare-update.sh
# Triggered by surflare-update.timer (daily 03:00)

set -euo pipefail

INSTALL_URL="https://www.surflare.com/static/linux-setup.sh"
PROXY_BIN="/usr/bin/surflare-proxy"
CLI_BIN="/usr/bin/surflare"

log() { logger -t surflare-update "$*"; }

if [ "$(id -u)" -ne 0 ]; then
	echo "Must run as root" >&2
	exit 1
fi

if [ ! -f "$PROXY_BIN" ]; then
	log "surflare-proxy not found, skipping"
	exit 0
fi

hash_before=$(sha256sum "$PROXY_BIN" "$CLI_BIN" 2>/dev/null | sha256sum | awk '{print $1}')

if ! curl -fsSL --connect-timeout 15 --max-time 60 "$INSTALL_URL" | bash >/dev/null 2>&1; then
	log "Install script failed"
	exit 1
fi

hash_after=$(sha256sum "$PROXY_BIN" "$CLI_BIN" 2>/dev/null | sha256sum | awk '{print $1}')

if [ "$hash_before" != "$hash_after" ]; then
	new_ver=$("$CLI_BIN" --version 2>/dev/null || echo "unknown")
	log "Binary changed (${new_ver}), restarting watchdog"
	systemctl restart surflare-watchdog
else
	log "No change"
fi
