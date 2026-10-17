#!/bin/sh
# TDD defect-injection harness for the ded-exit layer (runs on N100,
# read-only wrt the live service: it only builds configs in /tmp).
#
# Two injections, each must flip an assertion from PASS to FAIL:
#   J1: drop the guard-rule prepend in filter-new2 (socks-in-socks
#       recursion hole for the :20812 forwarder -> guard rule must be
#       absent from the output)
#   J2: drop the canary inbound injection (canary has nothing to probe)
# Both injections are applied to a COPY of the filter; the worktree
# file is never touched.
#
# The dedicated endpoint in this harness is a TEST-NET-3 placeholder
# (203.0.113.77); the assertions are structural, any address works.
# See README.md for how to capture a raw config as input.

set -u
FILTER="$(dirname "$0")/filter-new2.jq"
# Default input is the committed hermetic fixture; pass a captured
# raw config path for full realism (see README).
DED_IP="203.0.113.77"
# creds travel via env (see wrapper header); export the TEST-NET stand-ins
export DED_SERVER="$DED_IP" DED_PORT=13258 DED_USER=u DED_PASS=w
IN="${1:-$(dirname "$0")/fixture-input.json}"

fail=0

# --- baseline assertions (must hold on the pristine filter) ----------
jq --argjson T 300 --arg I 60s --arg D claude.com,claude.ai,google.com --arg DD minxihou.site \
   --arg DE 1 \
   -f "$FILTER" "$IN" > /tmp/inj-base.json
if jq -e '.route.rules[0].ip_cidr == ["'"$DED_IP"'/32"] and .route.rules[0].outbound != "ded-exit"' /tmp/inj-base.json >/dev/null; then
    echo "PASS base: guard rule present and not ded-exit"
else
    echo "FAIL base guard"; fail=1
fi
# read the canary port so this assertion cross-references the two
# hardcoded copies (filter vs canary script) and fails on either drift
_cport=$(sed -n "s/^CANARY_PORT=//p" "$(dirname "$0")/../router/services/surflare-dedicated/surflare-ded-canary" | head -1)
if jq -e --argjson cp "${_cport:-0}" '[.inbounds[] | select(.tag == "ded-canary-in" and .listen == "127.0.0.1" and .listen_port == $cp)] | length == 1' /tmp/inj-base.json >/dev/null; then
    echo "PASS base: canary inbound present"
else
    echo "FAIL base canary"; fail=1
fi
if jq -e '.route.final == "ded-exit"' /tmp/inj-base.json >/dev/null; then
    echo "PASS base: route.final is ded-exit when the layer is on"
else
    echo "FAIL base final"; fail=1
fi

# The dedicated SOCKS refuses plain HTTP (code=5, observed on live):
# the bypass must sit right before the first port-unconstrained
# ded-exit rule, so rules that already name a port (captive-portal
# probes, DNS hijack) keep their own outbound.
_p80=$(jq -r 'first(.route.rules | to_entries[] | select(.value.outbound == "ded-exit" and (.value | has("port") | not)) | .key)' /tmp/inj-base.json)
if jq -e --argjson i "$_p80" '.route.rules[($i - 1)].port == [80] and .route.rules[($i - 1)].outbound != "ded-exit" and .route.rules[($i - 1)].outbound != "direct"' /tmp/inj-base.json >/dev/null; then
    echo "PASS base: port-80 bypass sits before the first unconstrained ded-exit rule"
else
    echo "FAIL base port80"; fail=1
fi

# --- J10: without the port-80 bypass rule the assertion above goes red
# shellcheck disable=SC2016  # $i/$vpn are LITERAL jq tokens in the
# filter file being edited, not shell expansions to perform
sed '/first(to_entries\[\] | select(.value.outbound == "ded-exit"/,/ + .[\$$i:])/d' "$FILTER" > /tmp/filter-j10.jq
jq --argjson T 300 --arg I 60s --arg D claude.com,claude.ai,google.com --arg DD minxihou.site \
   --arg DE 1 \
   -f /tmp/filter-j10.jq "$IN" > /tmp/inj-j10.json
if jq -e --argjson i "$_p80" '.route.rules[($i - 1)].port == [80] and .route.rules[($i - 1)].outbound != "ded-exit"' /tmp/inj-j10.json >/dev/null; then
    echo "FAIL J10: port-80 bypass still present after injection (injection ineffective)"; fail=1
else
    echo "PASS J10: port-80 bypass gone -> assertion correctly red"
fi
if jq -e '([.outbounds[] | select(.tag == "ded-exit" and .detour != null and .detour != "direct")] | length == 1) and ([.route.rules[] | select(.ip_cidr == ["'"$DED_IP"'/32"] and .outbound != "ded-exit")] | length == 1)' /tmp/inj-base.json >/dev/null; then
    echo "PASS base: ded-exit detours via carrier; guard rule stays on carrier"
else
    echo "FAIL base detour/guard"; fail=1
fi

# --- J1: remove guard prepend ---------------------------------------
# shellcheck disable=SC2016  # $ENV/$vpn are LITERAL jq tokens in the
# filter file being edited, not shell expansions to perform
sed 's#{"ip_cidr": \[\$ENV\.DED_SERVER + "/32"\], "outbound": \$vpn}##' "$FILTER" > /tmp/filter-j1.jq
jq --argjson T 300 --arg I 60s --arg D claude.com,claude.ai,google.com --arg DD minxihou.site \
   --arg DE 1 \
   -f /tmp/filter-j1.jq "$IN" > /tmp/inj-j1.json
if jq -e '.route.rules[0].ip_cidr == ["'"$DED_IP"'/32"]' /tmp/inj-j1.json >/dev/null; then
    echo "FAIL J1: guard rule still present after injection (injection ineffective)"; fail=1
else
    echo "PASS J1: guard rule gone -> assertion correctly red"
fi

# --- J2: remove canary inbound ---------------------------------------
# shellcheck disable=SC2016  # same: literal jq fragments, not shell text
sed 's#| .inbounds += \[{##; s#"type": "mixed",##; s#"tag": "ded-canary-in",##; s#"listen": "127.0.0.1",##; s#"listen_port": '"${_cport:-20814}"'##; s#      }]##' "$FILTER" > /tmp/filter-j2.jq
jq --argjson T 300 --arg I 60s --arg D claude.com,claude.ai,google.com --arg DD minxihou.site \
   --arg DE 1 \
   -f /tmp/filter-j2.jq "$IN" > /tmp/inj-j2.json 2>/tmp/j2err.txt
if jq -e '[.inbounds[] | select(.tag == "ded-canary-in")] | length == 1' /tmp/inj-j2.json >/dev/null 2>&1; then
    echo "FAIL J2: canary inbound still present after injection (injection ineffective)"; fail=1
else
    echo "PASS J2: canary inbound gone -> assertion correctly red"
fi

# --- canary flip logic (pure shell, source-only harness) -------------
# Simulate: canary down + tcp ok -> conf must flip to 0.
tconf=$(mktemp)
printf 'EXIT_VIA_DED="1"\nDED_SERVER="%s"\nDED_PORT="13258"\n' "$DED_IP" > "$tconf"
sed -i 's/^EXIT_VIA_DED=.*/EXIT_VIA_DED="0"/' "$tconf"
if grep -q '^EXIT_VIA_DED="0"$' "$tconf"; then
    echo "PASS J3: canary flip rewrites conf (quoted form kept)"
else
    echo "FAIL J3"; fail=1
fi
rm -f "$tconf"

# J3b: unquoted values must parse to the same result (the quote
# stripping in _ded_read_conf must handle both forms)
tconf=$(mktemp)
printf 'EXIT_VIA_DED=1\nDED_SERVER=%s\nDED_PORT=13258\n' "$DED_IP" > "$tconf"
sed -i 's/^EXIT_VIA_DED=.*/EXIT_VIA_DED="0"/' "$tconf"
if grep -q '^EXIT_VIA_DED="0"$' "$tconf"; then
    echo "PASS J3b: unquoted input rewrites to the quoted form"
else
    echo "FAIL J3b"; fail=1
fi
rm -f "$tconf"

# J3c: the flip must be the reattach script's own line, not a copy.
# Extract it, run it against a quoted conf, and require the quotes to
# survive.  A second pass drops the quotes from that line and must go
# RED -- that is the defect this assertion exists to catch.
reattach_flip="$(dirname "$0")/../router/services/surflare-dedicated/surflare-ded-reattach"
_flip=$(grep -E "^[[:space:]]*sed -i 's/\^EXIT_VIA_DED=" "$reattach_flip" | head -1)
_flip=$(printf '%s\n' "$_flip" | sed 's/^[[:space:]]*//')
tconf=$(mktemp)
printf 'EXIT_VIA_DED="0"\nDED_SERVER="%s"\n' "$DED_IP" > "$tconf"
CONF="$tconf" sh -c "$_flip"
if grep -q '^EXIT_VIA_DED="1"$' "$tconf"; then
    echo "PASS J3c: reattach flip keeps the quoted form"
else
    echo "FAIL J3c: reattach flip dropped the quotes"; fail=1
fi
_bad=$(printf '%s\n' "$_flip" | tr -d '"')
printf 'EXIT_VIA_DED="0"\n' > "$tconf"
CONF="$tconf" sh -c "$_bad"
if grep -q '^EXIT_VIA_DED="1"$' "$tconf"; then
    echo "FAIL J3c-control: bare rewrite not flagged -- assertion toothless"; fail=1
else
    echo "PASS J3c-control: bare rewrite flagged (red-as-expected)"
fi
rm -f "$tconf"

# J3d: while the layer is off the canary must drop a leftover streak.
# Extract the disabled arm from the canary itself and run it.  The
# control deletes that rm and must leave the streak behind.
canary_src="$(dirname "$0")/../router/services/surflare-dedicated/surflare-ded-canary"
# shellcheck disable=SC2016  # the $ is part of the source line being matched, not this script
_arm_start=$(grep -nxF 'case "$EXIT_VIA_DED" in' "$canary_src" | head -1 | cut -d: -f1)
_arm_end=$(awk -v s="$_arm_start" 'NR>s && $0 ~ /^esac$/ {print NR; exit}' "$canary_src")
_arm=$(sed -n "$((_arm_start + 3)),$((_arm_end - 1))p" "$canary_src" | sed 's/;;$//')
_sd=$(mktemp -d)
STATE_DIR="$_sd" EXIT_VIA_DED=0 sh -c ": > \"\$STATE_DIR/fail_streak\"; $_arm"
if [ -f "$_sd/fail_streak" ]; then
    echo "FAIL J3d: disabled canary kept the stale streak"; fail=1
else
    echo "PASS J3d: disabled canary drops the stale streak"
fi
: > "$_sd/fail_streak"
_arm_bad=$(printf '%s\n' "$_arm" | grep -v 'fail_streak')
STATE_DIR="$_sd" EXIT_VIA_DED=0 sh -c "$_arm_bad"
if [ -f "$_sd/fail_streak" ]; then
    echo "PASS J3d-control: missing rm flagged (red-as-expected)"
else
    echo "FAIL J3d-control: missing rm not flagged -- assertion toothless"; fail=1
fi
rm -rf "$_sd"

# --- J4: reattach shadow jq must inject the same topology as the
# wrapper (drift here means the daily probe tests a different chain
# than production).  The reattach runs on the CLOSED-state patched
# config in production (EXIT_VIA_DED=0 when the layer is off), so the
# symmetry test feeds it exactly that: wrapper(closed) -> reattach
# must equal wrapper(de1) with only the inbounds differing (canary-in
# vs shadow-in). -----------------------------------------------
reattach="$(dirname "$0")/../router/services/surflare-dedicated/surflare-ded-reattach"
prog=/tmp/reattach-prog.jq
# Extract the embedded single-quoted jq program: starts at the line
# "     '([.outbounds", ends at the first "' " (closing shell quote)
# on its last line; the '"$SHADOW_PORT"' shell interpolation inside
# is resolved to a literal port.  The quote character travels via
# -v so no quoting acrobatics live in this script.  The replacement
# port is also resolved from the reattach script itself so a stale
# literal cannot bake into the extracted program.
_sport=$(sed -n "s/^SHADOW_PORT=//p" "$reattach" | head -1)
awk -v sq="'" -v rp="${_sport:-20815}" '
    !p && index($0, ("     " sq "([.outbounds")) == 1 {
        p = 1
        $0 = substr($0, 7)
    }
    p {
        e = index($0, (sq " "))
        if (e > 0) {
            $0 = substr($0, 1, e - 1)
            s = sq "\"" "$SHADOW_PORT" "\"" sq
            i = index($0, s)
            if (i > 0)
                $0 = substr($0, 1, i - 1) rp substr($0, i + length(s))
            print
            exit
        }
        print
    }
' "$reattach" > "$prog"
jq --argjson T 300 --arg I 60s --arg D claude.com,claude.ai,google.com --arg DD minxihou.site \
   --arg DE "" \
   -f "$FILTER" "$IN" > /tmp/inj-closed.json
# sanity: whitespace drift in the reattach file would make the awk
# extract an empty/stale program; fail loudly with the root cause
if ! grep -q '(\[.outbounds' "$prog" 2>/dev/null; then
    echo "FAIL J4: extracted reattach program is empty or malformed (extraction missed the jq program -- reformat of surflare-ded-reattach?)"; fail=1
elif jq \
      -f "$prog" /tmp/inj-closed.json > /tmp/inj-j4.json 2>/dev/null; then
    a=$(jq -cS 'del(.inbounds)' /tmp/inj-base.json | md5sum | cut -d' ' -f1)
    b=$(jq -cS 'del(.inbounds)' /tmp/inj-j4.json | md5sum | cut -d' ' -f1)
    if [ "$a" = "$b" ]; then
        echo "PASS J4: reattach shadow topology identical to wrapper (ex-inbounds)"
    else
        echo "FAIL J4: reattach shadow topology drifted from wrapper"; fail=1
    fi
else
    echo "FAIL J4: could not run extracted reattach jq program"; fail=1
fi

# --- A1: closed-state equivalence (EXIT_VIA_DED off => the patched
# wrapper must produce byte-identical output to the legacy filter) --
new_sum=$(jq --argjson T 300 --arg I 60s --arg D claude.com,claude.ai,google.com --arg DD minxihou.site \
   --arg DE "" \
   -f "$FILTER" "$IN" | md5sum | cut -d' ' -f1)
old_sum=$(jq --argjson T 300 --arg I 60s --arg D claude.com,claude.ai,google.com --arg DD minxihou.site \
   -f "$(dirname "$0")/filter-old.jq" "$IN" | md5sum | cut -d' ' -f1)
if [ "$new_sum" = "$old_sum" ]; then
    echo "PASS A1: closed-state output byte-identical to legacy filter"
else
    echo "FAIL A1: closed-state output drifted from legacy filter"; fail=1
fi

# --- J5: tests/filter-new2.jq must stay byte-identical to the jq
# program embedded in the wrapper (README contract, now enforced) ---
wrapper="$(dirname "$0")/../router/surflare-proxy"
wprog=/tmp/wrapper-prog.jq
awk -v sq="'" '
    index($0, "if jq --argjson T ") == 1 { p = 1; next }
    p && index($0, (sq " < " "\"" "$_tmp" "\"")) == 1 { exit }
    p { print }
' "$wrapper" > "$wprog"
if cmp -s "$wprog" "$FILTER"; then
    echo "PASS J5: wrapper jq program byte-identical to tests copy"
else
    echo "FAIL J5: wrapper jq program drifted from tests/filter-new2.jq"; fail=1
fi

# --- J6: layer ON but no carrier urltest -> graceful no-injection ---
jq '.outbounds |= map(select(.type != "urltest"))' "$IN" > /tmp/inj-noutest.json
jq --argjson T 300 --arg I 60s --arg D claude.com,claude.ai,google.com --arg DD minxihou.site \
   --arg DE 1 \
   -f "$FILTER" /tmp/inj-noutest.json > /tmp/inj-j6.json 2>/dev/null
if jq -e '([.outbounds[] | select(.tag == "ded-exit")] | length == 0) and (.route.final != "ded-exit")' /tmp/inj-j6.json >/dev/null 2>&1; then
    echo "PASS J6: no carrier -> no ded-exit injected, final not ded-exit"
else
    echo "FAIL J6: ded-exit injected without a carrier"; fail=1
fi

# --- J7: the conf parser/validator must stay in sync across the three
# copies (wrapper, canary, reattach) -- normalize tabs and compare ---
# Extract the function, normalize (tabs to spaces, comments and blank
# lines dropped) so only executable statements are compared: the three
# copies carry different explanatory prose by design.
_extract_fn() {
    awk -v fn="$2" '
        index($0, (fn "() {")) == 1 { p = 1 }
        p {
            sub(/#.*/, "")
            gsub(/\t/, "    ")
            if ($0 ~ /[^ ]/) print
        }
        p && /^}/ { exit }
    ' "$1"
}
_w=$(_extract_fn "$(dirname "$0")/../router/surflare-proxy" _ded_read_conf)$(_extract_fn "$(dirname "$0")/../router/surflare-proxy" _ded_conf_valid)
_c=$(_extract_fn "$(dirname "$0")/../router/services/surflare-dedicated/surflare-ded-canary" _ded_read_conf)$(_extract_fn "$(dirname "$0")/../router/services/surflare-dedicated/surflare-ded-canary" _ded_conf_valid)
_r=$(_extract_fn "$(dirname "$0")/../router/services/surflare-dedicated/surflare-ded-reattach" _ded_read_conf)$(_extract_fn "$(dirname "$0")/../router/services/surflare-dedicated/surflare-ded-reattach" _ded_conf_valid)
if [ "$_w" = "$_c" ] && [ "$_c" = "$_r" ]; then
    echo "PASS J7: conf parser/validator identical across wrapper, canary, reattach"
else
    echo "FAIL J7: conf parser/validator copies drifted"; fail=1
fi

# --- baseline integrity: filter-old.jq is the frozen legacy snapshot;
# pin its checksum so silent edits to the baseline cannot make A1
# compare against a moving target ------------------------------------
old_md5=$(md5sum "$(dirname "$0")/filter-old.jq" | cut -d' ' -f1)
# Checksum of the legacy filter snapshot taken from the live N100
# wrapper (md5 0670f2c6b26f7bb9b2e1d99c6ef0f822 baseline) before the
# ded-exit work.  To update INTENTIONALLY: re-freeze from a verified
# legacy source, then refresh this constant in the same commit.
OLD_EXPECTED="f191d55ad1e08cdb725b7f9139a89d85"
if [ "$old_md5" = "$OLD_EXPECTED" ]; then
    echo "PASS baseline: filter-old.jq matches frozen checksum"
else
    echo "FAIL baseline: filter-old.jq drifted from frozen checksum ($old_md5)"; fail=1
fi

# --- J8: the reattach jq program, run through the SAME shell quoting
# the script uses in production, must yield a NUMERIC listen_port --
# sing-box rejects a string there and the daily reattach would fail
# binary check forever.  A generated runner script (not eval-quoting
# inline) reproduces the '"$SHADOW_PORT"' quote-break verbatim. --------
rawprog=$(mktemp)
awk -v sq="'" '
    !p && index($0, ("     " sq "([.outbounds")) == 1 {
        p = 1
        $0 = substr($0, 7)
    }
    p {
        e = index($0, (sq " "))
        if (e > 0) {
            $0 = substr($0, 1, e - 1)
            print
            exit
        }
        print
    }
' "$reattach" > "$rawprog"
j8run=$(mktemp)
{
    printf 'SHADOW_PORT=%s\n' "${_sport:-20815}"
    printf "jq '"
    cat "$rawprog"
    printf "' /tmp/inj-closed.json > /tmp/inj-j8.json\n"
} > "$j8run"
if sh "$j8run" 2>/dev/null    && [ "$(jq -r '.inbounds[0].listen_port | type' /tmp/inj-j8.json 2>/dev/null)" = "number" ]; then
    echo "PASS J8: production quoting yields numeric listen_port"
else
    echo "FAIL J8: reattach listen_port is not numeric under production quoting"; fail=1
fi
# J8-control (defect injection): the identical assertion must go RED
# for a string-typed port -- otherwise J8 has no teeth
jq -n --arg p "${_sport:-20815}" '{"inbounds":[{"listen_port":$p}]}' > /tmp/inj-j8c.json
if [ "$(jq -r '.inbounds[0].listen_port | type' /tmp/inj-j8c.json)" = "number" ]; then
    echo "FAIL J8-control: string port reported numeric -- assertion toothless"; fail=1
else
    echo "PASS J8-control: string port correctly reported as string (red-as-expected)"
fi
rm -f "$rawprog" "$j8run" /tmp/inj-j8.json /tmp/inj-j8c.json

# --- J9: the legacy rules[-1] repoint must hit the terminal catch-all,
# never the private-IP bypass.  Production's last rule is the tproxy-in
# catch-all; the fixture mirrors that shape.  Two assertions on the
# closed-state output: private-IP bypass stays direct, last rule is
# repointed to the carrier. ------------------------------------------------
_j9check() {
    jq -e '[.route.rules[] | select(.ip_cidr != null and (.ip_cidr | index("10.0.0.0/8")))][0].outbound == "direct"' "$1" >/dev/null 2>&1 \
        && jq -e '.route.rules[-1].outbound == "mh_via_test"' "$1" >/dev/null 2>&1
}
if _j9check /tmp/inj-closed.json; then
    echo "PASS J9: private-IP bypass stays direct, catch-all repointed to carrier"
else
    echo "FAIL J9: rules[-1] repoint hit the wrong rule (fixture shape regression)"; fail=1
fi
# J9-control (defect injection): a repoint that hit the private-IP
# bypass instead must make the check go RED
jq '.route.rules |= map(if .ip_cidr != null then .outbound = "mh_via_test" else . end)' \
    /tmp/inj-closed.json > /tmp/inj-j9c.json
if _j9check /tmp/inj-j9c.json; then
    echo "FAIL J9-control: misdirected repoint not flagged -- assertion toothless"; fail=1
else
    echo "PASS J9-control: misdirected repoint flagged (red-as-expected)"
fi
rm -f /tmp/inj-j9c.json

if [ "$fail" -eq 0 ]; then
    echo "=== ALL INJECTION CHECKS RED-AS-EXPECTED ==="
else
    echo "=== INJECTION HARNESS FAILED ==="
fi
exit "$fail"
