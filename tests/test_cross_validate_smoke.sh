#!/bin/bash
# Smoke test for cross_validate_routes.py.
#
# Every assertion here used to be `cmd && echo PASS || echo FAIL`, which prints
# a verdict and exits 0 whatever happened: the runner recorded a pass for a
# checker that refuses to run.  The counts below are the test.
set -u

# Change to repo root so python3 cross_validate_routes.py works
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

pass=0
fail=0

# expect_ok <label> <command...> -- the checker must accept this input
expect_ok() {
	local label=$1
	shift
	if "$@" > /dev/null 2>&1; then
		echo "PASS: $label"
		pass=$((pass + 1))
	else
		echo "FAIL: $label (the checker rejected input it should accept)"
		fail=$((fail + 1))
	fi
}

# expect_reject <label> <command...> -- the checker must refuse this input
expect_reject() {
	local label=$1
	shift
	if "$@" > /dev/null 2>&1; then
		echo "FAIL: $label (the checker accepted input it should refuse)"
		fail=$((fail + 1))
	else
		echo "PASS: $label"
		pass=$((pass + 1))
	fi
}

echo "--- RUNNING SMOKE TESTS ---"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

cat << 'ROUTE' > "$TEST_DIR/dummy_bgp.txt"
1.0.0.0/24
2.0.0.0/8
ROUTE
cat << 'ROUTE' > "$TEST_DIR/dummy_apnic.txt"
apnic|CN|ipv4|1.0.0.0|256|20100101|allocated
apnic|CN|ipv4|2.0.0.0|16777216|20100101|allocated
ROUTE
expect_ok "ipv4 routes covered by the delegation are accepted" \
	python3 cross_validate_routes.py ipv4 "$TEST_DIR/dummy_bgp.txt" "$TEST_DIR/dummy_apnic.txt"

touch "$TEST_DIR/empty.txt"
expect_reject "an empty route file is refused, not reported as 100% covered" \
	python3 cross_validate_routes.py ipv4 "$TEST_DIR/empty.txt" "$TEST_DIR/dummy_apnic.txt"

cat << 'ROUTE' > "$TEST_DIR/poisoned_bgp.txt"
1.0.0.0/24
2.0.0.0/8
8.8.8.0/24
10.0.0.0/8
ROUTE
expect_reject "foreign and private prefixes are refused" \
	python3 cross_validate_routes.py ipv4 "$TEST_DIR/poisoned_bgp.txt" "$TEST_DIR/dummy_apnic.txt"

cat << 'ROUTE' > "$TEST_DIR/dummy_v6_bgp.txt"
2400:3200::/32
2408:4000::/22
ROUTE
cat << 'ROUTE' > "$TEST_DIR/dummy_v6_apnic.txt"
apnic|CN|ipv6|2400:3200::|32|20100101|allocated
apnic|CN|ipv6|2408:4000::|22|20100101|allocated
ROUTE
expect_ok "ipv6 routes covered by the delegation are accepted" \
	python3 cross_validate_routes.py ipv6 "$TEST_DIR/dummy_v6_bgp.txt" "$TEST_DIR/dummy_v6_apnic.txt"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
