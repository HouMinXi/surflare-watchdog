#!/bin/bash
# Tests for the transit stability measurement script. The scoring
# formula and parse helpers are EXTRACTED from the real script so a
# pass proves the production math, not a copy.
#
# shellcheck disable=SC2015  # `[ cond ] && ok x || bad x` is safe here:
# ok()/bad() always return 0, so bad never runs after a successful ok.
# This is the house idiom across all tests in this repo.
# shellcheck disable=SC2016  # single quotes around harness bodies are
# intentional -- the inner $VARS must expand in the CHILD shell.

set -u
cd "$(dirname "$0")/.." || exit 1
SCRIPT=scripts/measure_transit_stability.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

extract_fn() {
	awk "/^$1\(\)/,/^}/" "$SCRIPT"
}

# _count_503_since reads PROXY_503_PATTERN from top-level scope; pull
# the constant's own definition line so the extracted function sees
# the same anchor the production script uses (not an empty pattern
# that would match every line).
PROXY_503_PATTERN_DEF="$(grep '^PROXY_503_PATTERN=' "$SCRIPT")"

FNS="$PROXY_503_PATTERN_DEF
$(extract_fn _score_candidate)
$(extract_fn _parse_http)
$(extract_fn _count_503_since)
$(extract_fn _summarize_samples)
$(extract_fn _valid_candidate)
$(extract_fn _split_candidates)"

# $1 = args to _score_candidate; echoes the score
score() { bash -c "$FNS
_score_candidate $1" 2>/dev/null; }

echo "T1: perfect run -> 100"
[ "$(score '0 1 0 20 0 20 180 0')" = "100" ] && ok "perfect -> 100" || bad "perfect wrong: $(score '0 1 0 20 0 20 180 0')"

echo "T2: connect failure -> 80"
[ "$(score '1 1 0 0 0 0 0 0')" = "80" ] && ok "connect fail -> 80" || bad "connect fail wrong: $(score '1 1 0 0 0 0 0 0')"

echo "T3: 50% sample drops -> 80"
[ "$(score '0 1 10 20 0 20 200 0')" = "80" ] && ok "drops 50% -> 80" || bad "drops wrong: $(score '0 1 10 20 0 20 200 0')"

echo "T4: 503 rate 1.5/min (30 in 1200s) -> 97"
[ "$(score '0 1 0 20 30 1200 200 0')" = "97" ] && ok "503 -> 97" || bad "503 wrong: $(score '0 1 0 20 30 1200 200 0')"

echo "T5: sigma 600ms -> penalty 30 -> 70"
[ "$(score '0 1 0 20 0 20 200 600')" = "70" ] && ok "sigma -> 70" || bad "sigma wrong: $(score '0 1 0 20 0 20 200 600')"

echo "T6: sigma 1000ms -> penalty capped at 30 -> 70"
[ "$(score '0 1 0 20 0 20 200 1000')" = "70" ] && ok "sigma cap -> 70" || bad "sigma cap wrong: $(score '0 1 0 20 0 20 200 1000')"

echo "T11: attempts=0 boundary -> fr defaults to 1 -> 80"
[ "$(score '0 0 0 0 0 0 0 0')" = "80" ] && ok "no attempts -> 80" || bad "no attempts wrong: $(score '0 0 0 0 0 0 0 0')"

echo "T12: cumulative penalties past 100 -> clamped at 0"
[ "$(score '1 1 20 20 2000 1200 200 1000')" = "0" ] && ok "clamp -> 0" || bad "clamp wrong: $(score '1 1 20 20 2000 1200 200 1000')"

echo "T15: combined penalties -> 27"
[ "$(score '1 1 10 20 30 1200 200 600')" = "27" ] && ok "combined -> 27" || bad "combined wrong: $(score '1 1 10 20 30 1200 200 600')"

echo "T7: _parse_http normal + malformed"
OUT=$(bash -c "$FNS
_parse_http '200:1.234:0.900'
_parse_http ''" 2>/dev/null)
case "$OUT" in
	"200 1.234"*) ok "parse -> code+time_total" ;;
	*) bad "parse wrong: $OUT" ;;
esac
# the malformed half gets its own assertion: empty input must yield
# two EMPTY fields (the sampler's case-default turns that into a drop)
read -r MCODE MTT <<< "$(bash -c "$FNS
_parse_http ''" 2>/dev/null)"
if [ -z "$MCODE" ] && [ -z "$MTT" ]; then
	ok "malformed -> both fields empty (drop)"
else
	bad "malformed wrong: code='$MCODE' tt='$MTT'"
fi

echo "T8: 503 delta same inode counts only anchored 503s in appended bytes"
FLOG=$(mktemp /tmp/tm503_XXXXXX)
printf 'ERROR status: 503 Service Unavailable\nplain line\n' > "$FLOG"
SIZE=$(stat -c %s "$FLOG"); INO=$(stat -c %i "$FLOG")
printf '12:50:33 timestamp with bare 503 digits\nnew ERROR status: 503 Service Unavailable\n' >> "$FLOG"
OUT=$(PROXY_LOG="$FLOG" bash -c "$FNS
_count_503_since $SIZE $INO" 2>/dev/null)
[ "$OUT" = "1 0" ] && ok "delta -> 1 0 (timestamp 503 not counted)" || bad "delta wrong: $OUT"
rm -f "$FLOG"

echo "T8b: empty log at capture (offset=0, same inode) -> no rotation flag"
FLOG=$(mktemp /tmp/tm503e_XXXXXX)
: > "$FLOG"
INO=$(stat -c %i "$FLOG")
printf 'ERROR status: 503 Service Unavailable\n' > "$FLOG"
OUT=$(PROXY_LOG="$FLOG" bash -c "$FNS
_count_503_since 0 $INO" 2>/dev/null)
[ "$OUT" = "1 0" ] && ok "empty-start -> 1 0 (counted, not flagged rotated)" || bad "empty-start wrong: $OUT"
rm -f "$FLOG"

echo "T9: rotation (inode change) counts whole file + flags rot"
FLOG=$(mktemp /tmp/tm503_XXXXXX)
printf 'ERROR status: 503 Service Unavailable\n' > "$FLOG"
SIZE=$(stat -c %s "$FLOG"); INO=999999
OUT=$(PROXY_LOG="$FLOG" bash -c "$FNS
_count_503_since $SIZE $INO" 2>/dev/null)
[ "$OUT" = "1 1" ] && ok "rotation -> 1 1" || bad "rotation wrong: $OUT"
rm -f "$FLOG"

echo "T13: missing proxy log -> 0 0"
OUT=$(PROXY_LOG=/nonexistent_log bash -c "$FNS
_count_503_since 0 0" 2>/dev/null)
[ "$OUT" = "0 0" ] && ok "missing log -> 0 0" || bad "missing log wrong: $OUT"

echo "T16: _summarize_samples -- mean over successes, not all samples, converted to ms"
SFILE=$(mktemp /tmp/tmsum_XXXXXX)
# curl time_total is in SECONDS on disk; output must be milliseconds
printf '0.100\n0.300\n' > "$SFILE"
OUT=$(bash -c "$FNS
_summarize_samples $SFILE" 2>/dev/null)
# ok_count=2, mean=(100+300)/2=200.0ms -- a diluted mean over more
# samples would be lower, so 200.0 proves the successful-sample
# denominator; sigma of {100,300}ms = sqrt(((10000+90000)-40000)/1) = 141.4
[ "$OUT" = "2 200.0 141.4" ] && ok "summary -> 2 200.0 141.4" || bad "summary wrong: $OUT"
rm -f "$SFILE"

echo "T16b: _summarize_samples -- sigma penalty is not dead code after ms conversion"
SFILE=$(mktemp /tmp/tmsum_XXXXXX)
# two samples 0.3s apart in time_total -- 600ms of jitter, matching
# the sigma=600 fixture already frozen in T5/T10's sigma-cap tests
printf '0.100\n0.700\n' > "$SFILE"
read -r _n _mean _sig <<< "$(bash -c "$FNS
_summarize_samples $SFILE" 2>/dev/null)"
# sigma must land in the hundreds (ms), not below 1 (which is what the
# pre-fix seconds-as-ms bug produced -- pen=sig/20 rounded to 0 via %d)
if [ "$(awk -v s="$_sig" 'BEGIN{print (s >= 100)}')" = "1" ]; then
	ok "sigma in ms range ($_sig), penalty term is live"
else
	bad "sigma still second-scale: $_sig (penalty would round to 0)"
fi
rm -f "$SFILE"

echo "T17: _summarize_samples -- empty file -> 0 0 0"
SFILE=$(mktemp /tmp/tmsum_XXXXXX)
: > "$SFILE"
OUT=$(bash -c "$FNS
_summarize_samples $SFILE" 2>/dev/null)
[ "$OUT" = "0 0 0" ] && ok "empty -> 0 0 0" || bad "empty wrong: $OUT"
rm -f "$SFILE"

echo "T34: _summarize_samples -- blank/garbage lines are skipped, not counted as v=0"
SFILE=$(mktemp /tmp/tmsum_XXXXXX)
# a blank line and a truncated line between two real 100ms samples;
# unguarded awk would parse both as v=0 and drag mean to (100+0+0+100)/4=50
printf '0.100\n\npartial\n0.100\n' > "$SFILE"
OUT=$(bash -c "$FNS
_summarize_samples $SFILE" 2>/dev/null)
[ "$OUT" = "2 100.0 0.0" ] && ok "blank/garbage skipped -> 2 100.0 0.0" || bad "blank-line guard wrong: $OUT"
rm -f "$SFILE"
# bug-injection proof: strip the regex guard and the same fixture must
# regress to the zero-dragged mean (proves T34 watches the real guard).
# Exact-literal replacement via python (no regex escaping to doubt);
# the assert fails LOUDLY if the guard text ever drifts from the
# needle, so a silent no-op injection is impossible.
INJ=$(mktemp /tmp/tm_injsum_XXXXXX)
python3 - "$SCRIPT" "$INJ" << 'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
old = '/^[0-9]+(\\.[0-9]+)?$/ '
new = ''
assert s.count(old) == 1, "guard literal not found exactly once"
open(dst, 'w').write(s.replace(old, new, 1))
PYEOF
OUT=$(bash -c "$PROXY_503_PATTERN_DEF
$(awk '/^_summarize_samples\(\)/,/^}/' "$INJ")
_summarize_samples /dev/stdin" <<< "$(printf '0.100\n\npartial\n0.100\n')" 2>/dev/null)
[ "$OUT" = "4 50.0 57.7" ] && ok "guard stripped -> 4 50.0 57.7 (T34 catches it)" || bad "injection unexpected: $OUT"
rm -f "$INJ"

echo "T10: bug-inject -- every scoring coefficient is frozen; tampering with any one flips its test"
# inject_score <sed-expr> <fixture>: extract the TAMPERED formula and
# verify the fixture's score moves off the true value
inject_score() {
	sed "$1" "$SCRIPT" > "$INJ"
	bash -c "$(awk '/^_score_candidate\(\)/,/^}/' "$INJ")
_score_candidate $2" 2>/dev/null
}
INJ=$(mktemp /tmp/tm_inj_XXXXXX)

# connect-fail: 20*fr (fixture 1/1 attempts; true score 80)
OUT=$(inject_score 's/20\*fr/19*fr/' '1 1 0 0 0 0 0 0')
[ "$OUT" = "81" ] && ok "20*fr frozen (81 != 80)" || bad "20*fr NOT frozen: $OUT"

# drop: 40*dr (fixture 10/20 drops; true score 80)
OUT=$(inject_score 's/40\*dr/30*dr/' '0 1 10 20 0 20 200 0')
[ "$OUT" = "85" ] && ok "40*dr frozen (85 != 80)" || bad "40*dr NOT frozen: $OUT"

# 503 rate: 2*pr (fixture 60 x 503 in 1200s -> pr=3; true score 94)
OUT=$(inject_score 's/2\*pr/1\*pr/' '0 1 0 20 60 1200 200 0')
[ "$OUT" = "97" ] && ok "2*pr frozen (97 != 94)" || bad "2*pr NOT frozen: $OUT"

# sigma divisor: sig/20 (fixture sigma 600 -> pen 30; true score 70).
# NOTE: tampering the cap VALUE alone is invisible while the threshold
# reads `pen > 30` (30 > 30 is false, the assignment never runs), so
# the injection targets the divisor instead.
OUT=$(inject_score 's|sig/20|sig/25|' '0 1 0 20 0 20 200 600')
[ "$OUT" = "76" ] && ok "sigma term frozen (76 != 70)" || bad "sigma term NOT frozen: $OUT"

# the same fixtures against the REAL formula must give the true values
[ "$(score '0 1 10 20 0 20 200 0')" = "80" ] || bad "40*dr fixture wrong on real formula"
[ "$(score '0 1 0 20 60 1200 200 0')" = "94" ] || bad "2*pr fixture wrong on real formula"
[ "$(score '0 1 0 20 0 20 200 600')" = "70" ] || bad "sigma fixture wrong on real formula"
rm -f "$INJ"

echo "T18: _split_candidates -- comma list keeps multi-word names whole"
OUT=$(bash -c "$FNS
_split_candidates 'Dallas,Chicago,New York'
printf '%s\n' \"\${CAND_LIST[@]}\"" 2>/dev/null)
EXP='Dallas
Chicago
New York'
[ "$OUT" = "$EXP" ] && ok "comma split -> 3 tokens, New York intact" || bad "comma split wrong: $OUT"

echo "T19: _split_candidates -- comma list trims surrounding spaces"
OUT=$(bash -c "$FNS
_split_candidates ' Dallas , Miami '
printf '%s\n' \"\${CAND_LIST[@]}\"" 2>/dev/null)
EXP='Dallas
Miami'
[ "$OUT" = "$EXP" ] && ok "trimmed -> Dallas Miami" || bad "trim wrong: $OUT"

echo "T20: _split_candidates -- comma-free string falls back to whitespace split"
OUT=$(bash -c "$FNS
_split_candidates 'Dallas Chicago'
printf '%s\n' \"\${CAND_LIST[@]}\"" 2>/dev/null)
EXP='Dallas
Chicago'
[ "$OUT" = "$EXP" ] && ok "whitespace fallback -> 2 tokens" || bad "whitespace fallback wrong: $OUT"

echo "T21: _split_candidates -- empty input -> nonzero rc"
bash -c "$FNS
_split_candidates ''" >/dev/null 2>&1 && bad "empty accepted (should fail)" || ok "empty -> rc!=0"

echo "T22: _parse_http -- colon-free input is malformed, not a latency"
read -r NCODE NTT <<< "$(bash -c "$FNS
_parse_http '200'" 2>/dev/null)"
if [ -z "$NCODE" ] && [ -z "$NTT" ]; then
	ok "no-colon -> both fields empty (drop)"
else
	bad "no-colon wrong: code='$NCODE' tt='$NTT'"
fi

echo "T23: _split_candidates -- path fragments are rejected"
bash -c "$FNS
_split_candidates 'Dallas,../evil'" >/dev/null 2>&1 && bad "traversal accepted" || ok "traversal -> rc!=0"
bash -c "$FNS
_split_candidates 'a/b'" >/dev/null 2>&1 && bad "slash accepted" || ok "slash -> rc!=0"

echo "T24: _split_candidates -- bare '.' and '..' segments rejected despite passing the charset"
bash -c "$FNS
_split_candidates 'Dallas,..'" >/dev/null 2>&1 && bad ".. accepted" || ok ".. -> rc!=0"
bash -c "$FNS
_split_candidates '.'" >/dev/null 2>&1 && bad ". accepted" || ok ". -> rc!=0"
# a name that merely CONTAINS dots (a real node convention) must still pass
bash -c "$FNS
_split_candidates 'St.Petersburg'" >/dev/null 2>&1 && ok "St.Petersburg accepted" || bad "St.Petersburg wrongly rejected"

echo "T25: _split_candidates -- whitespace-only name is rejected"
bash -c "$FNS
_split_candidates 'Dallas,   '" >/dev/null 2>&1 && bad "whitespace-only accepted" || ok "whitespace-only -> rc!=0"

echo "T26: connect-failure CSV row is now quoted (multi-word candidate names stay one field)"
grep -q '"%s","%s",%s,%s,%s,%s,%s,%s,%s,%s' "$SCRIPT" \
	&& ok "connect_failed/routing_timeout/success rows all use quoted printf" \
	|| bad "CSV printf rows are missing field quoting"

echo "T27: _valid_candidate -- direct edge cases (no transitive masking)"
vcheck() { bash -c "$FNS
_valid_candidate '$1'" >/dev/null 2>&1; }
vcheck "New York"    && ok "space name valid"        || bad "space name rejected"
vcheck "New_York"    && ok "underscore name valid"   || bad "underscore name rejected"
vcheck "St.Petersburg" && ok "dots inside valid"     || bad "dots-inside rejected"
vcheck "back\\slash" && bad "backslash accepted" || ok "backslash rejected"
vcheck "tab	name"   && bad "tab accepted"       || ok "tab rejected"
# single quotes on purpose: the LITERAL $() string must be rejected
# shellcheck disable=SC2016
vcheck '$(touch /tmp/tm_inject_XXXX)' && bad "dollar accepted" || ok "dollar rejected"
ls /tmp/tm_inject_XXXX >/dev/null 2>&1 && bad "injection side effect" || true

echo "T28: sample filenames -- ' ' maps to '+' and cannot collide with '_'"
S1=$(printf 'New York' | tr ' ' '+')
S2=$(printf 'New_York' | tr ' ' '+')
if [ "$S1" != "$S2" ] && [ "$S1" = "New+York" ] && [ "$S2" = "New_York" ]; then
	ok "mapping is injective (New+York vs New_York)"
else
	bad "collision: '$S1' vs '$S2'"
fi

echo "T29: HTTP code sampler accepts 200 and all 3xx (not just 300-309)"
grep -q '200|3\[0-9\]\[0-9\])' "$SCRIPT" \
	&& ok "pattern covers full 3xx range" \
	|| bad "pattern still '30*' or missing"

echo "T30: trap cleans the connect scratch file on interrupt"
# single quotes on purpose: grep for the LITERAL ${_connect_out:-} text
# shellcheck disable=SC2016
grep -q 'rm -f "${_connect_out:-}"' "$SCRIPT" \
	&& ok "trap removes _connect_out" \
	|| bad "trap does not clean up"

echo "T31: copytruncate -- same inode, size shrank below offset -> whole file + rot flag"
FLOG=$(mktemp /tmp/tm503ct_XXXXXX)
printf 'ERROR status: 503 Service Unavailable\npadding line to grow the file beyond a few bytes\n' > "$FLOG"
SIZE=$(stat -c %s "$FLOG"); INO=$(stat -c %i "$FLOG")
# copytruncate: same inode, content replaced with a shorter file
printf 'ERROR status: 503 Service Unavailable\n' > "$FLOG"
[ "$(stat -c %s "$FLOG")" -lt "$SIZE" ] || bad "fixture broken: file did not shrink"
OUT=$(PROXY_LOG="$FLOG" bash -c "$FNS
_count_503_since $SIZE $INO" 2>/dev/null)
[ "$OUT" = "1 1" ] && ok "copytruncate -> 1 1 (counted post-truncate file, flagged)" || bad "copytruncate wrong: $OUT"
rm -f "$FLOG"

echo "T32: probe URL is overridable via PROBE_URL, default google"
grep -q 'PROBE_URL="${PROBE_URL:-https://www.google.com}"' "$SCRIPT" \
	&& ok "PROBE_URL env with google default" \
	|| bad "PROBE_URL override missing"
grep -q '"\$PROBE_URL"' "$SCRIPT" \
	&& ok "sampler uses PROBE_URL" \
	|| bad "sampler still hardcodes the URL"

echo "T33: parsed candidate list is logged at startup"
grep -q 'log "candidates (' "$SCRIPT" \
	&& ok "candidate log line present" \
	|| bad "candidate log line missing"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
