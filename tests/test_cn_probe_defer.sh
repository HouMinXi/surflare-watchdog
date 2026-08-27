#!/usr/bin/env bash
# Tests for the CN-defer fix in check_vpn_health (fix/cn-probe-race).
# Line-anchored extraction of two blocks from the production watchdog,
# each wrapped in a function body so `local` parses, then scenario
# fixtures run against them.
#
# Block anchors (surflare_watchdog.sh):
#   LOOP_CN  : "# Check country probes" .. first "^	done$" after it
#   FINAL_CN : "Final check after wait" .. the "fi" closing the
#              deferred-CN fallback ("result=\"$_cn_candidate\"" +1)
set -u
cd "$(dirname "$0")/.." || exit 1
WATCHDOG="surflare_watchdog.sh"
PASS=0; FAIL=0

ok()  { PASS=$((PASS+1)); echo "PASS $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1  [$2]"; }

# --- line-anchored extraction (start line, end pattern after start) ---
extract_block() { # $1=start_pattern  $2=end_regex
    local start end
    start=$(grep -n "$1" "$WATCHDOG" | head -1 | cut -d: -f1)
    [ -n "$start" ] || return 1
    end=$(awk -v s="$start" 'NR>s && /'"$2"'/{print NR; exit}' "$WATCHDOG")
    [ -n "$end" ] || return 1
    sed -n "${start},${end}p" "$WATCHDOG"
}

# "done" at exactly 2-tab indent closes the country-probe for-loop;
# a 3-tab "done" (outer constructs) must not match.
# shellcheck disable=SC2016  # $ must stay literal: patterns match watchdog source
LOOP_CN=$(extract_block "# Check country probes" '^		done$')
# shellcheck disable=SC2016  # literal source pattern
FINAL_CN=$(extract_block "# Final check after wait" 'result="\$_cn_candidate"')
# The extraction stops at the deferred-CN assignment in the FINAL block;
# the next TWO lines are its closing fi (deferred-if) and the enclosing
# country-probe if's fi.  The outermost `if [ -z "$result" ]` wrapper's
# fi sits past the IP-probe section, so a synthetic one is appended.
# shellcheck disable=SC2016  # literal source pattern
_fin_assign=$(grep -n 'result="\$_cn_candidate"' "$WATCHDOG" | tail -1 | cut -d: -f1)
_tail=$(sed -n "$((_fin_assign + 1)),$((_fin_assign + 2))p" "$WATCHDOG")
FINAL_CN="$(printf '%s\n' "$FINAL_CN")
$_tail
	fi"
[ -n "$LOOP_CN" ] || { echo "FATAL: loop extraction empty"; exit 1; }
printf '%s\n' "$FINAL_CN" | grep -q '_cn_candidate' || { echo "FATAL: final extraction incomplete"; exit 1; }

# run_loop: extracted block inside a function with while+for nesting matching
# production (so `local` is legal and `break 2` breaks for + while).
# args: cf cf2 ifc secs cand
run_loop() {
    local d; d=$(mktemp -d)
    printf '%s' "$1" > "$d/t1"; printf '%s' "$2" > "$d/t2"; printf '%s' "$3" > "$d/t3"
    bash -c "
        probe_block() {
            while true; do
$(printf '%s\n' "$LOOP_CN")
                break
            done
        }
        _cn_candidate='$5'; _cn_wait_start=0; SECONDS=$4
        tmp_cf='$d/t1'; tmp_cf2='$d/t2'; tmp_ifc='$d/t3'
        result=''
        probe_block
        echo \"\${result:-EMPTY}|\${_cn_candidate:-NONE}\"
    " 2>&1
    rm -rf "$d"
}

out=$(run_loop "CN" "" "" 0 "")
case "$out" in
    "EMPTY|CN") ok "T1 CN deferred (result unset, candidate recorded)" ;;
    "CN|CN")    bad T1 "CN won the race -- defer missing" ;;
    *)          bad T1 "unexpected: $out" ;;
esac

out=$(run_loop "CN" "" "" 4 "CN")
case "$out" in
    "EMPTY|CN") ok "T2 candidate preserved for deadline confirm" ;;
    *)          bad T2 "unexpected: $out" ;;
esac

out=$(run_loop "CN" "US" "" 0 "CN")
case "$out" in
    "US|CN") ok "T3 non-CN beats deferred CN" ;;
    *)       bad T3 "unexpected: $out" ;;
esac

run_final() { # args: cf cf2 ifc candidate google_done(0=hang,1=done)
    local d; d=$(mktemp -d)
    printf '%s' "$1" > "$d/a"; printf '%s' "$2" > "$d/b"; printf '%s' "$3" > "$d/c"
    : > "$d/g"
    if [ "$5" = "1" ]; then
        printf 'time_total 0.8\n' > "$d/gt"
    else
        : > "$d/gt"
    fi
    sleep 30 & pid_g=$!
    bash -c "
        final_block() {
$(printf '%s\n' "$FINAL_CN")
        }
        _cn_candidate='$4'; result=''
        tmp_g='$d/g'; tmp_gt='$d/gt'; pid_g=$pid_g
        tmp_cf='$d/a'; tmp_cf2='$d/b'; tmp_ifc='$d/c'
        final_block
        echo \"\${result:-EMPTY}\"
    " 2>&1
    kill "$pid_g" 2>/dev/null
    rm -rf "$d"
}
# trap ensures a witness sleep never outlives the test script even when a
# later assertion aborts between spawn and the explicit kill above.  pid_g
# starts empty so the trap is safe before the first run_final call.
pid_g=""
trap 'kill "$pid_g" 2>/dev/null' EXIT

out=$(run_final "CN" "US" "" "CN" 1)
case "$out" in
    "US") ok "T4 final-check non-CN precedence" ;;
    "CN") bad T4 "CN file outranked non-CN file" ;;
    *)    bad T4 "unexpected: $out" ;;
esac

out=$(run_final "CN" "" "" "CN" 1)
case "$out" in
    "CN") ok "T5 final-check deferred CN fallback" ;;
    *)    bad T5 "unexpected: $out" ;;
esac

# T4b/T5b: google-witness gate from the polling loop.  Extract the actual
# deferred-confirm branch (comment anchor to the enclosing done) and run
# scenario fixtures against it: hanging google (empty gt, live pid) must
# block CN; settled witness (timing file) must confirm.
WITNESS=$(extract_block "# CN deferred: confirm only after the settle window" '^\t\tdone$')
printf '%s\n' "$WITNESS" | grep -q 'kill -0' || { echo "FATAL: witness extraction empty"; exit 1; }

run_witness() { # args: gt_content(empty=hang) pid_alive(0=dead,1=alive)
    local d; d=$(mktemp -d)
    if [ -n "$1" ]; then printf '%s\n' "$1" > "$d/gt"; else : > "$d/gt"; fi
    if [ "$2" = "1" ]; then
        sleep 30 & pid_g=$!
    else
        # real dead process: spawn + wait, so pid_g held a live PID once
        sleep 0.1 & pid_g=$!
        wait "$pid_g" 2>/dev/null
    fi
    bash -c "
        log() { :; }   # sandbox: production log() writes /dev/kmsg
        witness_block() {
            while true; do
$(printf '%s\n' "$WITNESS")
                break
            done
        }
        _cn_candidate='CN'; _cn_wait_start=0; SECONDS=5
        tmp_gt='$d/gt'; pid_g=$pid_g
        result=''
        witness_block
        echo \"\${result:-EMPTY}\"
    " 2>&1
    kill "$pid_g" 2>/dev/null
    rm -rf "$d"
}

out=$(run_witness "" 1)
case "$out" in
    "EMPTY") ok "T4b witness gate: hanging google blocks CN" ;;
    *)       bad T4b "unexpected: $out" ;;
esac

out=$(run_witness "time_total 0.8" 1)
case "$out" in
    "CN") ok "T5b witness gate: settled witness confirms CN" ;;
    *)    bad T5b "unexpected: $out" ;;
esac

out=$(run_witness "" 0)
case "$out" in
    "CN") ok "T5c witness gate: dead google probe confirms CN" ;;
    "EMPTY") bad T5c "dead probe not treated as finished witness" ;;
    *)    bad T5c "unexpected: $out" ;;
esac

# T6 bug-inject: disable deferral; T1 scenario must flip to CN-wins.
# Target the specific inner CN-defer branch anchor in LOOP_CN.
INJ=$(printf '%s\n' "$LOOP_CN" | awk '{
    if ($0 ~ /r_country.*=.*"CN"/) {
        print "\t\t\t\tif false; then"
    } else {
        print $0
    }
}')
d=$(mktemp -d); printf 'CN' > "$d/t1"; printf '' > "$d/t2"; printf '' > "$d/t3"
out=$(bash -c "
    probe_block() {
        while true; do
$(printf '%s\n' "$INJ")
            break
        done
    }
    _cn_candidate=''; _cn_wait_start=0; SECONDS=0
    tmp_cf='$d/t1'; tmp_cf2='$d/t2'; tmp_ifc='$d/t3'
    result=''
    probe_block
    echo \"\${result:-EMPTY}|\${_cn_candidate:-NONE}\"
" 2>&1)
rm -rf "$d"
case "$out" in
    "CN|CN"|"CN|NONE") ok "T6 bug-inject flips to CN (deferral load-bearing)" ;;
    "EMPTY|CN") bad T6 "injection ineffective" ;;
    *)         bad T6 "unexpected: $out" ;;
esac

# T7 regression: the full watchdog still parses and the wrapper carries
# the four user-facing domains.
_wrapper_domains=$(grep -m1 '^INJECT_DOMAINS=' scripts/surflare-proxy-wrapper.sh | cut -d'"' -f2)
if bash -n "$WATCHDOG" \
   && grep -q 'claude.ai' <<<"$_wrapper_domains" \
   && grep -q 'google.com' <<<"$_wrapper_domains" \
   && grep -q 'gemini.google.com' <<<"$_wrapper_domains"; then
    ok "T7 wrapper domains + watchdog syntax"
else
    bad T7 "wrapper domains missing or watchdog syntax error"
fi

echo
echo "RESULT: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
