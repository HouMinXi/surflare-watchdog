#!/bin/bash
set -e

# Change to repo root so python3 cross_validate_routes.py works
cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "--- RUNNING SMOKE TESTS ---"

TEST_DIR=$(mktemp -d /tmp/surflare_smoke_XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

# 1. Normal path: Real BGP vs Real APNIC (Simulated)
echo "1. Normal Path Test"
cat << 'ROUTE' > "$TEST_DIR/dummy_bgp.txt"
1.0.0.0/24
2.0.0.0/8
ROUTE
cat << 'ROUTE' > "$TEST_DIR/dummy_apnic.txt"
apnic|CN|ipv4|1.0.0.0|256|20100101|allocated
apnic|CN|ipv4|2.0.0.0|16777216|20100101|allocated
ROUTE
python3 cross_validate_routes.py ipv4 "$TEST_DIR/dummy_bgp.txt" "$TEST_DIR/dummy_apnic.txt" && echo "Normal path PASS" || echo "Normal path FAIL"

# 2. Boundary Test: Empty BGP
echo "2. Boundary Test: Empty BGP"
touch "$TEST_DIR/empty.txt"
python3 cross_validate_routes.py ipv4 "$TEST_DIR/empty.txt" "$TEST_DIR/dummy_apnic.txt" || echo "Empty BGP correctly FAILs"

# 3. Security/Injection Test: Poisoned BGP (US IPs injected to bypass)
echo "3. Security Test: Poisoned BGP"
cat << 'ROUTE' > "$TEST_DIR/poisoned_bgp.txt"
1.0.0.0/24
2.0.0.0/8
8.8.8.0/24
10.0.0.0/8
ROUTE
python3 cross_validate_routes.py ipv4 "$TEST_DIR/poisoned_bgp.txt" "$TEST_DIR/dummy_apnic.txt" || echo "Poisoned BGP correctly FAILs"

echo "Smoke tests completed."
