#!/bin/bash
# install.sh — idempotent installer for surflare-watchdog
#
# Installs the watchdog daemon, systemd service, NetworkManager hooks,
# and Wi-Fi stability tuning (disables NM + driver power saving).
#
# Usage:
#   sudo ./install.sh           # full install
#   sudo ./install.sh --no-wifi # skip Wi-Fi tuning (non-Intel or headless)
#
# Safe to run multiple times — each step checks current state and skips
# if already up-to-date.

set -euo pipefail

# ── Colours (disabled when stdout is not a TTY) ──────────────────────────────
if [ -t 1 ]; then
	RED='\033[0;31m'
	YEL='\033[1;33m'
	GRN='\033[0;32m'
	NC='\033[0m'
else
	RED=''
	YEL=''
	GRN=''
	NC=''
fi
ok() { printf "${GRN}[ok]${NC}    %s\n" "$*"; }
skip() { printf "[skip]  %s\n" "$*"; }
info() { printf "${YEL}[info]${NC}  %s\n" "$*"; }
warn() { printf "${YEL}[warn]${NC}  %s\n" "$*"; }
die() {
	printf "${RED}[error]${NC} %s\n" "$*" >&2
	exit 1
}

# ── Args ─────────────────────────────────────────────────────────────────────
WIFI_TUNING=1
for arg in "$@"; do
	[ "$arg" = "--no-wifi" ] && WIFI_TUNING=0
done

# ── Preflight ─────────────────────────────────────────────────────────────────
[ "$EUID" -eq 0 ] || die "Run as root: sudo $0"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

echo "=== surflare-watchdog installer ==="
echo

# ── Helper: install file if changed ──────────────────────────────────────────
install_file() {
	local src="$1" dst="$2" mode="${3:-644}"
	if [ ! -f "$src" ]; then
		die "Source not found: $src"
	fi
	if [ -f "$dst" ] && diff -q "$src" "$dst" >/dev/null 2>&1; then
		skip "$dst"
		return
	fi
	install -D -m "$mode" "$src" "$dst"
	ok "$dst"
}

# ── Preflight: warn about common configuration mistakes ──────────────────────
if grep -q 'NODE="your_node_tag"' "$SCRIPT_DIR/surflare_watchdog.sh" 2>/dev/null; then
	warn "surflare_watchdog.sh: NODE is still set to 'your_node_tag'"
	warn "  Edit NODE= before running, or the service will exit immediately on start"
fi

# ── 1. Watchdog script ────────────────────────────────────────────────────────
# Track whether the script actually changed — used in step 6 to decide restart vs skip
WATCHDOG_CHANGED=0
if [ ! -f /usr/local/sbin/surflare_watchdog.sh ] ||
	! diff -q "$SCRIPT_DIR/surflare_watchdog.sh" /usr/local/sbin/surflare_watchdog.sh >/dev/null 2>&1; then
	WATCHDOG_CHANGED=1
fi
install_file "$SCRIPT_DIR/surflare_watchdog.sh" /usr/local/sbin/surflare_watchdog.sh 755

# ── 2. systemd service ────────────────────────────────────────────────────────
install_file "$SCRIPT_DIR/surflare-watchdog.service" /etc/systemd/system/surflare-watchdog.service 644

# ── 3. NetworkManager dispatcher hook ────────────────────────────────────────
install_file "$SCRIPT_DIR/99-surflare-resume" /etc/NetworkManager/dispatcher.d/99-surflare-resume 755

# ── 4. systemd-sleep hook (S3 suspend) ───────────────────────────────────────
SLEEP_HOOK=/etc/systemd/system-sleep/surflare-resume.sh
if [ -L "$SLEEP_HOOK" ] && [ "$(readlink "$SLEEP_HOOK")" = /usr/local/sbin/surflare_watchdog.sh ]; then
	skip "$SLEEP_HOOK (symlink ok)"
else
	mkdir -p /etc/systemd/system-sleep
	ln -sf /usr/local/sbin/surflare_watchdog.sh "$SLEEP_HOOK"
	ok "$SLEEP_HOOK → /usr/local/sbin/surflare_watchdog.sh"
fi

# ── 5. Wi-Fi stability tuning ─────────────────────────────────────────────────
if [ "$WIFI_TUNING" -eq 0 ]; then
	info "Wi-Fi tuning skipped (--no-wifi)"
else
	echo
	echo "--- Wi-Fi stability tuning ---"

	# 5a. NetworkManager power saving
	NM_CONF_DST=/etc/NetworkManager/conf.d/wifi-power.conf
	install_file "$SCRIPT_DIR/conf/nm-wifi-power.conf" "$NM_CONF_DST" 644

	# Reload NM config (no disconnect)
	if nmcli general reload conf 2>/dev/null; then
		ok "nmcli general reload conf"
	else
		warn "nmcli reload failed — reboot may be needed for NM config to take effect"
	fi

	# Disable power save on active Wi-Fi interface
	WIFI_IFACE=$(iw dev 2>/dev/null | awk '/Interface/{iface=$2} /type managed/{print iface; exit}')
	if [ -n "$WIFI_IFACE" ]; then
		CURRENT_PS=$(iw dev "$WIFI_IFACE" get power_save 2>/dev/null | grep -oE '(on|off)')
		if [ "$CURRENT_PS" = "off" ]; then
			skip "iw $WIFI_IFACE power_save (already off)"
		else
			if iw dev "$WIFI_IFACE" set power_save off 2>/dev/null; then
				ok "iw $WIFI_IFACE set power_save off"
			else
				warn "iw $WIFI_IFACE set power_save off failed — reboot may be needed"
			fi
		fi
	else
		warn "No managed Wi-Fi interface found — skipping iw power_save"
	fi

	# 5b. Driver-level power scheme (Intel)
	echo
	DRIVER=""
	if lsmod 2>/dev/null | grep -q '^iwlmld'; then
		DRIVER="iwlmld"
	elif lsmod 2>/dev/null | grep -q '^iwlmvm'; then
		DRIVER="iwlmvm"
	fi

	if [ -z "$DRIVER" ]; then
		info "Intel Wi-Fi driver (iwlmld/iwlmvm) not loaded — skipping driver power_scheme tuning"
		info "If you use a different driver, set power_scheme=1 (or equivalent) manually."
	else
		MODPROBE_SRC="$SCRIPT_DIR/conf/modprobe-${DRIVER}.conf"
		MODPROBE_DST="/etc/modprobe.d/${DRIVER}.conf"
		install_file "$MODPROBE_SRC" "$MODPROBE_DST" 644

		# Only reload if power_scheme needs to change
		PARAM_FILE="/sys/module/${DRIVER}/parameters/power_scheme"
		CURRENT_SCHEME=$(cat "$PARAM_FILE" 2>/dev/null || echo "unknown")
		if [ "$CURRENT_SCHEME" = "1" ]; then
			skip "${DRIVER} power_scheme (already 1=CAM)"
		else
			warn "Reloading ${DRIVER} to apply power_scheme=1 — Wi-Fi will disconnect briefly"
			if modprobe -r "$DRIVER" && modprobe "$DRIVER"; then
				NEW_SCHEME=$(cat "$PARAM_FILE" 2>/dev/null || echo "unknown")
				if [ "$NEW_SCHEME" = "1" ]; then
					ok "${DRIVER} power_scheme=1 (CAM) applied"
				else
					warn "${DRIVER} power_scheme is ${NEW_SCHEME} after reload — reboot to apply"
				fi
			else
				warn "Failed to reload ${DRIVER} — reboot to apply power_scheme=1"
			fi
		fi
	fi
fi

# ── 6. systemd daemon-reload + enable ────────────────────────────────────────
echo
echo "--- systemd ---"
systemctl daemon-reload
ok "systemctl daemon-reload"

if systemctl is-enabled --quiet surflare-watchdog 2>/dev/null; then
	skip "surflare-watchdog.service (already enabled)"
else
	systemctl enable surflare-watchdog
	ok "surflare-watchdog.service enabled"
fi

if [ ! -f /etc/surflare/surflare-password.cred ]; then
	warn "Credential file not found: /etc/surflare/surflare-password.cred"
	warn "  Proactive token refresh will be disabled — create it with:"
	warn "  echo -n 'YOUR_PASSWORD' | sudo systemd-creds encrypt --name=surflare-password - /etc/surflare/surflare-password.cred"
fi

if systemctl is-active --quiet surflare-watchdog 2>/dev/null; then
	if [ "$WATCHDOG_CHANGED" -eq 1 ]; then
		systemctl restart surflare-watchdog
		ok "surflare-watchdog.service restarted (new script deployed)"
	else
		skip "surflare-watchdog.service restart (script unchanged)"
	fi
else
	systemctl start surflare-watchdog
	ok "surflare-watchdog.service started"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "=== Install complete ==="
echo
echo "Status:"
systemctl status surflare-watchdog --no-pager --lines=3 2>/dev/null || true
echo
echo "Monitor logs:  sudo dmesg -w | grep surflare_watchdog"
