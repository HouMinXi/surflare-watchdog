#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
	echo "Please run with sudo"
	exit 1
fi

if ! command -v systemd-creds >/dev/null 2>&1; then
	echo "Error: systemd-creds is not installed. Required for secure credential storage."
	exit 1
fi

echo "=== Surflare Watchdog TPM2 Auth Setup ==="
echo "This script securely stores your credentials using systemd hardware encryption."
echo

read -r -p "Enter Surflare Email: " EMAIL
if [[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+$ ]]; then
	echo "Error: invalid email format"
	exit 1
fi

read -r -s -p "Enter Surflare Password: " SURF_PWD
echo

mkdir -p /etc/systemd/system/surflare-watchdog.service.d/

# Encrypt password to credential file
printf "%s" "$SURF_PWD" | systemd-creds encrypt --name=surflare_password - /etc/systemd/system/surflare-watchdog.service.d/surflare_password.cred
unset SURF_PWD

# Create override configuration (restrict permissions to prevent email leakage)
(
	umask 0077
	cat > /etc/systemd/system/surflare-watchdog.service.d/11-auth-email.conf <<EOF
[Service]
Environment="SURFLARE_EMAIL=${EMAIL}"
LoadCredentialEncrypted=surflare_password:/etc/systemd/system/surflare-watchdog.service.d/surflare_password.cred
EOF
)

systemctl daemon-reload
echo
echo "Successfully configured secure auth credentials!"
echo "You can now restart the watchdog to apply: sudo systemctl restart surflare-watchdog"
