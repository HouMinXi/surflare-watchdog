#!/usr/bin/env bash
# route_updater curl timeouts: every network fetch needs a hard --max-time.
# 2026-10-02 P0: the 09-29 02:30 instance hung for 4 days on a curl with
# only --connect-timeout, wedged in do_wait forever.  The heartbeat kept
# the lock fresh, the watchdog kept suppressing health escalation, and a
# real outage went undetected.  This test pins the fix: all curl invocations
# in BOTH updater copies carry --max-time.
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

check_curls() {  # $1=file $2=min-expected
    local f="$1" need="$2"
    [ -f "$f" ] || { bad "$f missing"; return; }
    # Join backslash-newline continuations, then extract every curl call
    # up to the first shell separator so flags on the next line count.
    local total=0 missing=0 c
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        total=$((total + 1))
        if ! printf '%s' "$c" | grep -q -- '--max-time'; then
            missing=$((missing + 1))
            bad "$f curl without --max-time: ${c:0:90}"
        fi
    done < <(sed ':a; /\\$/{N; s/\\\n[[:space:]]*/ /; ba}' "$f" \
             | grep -oE 'curl (-[^ ]+ +| )+[^|;&)]*' | sed 's/ *$//')
    [ "$total" -ge "$need" ] && ok "$f: found $total curl invocations" \
        || bad "$f: expected >=$need curls, found $total (extraction broken?)"
    [ "$missing" -eq 0 ] && ok "$f: every curl carries --max-time" \
        || bad "$f: $missing curl(s) missing --max-time"
    bash -n "$f" && ok "$f: bash -n" || bad "$f: bash -n"
}

# router copy: curls live in the ripe_fetch helper (1 literal) + serial
# fetches + Source B; count what the extractor can see.  The timeout
# requirement is per curl call site, and the helper's single curl site
# covers all 8 RIPE targets.
check_curls router/surflare_route_updater.sh 5
# The 8 RIPE targets themselves must all be wired through the helper:
# a dropped ripe_fetch call silently skips an ASN (WARN-only path).
# The 8 RIPE targets must all go through the one-arg helper (any name).
n_ripe=$(sed -n '/_curl_pids="\$_curl_pids/,$p' router/surflare_route_updater.sh | grep -cE '^[[:space:]]*[a-z_]+ "\$RIPE_CONSIST')
[ "$n_ripe" -eq 8 ] && ok "router: all 8 RIPE targets wired through the helper" \
    || bad "router: expected 8 helper calls for RIPE targets, found $n_ripe"
# PID collection must happen at spawn time inside the helper.
grep -q '_curl_pids="$_curl_pids $!"' router/surflare_route_updater.sh \
    && ok "router: curl PIDs collected at spawn" \
    || bad "router: PID collection missing (wait would collect nothing or everything)"
# laptop copy: 8 curls (same fetches, no lock/heartbeat machinery)
check_curls laptop/surflare_route_updater.sh 8

echo "FAIL=$fail"
exit $fail
