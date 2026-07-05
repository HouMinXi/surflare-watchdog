#!/bin/sh
# surflare-proxy wrapper: patches urltest tolerance/interval before
# forwarding stdin JSON to the real binary.
# md5-gate: auto-restores patched binary if surflare auto-update replaces it.
REAL_BIN="/usr/bin/surflare-proxy.real"
FALLBACK_BIN="/usr/local/lib/surflare-proxy-patched"
EXPECTED_MD5="8e18ab1e9b5aa9d9de8bbe91d4d6245b"
TOLERANCE=300
INTERVAL="60s"

# md5-gate: detect and rollback surflare auto-update
_md5=$(md5sum "$REAL_BIN" 2>/dev/null | cut -d" " -f1)
if [ "$_md5" != "$EXPECTED_MD5" ] && [ -x "$FALLBACK_BIN" ]; then
	_fb_md5=$(md5sum "$FALLBACK_BIN" 2>/dev/null | cut -d" " -f1)
	if [ "$_fb_md5" = "$EXPECTED_MD5" ]; then
		logger -t surflare-proxy "auto-update rolled back"
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

if jq --argjson T "$TOLERANCE" --arg I "$INTERVAL" \
   '.outbounds |= map(if .type == "urltest" then .tolerance = $T | .interval = $I else . end)' \
   < "$_tmp" > "$_patched"; then
	exec < "$_patched"
	rm -f "$_tmp" "$_patched"
	exec "$REAL_BIN" "$@"
else
	exec < "$_tmp"
	rm -f "$_tmp" "$_patched"
	exec "$REAL_BIN" "$@"
fi
