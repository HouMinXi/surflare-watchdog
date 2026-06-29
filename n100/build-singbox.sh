#!/bin/bash
# Build patched sing-box for N100 (surflare-proxy replacement).
#
# Prerequisites:
#   - Go >= 1.22 (tested with 1.26.4)
#   - git
#
# Usage:
#   ./build-singbox.sh [version]
#   version defaults to v1.10.7 (matches surflare v4.1.1 bundled sing-box)
#
# Output: ./surflare-proxy-patched  (static amd64 binary)
#
# Deploy:
#   scp surflare-proxy-patched root@192.168.100.1:/tmp/
#   ssh root@192.168.100.1 'cp /usr/bin/surflare-proxy /usr/bin/surflare-proxy.orig && cp /tmp/surflare-proxy-patched /usr/bin/surflare-proxy && chmod +x /usr/bin/surflare-proxy && killall surflare-proxy'
#   # watchdog restarts surflare with patched binary within one health cycle

set -euo pipefail

VERSION="${1:-v1.10.7}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="/tmp/sing-box-build-$$"

# Build tags matching surflare's bundled sing-box
BUILD_TAGS="with_gvisor,with_quic,with_dhcp,with_wireguard,with_ech,with_utls,with_reality_server,with_acme,with_clash_api"

echo "Building sing-box ${VERSION} with urltest timeout patch..."

# Clone
git clone --depth 1 --branch "${VERSION}" https://github.com/SagerNet/sing-box.git "${BUILD_DIR}"
cd "${BUILD_DIR}"

# Select patch based on version
if [[ "${VERSION}" == v1.10.* ]]; then
    PATCH="${SCRIPT_DIR}/patches/sing-box-v1.10.7-urltest-timeout.patch"
    # v1.10.x: urltest group code is in outbound/urltest.go
else
    PATCH="${SCRIPT_DIR}/patches/sing-box-master-urltest-timeout.patch"
    # master/1.11+: urltest group code moved to protocol/group/urltest.go
fi

if [ ! -f "${PATCH}" ]; then
    echo "Error: patch not found: ${PATCH}" >&2
    exit 1
fi

echo "Applying: $(basename "${PATCH}")"
git apply "${PATCH}"

# Build static binary for N100 (x86_64)
echo "Compiling (CGO_ENABLED=0, linux/amd64)..."
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -tags "${BUILD_TAGS}" \
    -o "${SCRIPT_DIR}/surflare-proxy-patched" \
    ./cmd/sing-box

echo "Done: ${SCRIPT_DIR}/surflare-proxy-patched"
ls -lh "${SCRIPT_DIR}/surflare-proxy-patched"
md5sum "${SCRIPT_DIR}/surflare-proxy-patched"

# Cleanup
rm -rf "${BUILD_DIR}"
echo "Build dir cleaned up."
