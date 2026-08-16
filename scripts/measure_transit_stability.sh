#!/bin/bash
# Transit stability measurement -- find a relay whose STABILITY beats
# its latency (latency is the tiebreak, not the goal).
#
# Background: with TRANSIT=auto the proxy's urltest picks relays by
# RTT with 40ms tolerance, so a 50ms relay with a 10% 503 rate beats
# a 200ms stable one. This script measures every transit candidate
# under a fixed exit and scores them by a PRE-REGISTERED formula
# (below -- frozen before any data existed; change the formula only
# in a commit that says why).
#
# Runs on the N100 router. The watchdog must be stopped (its
# reconnect/rotation would fight the measurement); the script refuses
# to run otherwise. Each candidate gets one connect; each connect
# tears down and reconnects the tunnel, so LAN traffic is interrupted
# ~15-30s per switch. Results and a copy of this script are persisted
# side by side (S2: the artifact host keeps script + record together).
#
# Pre-registered scoring:
#   score = 100
#         - 20 * connect_fail_rate          (fails / attempts)
#         - 40 * drop_rate                  (failed samples / samples)
#         -  2 * 503_per_min                (proxy 503s per minute)
#         - min(30, sigma_ms / 20)          (RTT stddev penalty)
#   Latency (mean time_total) breaks ties only within 3 points.
#
# Usage:
#   scripts/measure_transit_stability.sh [--candidates "A,B C,D"] \
#       [--exit CITY] [--window 1200] [--interval 60] \
#       [--out /root/transit-measure] [--null-run]
# Env vars (CANDIDATES, EXIT_CITY, WINDOW, INTERVAL, OUT_DIR,
# NULL_RUN) seed the same defaults; CLI flags win.

set -u
set -f   # candidate names must never glob-expand
# Comma-separated so multi-word node names ("New York") stay one
# token; a comma-free string falls back to whitespace splitting
# (single-word names only).
CANDIDATES="${CANDIDATES:-Dallas,Chicago,Atlanta,Miami,New York}"
EXIT_CITY="${EXIT_CITY:-}"
WINDOW="${WINDOW:-1200}"          # seconds per candidate
INTERVAL="${INTERVAL:-60}"        # seconds between samples
OUT_DIR="${OUT_DIR:-/root/transit-measure}"
NULL_RUN="${NULL_RUN:-0}"
MODE="rule"                        # N100 production runs rule mode
ROUTE_READY_TIMEOUT=20
SETTLE=15

PROXY_LOG=/var/log/surflare/surflare-proxy.log
# Probe target for every sample. Google is the default canary because the
# measurement is about the FOREIGN path through the tunnel; override when
# it is unreachable from the vantage point (the score formula does not
# care which stable host answers).
PROBE_URL="${PROBE_URL:-https://www.google.com}"
# anchor on the log's own wording: a bare "503" substring would also
# match unrelated numbers (timestamps, byte counts, ports). Kept as a
# variable (not inlined at each grep call site) so a proxy log format
# change is a one-line fix instead of a silent all-zeros regression.
PROXY_503_PATTERN='status: 503 '

log() { echo "[$(date +%H:%M:%S)] $*"; }

die() { log "FATAL: $*"; exit 1; }

# the sampler feeds PROBE_URL to curl verbatim; confine it to https so
# an operator typo (or a borrowed environment) cannot turn the probe
# into a file:// read or a plain-http leak
case "$PROBE_URL" in
	https://*) ;;
	*) die "PROBE_URL must be an https:// URL: $PROBE_URL" ;;
esac

while [ "$#" -gt 0 ]; do
	case "$1" in
		--candidates) CANDIDATES="${2:-}"; shift 2 ;;
		--exit)       EXIT_CITY="${2:-}";   shift 2 ;;
		--window)     WINDOW="${2:-}";      shift 2 ;;
		--interval)   INTERVAL="${2:-}";    shift 2 ;;
		--out)        OUT_DIR="${2:-}";     shift 2 ;;
		--null-run)   NULL_RUN=1;           shift 1 ;;
		*) die "unknown flag: $1" ;;
	esac
done

# --- pre-registered scoring (pure; tested) ---------------------------
# Args: fails attempts drops samples s503 window_seconds mean_ms sigma_ms
# Prints integer score, clamped at 0 (extreme inputs must not go
# negative and distort ranking).
_score_candidate() {
	# mean arrives positionally for the caller contract but is not part
	# of the score (latency is a tiebreak outside this function)
	# shellcheck disable=SC2034  # mean intentionally unused here
	local fails=$1 attempts=$2 drops=$3 samples=$4 s503=$5 wsec=$6 mean=$7 sigma=$8
	awk -v f="$fails" -v a="$attempts" -v d="$drops" -v s="$samples" \
	    -v c="$s503" -v w="$wsec" -v sig="$sigma" 'BEGIN {
		fr = (a > 0) ? f/a : 1
		# no samples = no drop evidence; the connect-fail term already
		# prices a dead path
		dr = (s > 0) ? d/s : 0
		pr = (w > 0) ? c/(w/60) : c
		pen = sig/20; if (pen > 30) pen = 30
		score = 100 - 20*fr - 40*dr - 2*pr - pen
		if (score < 0) score = 0
		printf "%d", score
	}'
}

# _summarize_samples <file>: prints "ok_count mean_ms sigma_ms". The
# file holds curl's time_total in SECONDS (one sample per line); this
# converts to milliseconds so the output actually matches its own name
# and the scoring formula's sig/20 penalty operates on the right scale
# -- 600ms of jitter must read as sigma=600, not 0.6 (which would
# round the penalty to zero and make the sigma term dead code).
# Mean and sigma share the SUCCESSFUL-sample population; dividing by
# total samples would dilute the mean under drops and let a drop-heavy
# transit win the latency tiebreak.
_summarize_samples() {
	# skip anything that is not a plain non-negative number: an empty or
	# truncated line would otherwise parse as v=0 and silently drag the
	# mean/sigma toward zero
	awk '/^[0-9]+(\.[0-9]+)?$/ {v=$1*1000; s+=v; s2+=v*v; n++} END {
		if (n == 0) { printf "0 0 0"; exit }
		mean = s/n
		sig = (n > 1) ? sqrt((s2-s*s/n)/(n-1)) : 0
		printf "%d %.1f %.1f", n, mean, sig
	}' "$1" 2>/dev/null
}

# --- helpers ----------------------------------------------------------
# _split_candidates <string>: fills the CAND_LIST array. Comma is the
# separator when present (multi-word node names survive verbatim);
# otherwise the string splits on whitespace. Names are validated
# against [A-Za-z0-9 ._-] -- candidates end up in filenames, so '/'
# must never pass; a bare '.' or '..' segment (which the charset alone
# would let through) is rejected separately; whitespace-only names
# would produce a degenerate samples_.txt and are rejected too.
# Empty/invalid -> return 1.
# Validation runs through grep -E, NOT a case pattern: an unquoted
# bracket class inside a case pattern word-splits at parse time, and a
# backslash-escaped space inside the class silently ADDS a literal
# backslash as a class member.
_valid_candidate() {
	printf '%s\n' "$1" | grep -qE '^[A-Za-z0-9 ._-]+$' || return 1
	case "$1" in
		.|..) return 1 ;;
	esac
	# reject whitespace-only (trims to empty)
	case "$(printf '%s' "$1" | tr -d ' ')" in
		'') return 1 ;;
	esac
	return 0
}

_split_candidates() {
	CAND_LIST=()
	local _tok
	if printf '%s\n' "$1" | grep -q ','; then
		while IFS= read -r _tok; do
			if ! _valid_candidate "$_tok"; then
				echo "invalid candidate name: '$_tok'" >&2
				return 1
			fi
			CAND_LIST+=("$_tok")
		done < <(printf '%s\n' "$1" | awk -F',' \
			'{for (i = 1; i <= NF; i++) {gsub(/^[ \t]+|[ \t]+$/, "", $i); print $i}}')
	else
		# word-split via read -d ' ' (space is the record separator --
		# a plain `read -r _tok` reads a full LINE and would stuff all
		# remaining fields into _tok). The trailing space appended by
		# printf makes the last word terminate with a record separator
		# instead of EOF, which read would otherwise drop silently.
		# Tabs are normalized to spaces first so tab-separated input
		# splits the same way instead of dying on the validator's tab
		# rejection.
		while IFS= read -r -d ' ' _tok; do
			[ -n "$_tok" ] || continue
			if ! _valid_candidate "$_tok"; then
				echo "invalid candidate name: '$_tok'" >&2
				return 1
			fi
			CAND_LIST+=("$_tok")
		done < <(printf '%s ' "$(printf '%s' "$1" | tr '\t' ' ')")
	fi
	[ ${#CAND_LIST[@]} -gt 0 ]
}

# Read stdout of curl as "code:time_total:time_starttransfer"; prints
# "200 1.234". Empty or colon-free curl output prints a whitespace-only
# line, which `read -r code tt` parses as BOTH fields empty -- the
# sampler's case-default classifies that as a drop (a colon-free "200"
# is malformed, not a 200-second latency).
_parse_http() {
	local _line=$1 _code _tt
	case "$_line" in
		*:*) ;;
		*) printf ' \n'; return ;;
	esac
	_code=${_line%%:*}
	_tt=${_line#*:}
	printf '%s %s\n' "$_code" "${_tt%:*}"
}

# 503 count in the proxy log since byte OFFSET, rotation-aware:
# same inode -> count from offset; different inode -> count whole
# file and report rotation. Prints "count rotation_flag".
# copytruncate is the same-inode failure mode: the file SHRINKS below
# the captured offset, and tail -c +offset would silently read nothing.
# Detect the shrink and fall back to counting the whole (post-truncate)
# file with the rotation flag set -- the count loses the pre-truncate
# 503s, but a flagged imperfection beats a silent zero.
# Known limitation: a SECOND rotation inside the same window loses the
# intermediate file's 503s too (only the live file is readable by
# name).  That is why a rotation sets the flag: the CSV notes column
# marks that candidate's 503 column as a lower bound, and the scoring
# treats flagged rows accordingly.  Rotation mid-window is a
# logrotate-during-measurement operational error, not silent data
# corruption.
_count_503_since() {
	local _offset=$1 _ino=$2 _new_ino _new_size _cnt=0 _rot=0
	[ -f "$PROXY_LOG" ] || { echo "0 0"; return; }
	read -r _new_ino _new_size <<< "$(stat -c '%i %s' "$PROXY_LOG" 2>/dev/null || echo '0 0')"
	if [ "$_new_ino" = "$_ino" ]; then
		# same inode: count from the captured offset; offset=0 just
		# means the log was empty at capture -- count the whole file
		# WITHOUT flagging rotation (the inode is the rotation signal)
		if [ "$_offset" -gt 0 ] && [ "${_new_size:-0}" -ge "$_offset" ]; then
			_cnt=$(tail -c +"$((_offset + 1))" "$PROXY_LOG" 2>/dev/null | grep -c "$PROXY_503_PATTERN")
			# TOCTOU: the log could be copytruncated BETWEEN the stat
			# above and the tail.  Re-check the size after the read; a
			# shrink means the count just silently missed entries, so
			# fall through to the whole-file path instead.
			_post_size=$(stat -c %s "$PROXY_LOG" 2>/dev/null || echo 0)
			if [ "${_post_size:-0}" -lt "$_offset" ]; then
				_cnt=$(grep -c "$PROXY_503_PATTERN" "$PROXY_LOG" 2>/dev/null)
				_rot=1
			fi
		elif [ "$_offset" -gt 0 ]; then
			# same inode but shrank: copytruncate
			_cnt=$(grep -c "$PROXY_503_PATTERN" "$PROXY_LOG" 2>/dev/null)
			_rot=1
		else
			_cnt=$(grep -c "$PROXY_503_PATTERN" "$PROXY_LOG" 2>/dev/null)
		fi
	else
		_cnt=$(grep -c "$PROXY_503_PATTERN" "$PROXY_LOG" 2>/dev/null)
		_rot=1
	fi
	printf '%s %s\n' "${_cnt:-0}" "$_rot"
}

# --- orchestration ----------------------------------------------------
# interrupt cleanup: disconnect the tunnel and remove this run's connect
# scratch file. Sample files under OUT_DIR are kept on purpose -- they
# are diagnostic artifacts, and the CSV + persisted script copy beside
# them (S2) stay the run's reproducible record.
trap 'log "interrupted, disconnecting"; surflare disconnect >/dev/null 2>&1; rm -f "${_connect_out:-}" 2>/dev/null; exit 130' INT TERM

[ "$(id -u)" -eq 0 ] || die "must run as root"
# a live watchdog fights the measurement regardless of marker state --
# a stale marker must not let a measurement run against a running one
if pgrep -f "surflare_watchdog.sh" >/dev/null 2>&1; then
	die "watchdog is running; stop it first (/etc/init.d/surflare-watchdog stop)"
fi
command -v surflare >/dev/null 2>&1 || die "surflare CLI not found"
command -v curl >/dev/null 2>&1 || die "curl not found (every sample would silently read as a drop)"
# sanity check the 503 anchor against the live log format -- a proxy
# log rewording would otherwise silently zero every 503 count with no
# diagnostic. Non-fatal: an empty log or a genuinely 503-free run also
# produces zero matches, so this can only warn, never gate.
if [ -f "$PROXY_LOG" ] && [ -s "$PROXY_LOG" ] && ! grep -q "$PROXY_503_PATTERN" "$PROXY_LOG" 2>/dev/null; then
	log "WARN: proxy log has no lines matching '${PROXY_503_PATTERN}' -- either genuinely 503-free, or the log format changed and PROXY_503_PATTERN needs updating"
fi
case "$WINDOW" in ''|*[!0-9]*) die "--window must be a positive integer: $WINDOW" ;; esac
case "$INTERVAL" in ''|*[!0-9]*) die "--interval must be a positive integer: $INTERVAL" ;; esac
[ "$WINDOW" -gt 0 ] || die "--window must be > 0 (0 skips sampling entirely)"
[ "$INTERVAL" -gt 0 ] || die "--interval must be > 0 (0 busy-loops)"
mkdir -p "$OUT_DIR"
# samples and CSVs land here; the script runs as root, so keep the
# directory root-only even when the operator points OUT_DIR somewhere
# world-writable
chmod 700 "$OUT_DIR"

[ -z "$EXIT_CITY" ] && EXIT_CITY=$(head -1 /var/tmp/surflare_rotation 2>/dev/null | cut -f1)
[ -z "$EXIT_CITY" ] && EXIT_CITY="Dallas"

# Null run: one candidate, 2 samples, pipeline check only. Results are
# marked null and never compared against the pre-registered scoring.
if [ "$NULL_RUN" -eq 1 ]; then
	WINDOW=$((INTERVAL * 2))
fi

_split_candidates "$CANDIDATES" || die "no usable candidates"
# Echo the parsed list: with a comma-free string the whitespace fallback
# splits on spaces, so a multi-word name silently becomes two candidates
# (by design -- single-word names only without commas).  Make the parse
# visible so a mis-split is caught by the operator, not by the data.
log "candidates (${#CAND_LIST[@]}): ${CAND_LIST[*]}"
if [ "$NULL_RUN" -eq 1 ]; then
	CAND_LIST=("${CAND_LIST[0]}")
	log "NULL RUN: exit=${EXIT_CITY} candidate=${CAND_LIST[0]} window=${WINDOW}s (pipeline check)"
fi

OUT_CSV="$OUT_DIR/transit_measure_$(date +%Y%m%d_%H%M%S).csv"
cp "$0" "$OUT_DIR/measure_transit_stability.sh.$(date +%Y%m%d_%H%M%S)" 2>/dev/null
printf 'candidate,exit,attempts,fails,drop_rate,503_per_min,mean_ms,sigma_ms,score,notes\n' > "$OUT_CSV"

for cand in "${CAND_LIST[@]}"; do
	log "=== measuring transit=${cand} exit=${EXIT_CITY} ==="
	attempts=0; fails=0; drops=0; samples=0; s503=0; rotations=0

	# connect (single attempt; a second attempt would churn the LAN
	# twice -- the fail rate penalty already prices failures in)
	_connect_out=$(mktemp /tmp/tm_connect_XXXXXX) \
		|| die "mktemp failed (is /tmp writable?)"
	if ! timeout 60 surflare connect --node "$EXIT_CITY" --mode "$MODE" \
	     --transit "$cand" --daemon >"$_connect_out" 2>&1; then
		log "connect failed for ${cand}: $(tail -3 "$_connect_out" | tr '\n' ' ')"
		rm -f "$_connect_out"
		fails=1
		attempts=1
		surflare disconnect >/dev/null 2>&1
		printf '"%s","%s",%s,%s,%s,%s,%s,%s,%s,%s\n' \
			"$cand" "$EXIT_CITY" 1 1 "" "" "" "" "" "connect_failed" | tee -a "$OUT_CSV"
		continue
	fi
	rm -f "$_connect_out"
	attempts=1

	# wait for routing
	_ready=0; _t=0
	while [ "$_t" -lt "$ROUTE_READY_TIMEOUT" ]; do
		pgrep -f surflare-proxy >/dev/null 2>&1 && \
		nft list table inet surflare >/dev/null 2>&1 && \
		ip rule show 2>/dev/null | grep -q 'fwmark 0x1 lookup 100' && { _ready=1; break; }
		sleep 1; _t=$((_t + 1))
	done
	if [ "$_ready" -ne 1 ]; then
		log "routing not ready for ${cand}, skipping"
		printf '"%s","%s",%s,%s,%s,%s,%s,%s,%s,%s\n' \
			"$cand" "$EXIT_CITY" 1 0 "" "" "" "" "" "routing_timeout" | tee -a "$OUT_CSV"
		surflare disconnect >/dev/null 2>&1
		continue
	fi
	sleep "$SETTLE"

	# one stat call: two separate ones could straddle a rotation and
	# pair the old inode with the new (smaller) size
	read -r _log_ino _log_size <<< "$(stat -c '%i %s' "$PROXY_LOG" 2>/dev/null || echo '0 0')"
	_start=$(date +%s)
	# spaces in node names ("New York") must not leak into filenames.
	# '+' not '_': '_' is a legal candidate-name char, and mapping
	# both "New York" and "New_York" to samples_New_York.txt would
	# silently overwrite one candidate's samples with the other's.
	_sfile="$OUT_DIR/samples_$(printf '%s' "$cand" | tr ' ' '+').txt"
	: > "$_sfile"

	while [ $(( $(date +%s) - _start )) -lt "$WINDOW" ]; do
		_line=$(curl -s --connect-timeout 4 --max-time 10 \
			-o /dev/null -w '%{http_code}:%{time_total}:%{time_starttransfer}' \
			"$PROBE_URL" 2>/dev/null)
		read -r _code _tt <<< "$(_parse_http "$_line")"
		samples=$((samples + 1))
		case "$_code" in
			200|3[0-9][0-9]) printf '%s\n' "$_tt" >> "$_sfile" ;;
			*) drops=$((drops + 1)) ;;
		esac
		sleep "$INTERVAL"
	done

	read -r _d503 _rot <<< "$(_count_503_since "$_log_size" "$_log_ino")"
	s503=$((s503 + ${_d503:-0}))
	[ "${_rot:-0}" -eq 1 ] && rotations=1

	read -r _ok _mean _sigma <<< "$(_summarize_samples "$_sfile")"

	score=$(_score_candidate "$fails" "$attempts" "$drops" "$samples" "$s503" "$WINDOW" "$_mean" "$_sigma")
	_notes=""
	[ "$rotations" -eq 1 ] && _notes="log_rotated"
	[ "$NULL_RUN" -eq 1 ] && _notes="${_notes:+$_notes }null_run"

	# window=0 or a routing-timeout skip leaves samples at 0; the score
	# rationale ("no samples = no drop evidence") applies to the CSV
	# column too, so its zero-sample default is 0, not 1
	printf '"%s","%s",%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$cand" "$EXIT_CITY" "$attempts" "$fails" \
		"$(awk -v d="$drops" -v s="$samples" 'BEGIN{printf "%.3f", (s > 0) ? d/s : 0}')" \
		"$(awk -v c="$s503" -v w="$WINDOW" 'BEGIN{printf "%.2f", (w > 0) ? c/(w/60) : c}')" \
		"$_mean" "$_sigma" "$score" "$_notes" | tee -a "$OUT_CSV"

	log "=== ${cand}: score=${score} (fails=${fails}/${attempts} drops=${drops}/${samples} 503=${s503} mean=${_mean}ms sigma=${_sigma}ms) ==="
	surflare disconnect >/dev/null 2>&1
	sleep 5
done

log "done. results: $OUT_CSV"
