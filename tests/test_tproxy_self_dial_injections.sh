#!/bin/bash
# Defect injection for tests/test_tproxy_self_dial_guard.sh.
#
# Each injection reproduces one way this guard regresses and must turn a named
# assertion red.  Variants are cut from the real script, so moved code breaks
# the injection instead of passing on a stale copy.  Only $TMP is written.
set -u
cd "$(dirname "$0")/.." || exit 1
SRC=surflare_watchdog.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0

run() { WD="$1" bash tests/test_tproxy_self_dial_guard.sh 2>&1; }

base=$(run "$SRC")
case "$base" in
*" 0 failed"*) echo "PASS: baseline green" ;;
*)
	echo "FAIL: baseline not green"
	printf '%s\n' "$base"
	fail=1
	;;
esac

# variant <name> <old> <new> -> writes $TMP/<name>.sh, aborts if old is absent
variant() {
	local name="$1" old="$2" new="$3"
	# @key reads the pair from tests/fixtures/inject/<key>.old|.new, so an
	# anchor containing quotes or dollars never has to survive shell quoting.
	case "$old" in
	@*)
		old=$(cat "tests/fixtures/inject/${old#@}.old")
		new=$(cat "tests/fixtures/inject/${new#@}.new")
		;;
	esac
	/usr/bin/python3 - "$SRC" "$TMP/$name.sh" "$old" "$new" <<'PY' 
import io, sys
src, dst, old, new = sys.argv[1:5]
text = io.open(src, encoding="utf-8").read()
if text.count(old) != 1:
    sys.stderr.write("anchor appears %d times: %r\n" % (text.count(old), old[:70]))
    raise SystemExit(1)
io.open(dst, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
	# A stale anchor must not abort the run: report it and keep going, or the
	# injections after it silently never execute.
	if [ ! -s "$TMP/$name.sh" ]; then
		echo "FAIL (inject): $name -- anchor lost, injection not applied"
		fail=1
		return 1
	fi
}

expect_red() {
	local label="$1" file="$2" needle="$3" out
	out=$(run "$file")
	if printf '%s' "$out" | grep -q "FAIL: .*$needle"; then
		echo "PASS (inject): $label"
	else
		echo "FAIL (inject): $label -- assertion stayed green"
		printf '%s\n' "$out" | sed 's/^/    /'
		fail=1
	fi
}

# --- the insert never happens -----------------------------------------
variant j1 '	if err=$(nft insert rule' '	if err=$(false && nft insert rule'
expect_red "insert disabled" "$TMP/j1.sh" "across three ticks"

# --- the dedup key drifts from the tag the rule carries ----------------
variant j2 '	our_line=$(printf '"'"'%s\n'"'"' "$listing" | grep -F "comment \"$_SELF_DIAL_TAG\"" \' '	our_line=$(printf '"'"'%s\n'"'"' "$listing" | grep -F "comment \"${_SELF_DIAL_TAG}-v2\"" \'
expect_red "dedup key drift" "$TMP/j2.sh" "across three ticks"

# --- the dedup check is dropped altogether -----------------------------
variant j3 '	if [ -n "$our_handle" ]; then' '	if false; then'
expect_red "dedup check removed" "$TMP/j3.sh" "across three ticks"

# --- the rule loses its comment (dedup and attribution both go) --------
variant j4 'counter drop comment "$_SELF_DIAL_TAG"' 'counter drop'
expect_red "rule loses the comment tag" "$TMP/j4.sh" "no comment tag"

# --- the verdict is softened to accept ---------------------------------
variant j5 'counter drop comment "$_SELF_DIAL_TAG"' 'counter accept comment "$_SELF_DIAL_TAG"'
expect_red "verdict flipped to accept" "$TMP/j5.sh" "does not drop"

# --- the dedup stops checking the verdict ------------------------------
variant j6 "| grep ' drop' | head -1)" "| head -1)"
expect_red "dedup ignores the verdict" "$TMP/j6.sh" "softened copy survived"

# --- the dedup stops checking the port ---------------------------------
variant j7 @j7 @j7
expect_red "dedup ignores the port" "$TMP/j7.sh" "wrong-port copy survived"

# --- the head-position check disappears -------------------------------
variant j8 '[ "$our_handle" = "$head_handle" ]' 'true'
expect_red "head-position check removed" "$TMP/j8.sh" "left below an accept"

# --- stale tagged copies are no longer removed ------------------------
variant j9 '_self_dial_delete_tagged "$stale"' ':'
expect_red "stale copies not removed" "$TMP/j9.sh" "survived"

# --- the note stops being type-checked (a FIFO would block) -----------
variant j10 '[ -f "$_SELF_DIAL_NOTE" ] && [ ! -L "$_SELF_DIAL_NOTE" ] || return 0' ':'
expect_red "note type check removed" "$TMP/j10.sh" "hung on a FIFO note"

# Not injected: whether the note carries the process id only shows up across
# two processes, and this suite drives one.  The daemon is single-instance
# (flock in _ensure_singleton), so the pid suffix is belt-and-braces against a
# stale /run note after an unclean stop.

# --- an empty nft stderr stops being reported -------------------------
variant j12 '[ -z "$first" ] && first="(nft failed with no output)"' ':'
expect_red "empty stderr sentinel removed" "$TMP/j12.sh" "empty nft stderr reported"

# --- the report state stops being read back ---------------------------
variant j13 '	[ "$1" = "$(_self_dial_note_read)" ] && return 0' '	:'
expect_red "report state not read back" "$TMP/j13.sh" "subshell calls reported"

# --- a lifecycle call site disappears (tick) --------------------------
variant j14 '		_remove_dns_fallback
		_patch_surflare_icmp_lan
		_patch_surflare_self_dial_guard' '		_remove_dns_fallback
		_patch_surflare_icmp_lan'
expect_red "tick call site removed" "$TMP/j14.sh" "not paired"

# --- the proxy-start call disappears ----------------------------------
variant j15 '			_raise_proxy_fd_limit
			_patch_surflare_self_dial_guard' '			_raise_proxy_fd_limit'
expect_red "proxy-start call removed" "$TMP/j15.sh" "_start_surflare_proxy rebuilds"

# --- the post-connect call disappears (legacy branch unguarded) -------
variant j16 '		_patch_surflare_self_dial_guard
		# Load CN output bypass' '		# Load CN output bypass'
expect_red "post-connect call removed" "$TMP/j16.sh" "not ahead of the settle split"

# --- the post-connect call is commented out ---------------------------
variant j17 '		_patch_surflare_self_dial_guard
		# Load CN output bypass' '		# _patch_surflare_self_dial_guard
		# Load CN output bypass'
expect_red "post-connect call commented out" "$TMP/j17.sh" "not ahead of the settle split"

# --- the transit-probe call disappears --------------------------------
variant j18 '		_patch_surflare_self_dial_guard
		sleep "$TRANSIT_PROBE_SETTLE"' '		sleep "$TRANSIT_PROBE_SETTLE"'
expect_red "probe call removed" "$TMP/j18.sh" "probe_best_transit rebuilds"

# --- the unconditional loop call disappears ---------------------------
variant j19 '	_patch_surflare_self_dial_guard
	# Diagnostic mode: pause without tearing down protections.' '	# Diagnostic mode: pause without tearing down protections.'
expect_red "loop-top call removed" "$TMP/j19.sh" "behind the health gate"

# --- the missing-chain warning loses its transition gating ------------
variant j20 '			_self_dial_report "no-chain" "output chain missing, not applied"' '			log "WARN: tproxy self-dial guard: output chain missing, not applied"'
expect_red "missing-chain warning not transition-gated" "$TMP/j20.sh" "no chain: reported"

# --- an unreadable chain is reported as a missing one -----------------
variant j21 '		_self_dial_report "chain unreadable: $err" "chain unreadable: $err"' '		_self_dial_report "no-chain" "output chain missing, not applied"'
expect_red "unreadable chain misreported as missing" "$TMP/j21.sh" "unreadable"

# --- nft's failure reason is discarded again --------------------------
variant j22 '	_self_dial_report "$first" "insert failed: $first"' '	_self_dial_report "$first" "insert failed"'
expect_red "nft stderr dropped from the warning" "$TMP/j22.sh" "nft's stderr"

# --- the listing loses -a, so no handle is ever parsed -----------------
variant j23 'if ! listing=$(nft -a list chain inet surflare output 2>/dev/null); then' 'if ! listing=$(nft list chain inet surflare output 2>/dev/null); then'
expect_red "listing loses -a" "$TMP/j23.sh" "across three ticks"

# --- the chain's own handle is taken for the first rule's ---------------
variant j24 "grep -v '{ # handle'" "grep -v '^chain '"
expect_red "chain header taken as first rule" "$TMP/j24.sh" "churned an anchored rule"

# --- the delete stops verifying the handle it is about to remove -------
variant j25 @j25 @j25
expect_red "delete stops verifying the handle" "$TMP/j25.sh" "rebuilt under it"

# --- the whole-table probe comes back ----------------------------------
variant j26 @j26 @j26
expect_red "whole-table probe reinstated" "$TMP/j26.sh" "whole-table listing"

[ "$fail" -eq 0 ] && echo "ALL INJECTIONS DETECTED" || { echo "INJECTION GAPS"; exit 1; }