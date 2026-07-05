#!/bin/sh
# surflare-proxy wrapper: patches urltest tolerance/interval before
# forwarding stdin JSON to the real binary.
# ponytail: global vars, add per-outbound config when needed.
REAL_BIN="/usr/bin/surflare-proxy.real"
TOLERANCE=300
INTERVAL="60s"

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
	_n=$(jq '[.outbounds[] | select(.type == "urltest")] | length' < "$_patched")
	echo "surflare-proxy-wrapper: patched $_n urltest outbound(s): tolerance=$TOLERANCE interval=$INTERVAL" >&2
	rm -f "$_tmp"
	exec "$REAL_BIN" "$@" < "$_patched"
else
	echo "surflare-proxy-wrapper: jq failed, forwarding original config" >&2
	rm -f "$_patched"
	exec "$REAL_BIN" "$@" < "$_tmp"
fi
