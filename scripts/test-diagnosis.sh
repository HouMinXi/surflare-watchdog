#!/bin/bash
# test-diagnosis.sh: fault-inject acceptance tests for advisory diagnosis.
#
# Runs on N100. Requires bash (busybox ash does not support local keyword
# or arithmetic used here). If N100 lacks bash, install via opkg or
# rewrite test harness to be POSIX sh compatible.
# Tests _run_advisory_diagnosis with synthetic diagnostic data.
#
# Usage: test-diagnosis.sh [--with-llm] [--scenario NAME] [--verbose]

set -e

# Runtime bash check: test harness requires bash (local, arithmetic, nested funcs)
command -v bash >/dev/null 2>&1 || { echo "ERROR: bash required but not found"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCHDOG="${SCRIPT_DIR}/../surflare_watchdog.sh"
DIAG_FILE="/var/log/surflare/diagnosis.json"
WITH_LLM=0
SINGLE_SCENARIO=""
VERBOSE=0
PASS=0
FAIL=0
TOTAL_START=$(date +%s)

# Parse args
while [ $# -gt 0 ]; do
	case "$1" in
		--with-llm) WITH_LLM=1 ;;
		--scenario) SINGLE_SCENARIO="$2"; shift ;;
		--verbose) VERBOSE=1 ;;
		*) echo "Unknown arg: $1"; exit 1 ;;
	esac
	shift
done

# Source watchdog functions.
# The watchdog has root checks and dependency checks that call exit,
# which kills the parent shell when sourced directly. We work around
# this by extracting function definitions with sed and sourcing them.
_source_functions() {
	local _src="$1"
	local _tmp
	_tmp=$(mktemp /tmp/surflare-funcs-XXXXXX.sh)
	trap "rm -f '$_tmp'" RETURN

	# Extract specific functions needed for diagnosis testing.
	# Uses sed to grab from function name() { to the closing } at column 0.
	# Also includes minimal globals and the log() function.
	cat > "$_tmp" << 'PREAMBLE'
# Minimal globals for diagnosis functions
: "${NODE_CANDIDATES:=()}"
: "${_ADVISORY_DIAGNOSIS_RUNNING:=0}"
PREAMBLE

	# Extract log() function (needed by diagnosis functions)
	sed -n '/^log() {/,/^}/p' "$_src" >> "$_tmp"

	# Extract diagnosis-related functions
	for _func in _run_advisory_diagnosis _inject_diag_state _inject_restore_state _llm_enrich_diagnosis _send_diagnosis_alert; do
		sed -n "/^${_func}() {/,/^}/p" "$_src" >> "$_tmp"
	done

	# shellcheck source=/dev/null
	. "$_tmp"
}

_source_functions "$WATCHDOG"

assert_diagnosis() {
	local _scenario="$1"
	local _expected_conclusion="$2"
	local _expected_confidence="$3"
	local _actual_conclusion _actual_confidence

	[ -f "$DIAG_FILE" ] || {
		echo "FAIL [${_scenario}]: diagnosis.json not created"
		FAIL=$((FAIL + 1))
		return 1
	}

	_actual_conclusion=$(grep -o '"conclusion":"[^"]*"' "$DIAG_FILE" | \
		sed 's/"conclusion":"//; s/"//')
	_actual_confidence=$(grep -o '"confidence":"[^"]*"' "$DIAG_FILE" | \
		sed 's/"confidence":"//; s/"//')

	local _ok=1
	if [ "$_actual_conclusion" != "$_expected_conclusion" ]; then
		echo "FAIL [${_scenario}]: conclusion='${_actual_conclusion}' expected='${_expected_conclusion}'"
		_ok=0
	fi
	if [ "$_actual_confidence" != "$_expected_confidence" ]; then
		echo "FAIL [${_scenario}]: confidence='${_actual_confidence}' expected='${_expected_confidence}'"
		_ok=0
	fi

	if [ "$_ok" -eq 1 ]; then
		echo "PASS [${_scenario}]: ${_actual_conclusion} (${_actual_confidence})"
		PASS=$((PASS + 1))
	else
		FAIL=$((FAIL + 1))
		[ "$VERBOSE" -eq 1 ] && cat "$DIAG_FILE"
	fi
}

run_scenario() {
	local _name="$1"
	local _inject="$2"
	local _health="$3"
	local _diag="$4"
	local _exp_conclusion="$5"
	local _exp_confidence="$6"
	local _start _elapsed

	_start=$(date +%s)

	# Delete stale diagnosis.json to prevent false assertion from prior run
	rm -f "$DIAG_FILE" 2>/dev/null

	# Set injection env vars
	export _INJECT_FAULT="$_inject"
	export _INJECT_HEALTH="$_health"
	export _INJECT_DIAG="$_diag"

	# Run diagnosis (|| true prevents set -e from exiting on injection failure)
	_run_advisory_diagnosis "$_health" "$_diag" 2>/dev/null || true

	# Optional LLM test
	if [ "$WITH_LLM" -eq 1 ]; then
		_llm_enrich_diagnosis >/dev/null 2>&1 || true
	fi

	# Assert
	assert_diagnosis "$_name" "$_exp_conclusion" "$_exp_confidence"

	_elapsed=$(($(date +%s) - _start))
	[ "$VERBOSE" -eq 1 ] && echo "  (${_elapsed}s)"

	# Cleanup
	unset _INJECT_FAULT _INJECT_HEALTH _INJECT_DIAG
}

# Cleanup trap: restore original files + ensure injection env vars don't leak
cleanup() {
	_inject_restore_state 2>/dev/null
	unset _INJECT_FAULT _INJECT_HEALTH _INJECT_DIAG 2>/dev/null
}
trap cleanup EXIT

# Ensure diag dir exists
mkdir -p /var/log/surflare 2>/dev/null

echo "=== Surflare Diagnosis Acceptance Tests ==="
echo ""

# Scenario 1: UPSTREAM_UNREACHABLE + fd high
if [ -z "$SINGLE_SCENARIO" ] || [ "$SINGLE_SCENARIO" = "UPSTREAM_UNREACHABLE_FD" ]; then
	run_scenario "UPSTREAM_UNREACHABLE_FD" \
		"UPSTREAM_UNREACHABLE_FD" "TCP_BLOCK" "UPSTREAM_UNREACHABLE" \
		"UPSTREAM_UNREACHABLE_RESOURCE" "high"
fi

# Scenario 2: SERVER_REFUSED + 503 storm
if [ -z "$SINGLE_SCENARIO" ] || [ "$SINGLE_SCENARIO" = "SERVER_REFUSED_503" ]; then
	run_scenario "SERVER_REFUSED_503" \
		"SERVER_REFUSED_503" "TCP_BLOCK" "SERVER_REFUSED" \
		"SERVER_REFUSED_503_STORM" "high"
fi

# Scenario 3: TARGETED_SYN_BLOCK
if [ -z "$SINGLE_SCENARIO" ] || [ "$SINGLE_SCENARIO" = "TARGETED_SYN_BLOCK" ]; then
	run_scenario "TARGETED_SYN_BLOCK" \
		"TARGETED_SYN_BLOCK" "TCP_BLOCK" "TARGETED_SYN_BLOCK" \
		"TARGETED_SYN_BLOCK" "high"
fi

# Scenario 4: TRANSIT_DEGRADATION
if [ -z "$SINGLE_SCENARIO" ] || [ "$SINGLE_SCENARIO" = "TRANSIT_DEGRADATION" ]; then
	run_scenario "TRANSIT_DEGRADATION" \
		"TRANSIT_DEGRADATION" "TCP_BLOCK" "TRANSIT_DEGRADATION" \
		"TRANSIT_DEGRADATION" "medium"
fi

# Scenario 5: PROXY_BROKEN + fd high
if [ -z "$SINGLE_SCENARIO" ] || [ "$SINGLE_SCENARIO" = "PROXY_BROKEN_FD" ]; then
	run_scenario "PROXY_BROKEN_FD" \
		"PROXY_BROKEN_FD" "PROXY_BROKEN" "" \
		"PROXY_BROKEN_RESOURCE" "high"
fi

# Scenario 6: CN exit
if [ -z "$SINGLE_SCENARIO" ] || [ "$SINGLE_SCENARIO" = "CN_EXIT" ]; then
	run_scenario "CN_EXIT" \
		"CN_EXIT" "CN" "" \
		"CN_EXIT_SINGLE_NODE" "medium"
fi

# Summary
TOTAL_ELAPSED=$(($(date +%s) - TOTAL_START))
echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed (${TOTAL_ELAPSED}s total) ==="

# Timing check
if [ "$TOTAL_ELAPSED" -gt 30 ]; then
	echo "WARN: total time ${TOTAL_ELAPSED}s exceeds 30s budget"
fi

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
