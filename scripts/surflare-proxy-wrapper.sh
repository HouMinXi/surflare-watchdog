#!/bin/sh
# surflare-proxy wrapper: patches urltest tolerance/interval before
# forwarding stdin JSON to the real binary.
# md5-gate: auto-restores patched binary if surflare auto-update replaces it.

# Raise fd limit before exec'ing the real binary.  procd_set_param
# limits in init.d sets rlimit on the watchdog script, but surflare
# connect --daemon daemonizes (fork+setsid) and reparents the proxy
# to PID 1, breaking rlimit inheritance.  Setting ulimit here
# (inside the wrapper, closest to exec) guarantees the proxy gets
# 65535 regardless of daemonize behavior.  PM-approved fallback
# (fd-rootcause-PM-verdict Ask 2).
ulimit -n 65535 2>/dev/null || true

REAL_BIN="/usr/bin/surflare-proxy.real"
FALLBACK_BIN="/usr/local/lib/surflare-proxy-patched"
EXPECTED_MD5="8e18ab1e9b5aa9d9de8bbe91d4d6245b"
TOLERANCE=300
INTERVAL="60s"
# Domains missing from surflare's proxy_rule_set that must go through VPN.
# Without this, sing-box catch-all routes them direct -> CN IP exposed.
# Incident: platform.claude.com OAuth callback -> app-unavailable-in-region.
INJECT_DOMAINS="claude.com"

# md5-gate: detect and rollback surflare auto-update
_md5=$(md5sum "$REAL_BIN" 2>/dev/null | cut -d" " -f1)
if [ "$_md5" != "$EXPECTED_MD5" ] && [ -x "$FALLBACK_BIN" ]; then
	_fb_md5=$(md5sum "$FALLBACK_BIN" 2>/dev/null | cut -d" " -f1)
	if [ "$_fb_md5" = "$EXPECTED_MD5" ]; then
		# Capture new binary before rollback for diff analysis
		cp "$REAL_BIN" "/tmp/surflare-proxy-autoupdate-$(date +%Y%m%d_%H%M%S)"
		logger -t surflare-proxy "auto-update rolled back (new binary saved to /tmp)"
		cp "$FALLBACK_BIN" "$REAL_BIN"
	fi
fi

# Detect --config stdin among arguments
_stdin=0
for a in "$@"; do
	case "$a" in
		stdin) _stdin=1 ;;
	esac
done

if [ "$_stdin" -eq 0 ]; then
	exec "$REAL_BIN" "$@"
fi

# Two-stage: save stdin, patch with jq, feed to real binary
_tmp=$(mktemp)
_patched=$(mktemp)
trap 'rm -f "$_tmp" "$_patched"' EXIT

cat > "$_tmp"

if jq --argjson T "$TOLERANCE" --arg I "$INTERVAL" --arg D "$INJECT_DOMAINS" '
  .outbounds |= map(if .type == "urltest" then .tolerance = $T | .interval = $I else . end)
  | .route.rule_set |= map(if .tag == "proxy_rule_set" then .rules |= map(
      if .domain_suffix then
        .domain_suffix |= (. + ($D | split(",")) | unique)
      else . end
    ) else . end)
' < "$_tmp" > "$_patched"; then
	exec < "$_patched"
	rm -f "$_tmp" "$_patched"
	exec "$REAL_BIN" "$@"
else
	exec < "$_tmp"
	rm -f "$_tmp" "$_patched"
	exec "$REAL_BIN" "$@"
fi
