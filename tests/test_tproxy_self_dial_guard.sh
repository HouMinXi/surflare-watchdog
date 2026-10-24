#!/bin/bash
# Host-side guard: the proxy must never be able to dial its own tproxy
# listener.  surflare's generated route sends ip_is_private traffic out
# `direct` before anything else, so a connection arriving at the inbound
# with a loopback destination is re-dialled to the same listener and the
# loop sustains itself (measured on live: 9,759 new connections/second, one
# core pinned by an otherwise idle proxy).
#
# The implementation is extracted from the production script, never copied,
# and driven against a stateful stub whose insert path renders rules the way
# nft does -- a bare `counter` becomes `counter packets N bytes N`, which is
# exactly why the dedup key is the rule's comment and not its text.
set -u
cd "$(dirname "$0")/.." || exit 1
WD="${WD:-surflare_watchdog.sh}"
FUNC=_patch_surflare_self_dial_guard

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- extract the tag, the note path and the function from production ----
# index() instead of a regex: the parenthesis/brace pattern needs four
# escaping layers here, and getting one wrong silently turns this into "read
# the whole file".  The line-count guard below catches that case loudly.
awk -v fn="$FUNC" '
	/^_SELF_DIAL_TAG=/ { keep = 1 }
	keep && index($0, fn "() {") == 1 { inside = 1 }
	keep { print }
	inside && /^}$/ { exit }
' "$WD" > "$TMP/funcs.sh"

if [ -s "$TMP/funcs.sh" ] && grep -q "^$FUNC() {" "$TMP/funcs.sh"; then
	echo "extracted $FUNC from $WD ($(wc -l < "$TMP/funcs.sh") lines)"
else
	echo "FAIL: could not extract $FUNC from $WD"
	echo "RESULT: 0 passed, 1 failed"
	exit 1
fi
# The bound catches the one failure that looks like success: an anchor that no
# longer matches prints the rest of the file, and the header check below still
# passes because the header is in there.  Room for the function to grow, not a
# nudge to trim it.
if [ "$(wc -l < "$TMP/funcs.sh")" -gt 200 ]; then
	echo "FAIL: extraction ran past the function: the start anchor moved, or the function outgrew the bound"
	echo "RESULT: 0 passed, 1 failed"
	exit 1
fi

# --- stateful stub ------------------------------------------------------
# nft runs inside a command substitution in production (to capture stderr),
# so the stub must keep its state on disk -- shell variables set inside a
# subshell would never come back.
NFT_TABLE=1
NFT_INSERT_RC=0
NFT_INSERT_ERR=""
RULES_FILE="$TMP/rules.txt"
ARGV_FILE="$TMP/argv.txt"
: > "$RULES_FILE"
: > "$ARGV_FILE"
LOGS=""

render_insert() {
	# nft prints a bare counter with its packet/byte counts inline, quotes
	# string values (oifname, comment) and appends a handle.  Modelling the
	# quoting matters: the dedup greps for the quoted form.
	local out="" tok prev="" handle
	for tok in "$@"; do
		case "$prev" in
		oifname|comment) out="$out \"$tok\"" ;;
		*)
			if [ "$tok" = "counter" ]; then
				out="$out counter packets 0 bytes 0"
			else
				out="$out $tok"
			fi
			;;
		esac
		prev="$tok"
	done
	handle=$(( $(sed -n 's/.*# handle \([0-9]*\)$/\1/p' "$RULES_FILE" 2>/dev/null | sort -n | tail -1 || echo 9) + 1 ))
	echo "${out# } # handle $handle"
}

nft() {
	printf '%s\n' "$*" >> "$ARGV_FILE"
	case "$*" in
	*"list table inet surflare"*)
		[ "$NFT_TABLE" -eq 1 ] || return 1
		echo "table inet surflare {"
		return 0
		;;
	*"list chain inet surflare output"*)
		if [ "${NFT_TABLE:-1}" -eq 0 ]; then
			echo "Error: No such file or directory" >&2
			return 1
		elif [ "${NFT_CHAIN:-1}" -eq 0 ]; then
			echo "Error: No such file or directory" >&2
			return 1
		elif [ "${NFT_CHAIN:-1}" -eq 2 ]; then
			echo "Error: Device or resource busy" >&2
			return 1
		fi
		# Real nft prints the chain's own handle on the header line and only
		# shows rule handles when -a is passed; a stub that always prints them
		# hides every defect that lives in the handle parsing.
		# A rebuilt table hands the same handle numbers out again.  After
		# NFT_SWAP_AFTER listings the stub serves the rebuilt chain, so a delete
		# that trusts an older listing can be caught.
		if [ -n "${NFT_SWAP_AFTER:-}" ] && [ -f "$RULES_FILE.gen2" ]; then
			seen=$(cat "$RULES_FILE.lists" 2>/dev/null || echo 0)
			seen=$(( seen + 1 ))
			echo "$seen" > "$RULES_FILE.lists"
			if [ "$seen" -gt "$NFT_SWAP_AFTER" ]; then
				printf '\tchain output { # handle 1\n'
				cat "$RULES_FILE.gen2"
				return 0
			fi
		fi
		printf '\tchain output { # handle 1\n'
		case "$*" in
		*"-a list chain"*) cat "$RULES_FILE" ;;
		*) sed 's/ # handle [0-9]*$//' "$RULES_FILE" ;;
		esac
		return 0
		;;
	*"insert rule"*)
		if [ "$NFT_INSERT_RC" -ne 0 ]; then
			echo "$NFT_INSERT_ERR" >&2
			return "$NFT_INSERT_RC"
		fi
		# nft's insert without a position prepends; handles keep growing.
		render_insert "$@" > "$RULES_FILE.new"
		cat "$RULES_FILE" >> "$RULES_FILE.new"
		mv "$RULES_FILE.new" "$RULES_FILE"
		return 0
		;;
	*"delete rule"*)
		h=$(printf '%s' "$*" | sed -n 's/.*handle \([0-9]*\).*/\1/p')
		if [ -n "$h" ]; then
			grep -v "# handle $h\$" "$RULES_FILE" > "$RULES_FILE.new" 2>/dev/null || :
			mv "$RULES_FILE.new" "$RULES_FILE"
		fi
		return 0
		;;
	esac
	return 0
}

log() { LOGS="${LOGS}$*"$'\n'; printf '%s\n' "$*" >> "$TMP/log.txt"; }

# Keep the guard's state file inside the sandbox: it writes to /run in
# production and the tests run unprivileged.
_SELF_DIAL_NOTE="$TMP/guard.note"

# shellcheck source=/dev/null
. "$TMP/funcs.sh"

reset_rules() { : > "$RULES_FILE"; : > "$ARGV_FILE"; : > "$TMP/log.txt"; LOGS=""; rm -f "${_SELF_DIAL_NOTE:-}" "${RULES_FILE}.gen2" "${RULES_FILE}.lists"; }
rule_count() { awk 'END{print NR}' "$RULES_FILE"; }

# --- case 1: no table (proxy down) -> nothing to do ---------------------
NFT_TABLE=0
reset_rules
$FUNC
if grep -q 'insert rule' "$ARGV_FILE"; then
	bad "no table: tried to insert into a table that does not exist"
else
	ok "no table: does not insert"
fi
NFT_TABLE=1

# --- case 2: repeated calls stay at one rule (the tick calls this) ------
reset_rules
$FUNC
first=$(rule_count)
$FUNC
$FUNC
third=$(rule_count)
if [ "$first" -eq 1 ] && [ "$third" -eq 1 ]; then
	ok "three ticks leave exactly one rule (dedup survives nft's counter rendering)"
else
	bad "rule count went $first -> $third across three ticks"
fi
inserts=$(grep -c 'insert rule' "$ARGV_FILE")
if [ "$inserts" -eq 1 ]; then
	ok "only the first tick inserts"
else
	bad "inserted $inserts times across three ticks"
fi

# --- case 3: the rule is attributable and matches the incident ----------
if grep -q 'oifname "lo" tcp dport 10800' "$RULES_FILE"; then
	ok "rule targets loopback dials to the tproxy port"
else
	bad "rule selector is wrong: $(cat "$RULES_FILE")"
fi
if grep -qF 'comment "watchdog-tproxy-self-dial"' "$RULES_FILE"; then
	ok "rule carries the dedup comment"
else
	bad "rule has no comment tag"
fi
# The verdict is the whole point: without it the rule is decoration.
if grep -q ' drop' "$RULES_FILE"; then
	ok "rule verdict is drop"
else
	bad "rule does not drop: $(cat "$RULES_FILE")"
fi

# --- case 4: a same-selector rule without our tag does not count --------
reset_rules
echo 'oifname "lo" tcp dport 10800 counter packets 0 bytes 0 drop # handle 3' >> "$RULES_FILE"
$FUNC
if [ "$(rule_count)" -eq 2 ]; then
	ok "a foreign rule on the same selector does not satisfy the dedup"
else
	bad "foreign rule was treated as ours"
fi

# --- case 5: insert failure surfaces nft's reason -----------------------
reset_rules
NFT_INSERT_RC=1
NFT_INSERT_ERR="Error: Could not process rule: No such file or directory"
$FUNC
if printf '%s' "$LOGS" | grep -q 'WARN: tproxy self-dial guard: insert failed'; then
	ok "insert failure is reported"
else
	bad "insert failure swallowed"
fi
if printf '%s' "$LOGS" | grep -q 'No such file or directory'; then
	ok "the warning carries nft's reason"
else
	bad "the warning drops nft's stderr"
fi
# nft's failure output spans three lines (error, echoed rule, caret).  One
# kmsg record per line would flood the ring, so only the first is kept.
NFT_INSERT_ERR="Error: first line
insert rule inet surflare output ...
                          ^^^^^^"
LOGS=""
$FUNC
if printf '%s' "$LOGS" | grep -q '\^\^\^'; then
	bad "multi-line nft stderr leaks into the log"
else
	ok "only the first line of nft's stderr is logged"
fi
NFT_INSERT_RC=0
NFT_INSERT_ERR=""

# --- case 5b: insert fails with empty stderr -> still reported once ------
reset_rules
NFT_INSERT_RC=1
NFT_INSERT_ERR=""
$FUNC
$FUNC
n=$(printf '%s' "$LOGS" | grep -c 'insert failed')
if [ "$n" -eq 1 ]; then
	ok "empty nft stderr is still reported, and only once"
else
	bad "empty nft stderr reported $n times"
fi
NFT_INSERT_RC=0
NFT_INSERT_ERR=""

# --- case 5c: the report state must survive a subshell -------------------
# connect_vpn's whole body runs in ( ... ) and probe_best_transit is called
# through command substitution, so a shell variable would be a per-call copy
# and every call would report again.
reset_rules
NFT_INSERT_RC=1
NFT_INSERT_ERR=""
( $FUNC )
( $FUNC )
( $FUNC )
n=$(grep -c 'insert failed' "$TMP/log.txt" 2>/dev/null || echo 0)
if [ "$n" -eq 1 ]; then
	ok "one report across three subshell calls (state is not per-process)"
else
	bad "subshell calls reported $n times"
fi
NFT_INSERT_RC=0
NFT_INSERT_ERR=""

# --- case 6: table present but the output chain is not ------------------
reset_rules
NFT_CHAIN=0
$FUNC
$FUNC
if grep -q 'insert rule' "$ARGV_FILE"; then
	bad "no chain: tried to insert into a chain that does not exist"
else
	ok "no chain: does not insert"
fi
if [ "$(printf '%s' "$LOGS" | grep -c 'output chain missing')" -eq 1 ]; then
	ok "no chain: reported once, not every cycle"
else
	bad "no chain: reported $(printf '%s' "$LOGS" | grep -c 'output chain missing') times"
fi
NFT_CHAIN=1

# --- case 7: a tagged rule that no longer drops does not count ----------
reset_rules
echo 'oifname "lo" tcp dport 10800 counter packets 0 bytes 0 accept comment "watchdog-tproxy-self-dial" # handle 4' >> "$RULES_FILE"
$FUNC
if [ "$(rule_count)" -eq 1 ] && grep -q ' drop' "$RULES_FILE"; then
	ok "a tagged rule that no longer drops is replaced by a dropping one"
else
	bad "a softened copy survived: $(cat "$RULES_FILE")"
fi

# --- case 8: a tagged drop on another port does not count --------------
reset_rules
echo 'oifname "lo" tcp dport 1081 counter packets 0 bytes 0 drop comment "watchdog-tproxy-self-dial" # handle 5' >> "$RULES_FILE"
$FUNC
if [ "$(rule_count)" -eq 1 ] && grep -q 'tcp dport 10800' "$RULES_FILE"; then
	ok "a tagged drop on another port is replaced by the right one"
else
	bad "a wrong-port copy survived: $(cat "$RULES_FILE")"
fi

# --- case 6b: an unreadable chain is not reported as a missing one ------
# "no such chain" resolves itself when the proxy starts; a netlink refusal
# needs an operator, and recording it as the first would hide the real cause.
reset_rules
NFT_CHAIN=2
$FUNC
$FUNC
if printf '%s' "$LOGS" | grep -q 'unreadable'; then
	ok "an unreadable chain is reported as unreadable"
else
	bad "unreadable chain went unreported: ${LOGS:-<silence>}"
fi
if [ "$(printf '%s' "$LOGS" | grep -c unreadable)" -eq 1 ]; then
	ok "the unreadable report is transition-gated too"
else
	bad "unreadable reported $(printf '%s' "$LOGS" | grep -c unreadable) times"
fi
NFT_CHAIN=1

# --- case 6c: a rule that is no longer first gets re-anchored -----------
# Other components insert their accepts at the head after us; an accept above
# this drop hands the self-dial back to the tunnel while the guard reports
# applied.
reset_rules
printf '%s\n' 'ip daddr 127.0.0.0/8 accept # handle 30' > "$RULES_FILE"
echo 'oifname "lo" tcp dport 10800 counter packets 0 bytes 0 drop comment "watchdog-tproxy-self-dial" # handle 20' >> "$RULES_FILE"
$FUNC
if head -1 "$RULES_FILE" | grep -q 'watchdog-tproxy-self-dial'; then
	ok "a demoted rule is re-anchored to the head"
else
	bad "rule left below an accept: $(head -1 "$RULES_FILE")"
fi
if [ "$(rule_count)" -eq 2 ]; then
	ok "re-anchoring keeps exactly one copy of the rule"
else
	bad "re-anchoring left $(rule_count) rules"
fi

# --- case 6d: a FIFO at the note path must not block the guard ----------
reset_rules
rm -f "$_SELF_DIAL_NOTE"
mkfifo "$_SELF_DIAL_NOTE" 2>/dev/null
if [ -p "$_SELF_DIAL_NOTE" ]; then
	_SELF_DIAL_NOTE="$_SELF_DIAL_NOTE" timeout 5 bash -c '
		. "$1/funcs.sh"
		_self_dial_note_read >/dev/null
	' _ "$TMP" 2>/dev/null
	[ "$?" -ne 124 ] && ok "a FIFO at the note path does not block" || bad "the guard hung on a FIFO note"
else
	ok "FIFO test skipped (mkfifo unavailable)"
fi
rm -f "$_SELF_DIAL_NOTE"

# --- case 6e: a symlink at the note path is not followed ----------------
reset_rules
victim="$TMP/victim"; echo "original" > "$victim"
ln -sf "$victim" "$_SELF_DIAL_NOTE" 2>/dev/null
got=$(_SELF_DIAL_NOTE="$_SELF_DIAL_NOTE" bash -c '
	. "$1/funcs.sh"
	_self_dial_note_read
' _ "$TMP" 2>/dev/null)
_SELF_DIAL_NOTE="$_SELF_DIAL_NOTE" bash -c '
	. "$1/funcs.sh"
	_self_dial_note_set "clobbered"
' _ "$TMP" 2>/dev/null
if [ -z "$got" ] && [ "$(cat "$victim")" = "original" ]; then
	ok "a symlinked note is neither read through nor clobbered"
else
	bad "symlinked note: read='$got' victim=$(cat "$victim")"
fi
rm -f "$_SELF_DIAL_NOTE"

# --- case 6f: an anchored rule is left alone ---------------------------
# Re-anchoring on every tick would reset the counter that proves the loop is
# gone, and would open a window with no drop rule at all.
reset_rules
echo 'oifname "lo" tcp dport 10800 counter packets 7 bytes 420 drop comment "watchdog-tproxy-self-dial" # handle 20' > "$RULES_FILE"
: > "$ARGV_FILE"
$FUNC
$FUNC
$FUNC
if [ "$(rule_count)" -eq 1 ] && ! grep -q 'delete rule' "$ARGV_FILE"; then
	ok "an anchored rule is left alone when already first"
else
	bad "the guard churned an anchored rule: $(grep -c 'delete rule' "$ARGV_FILE") deletes"
fi
if grep -q 'counter packets 7 bytes 420' "$RULES_FILE"; then
	ok "the counter survives a healthy pass"
else
	bad "the counter was reset by a needless re-anchor"
fi

# --- case 6g: the delete refuses a handle that changed generation -------
# surflare recreates its table on every start and the new table hands the same
# handle numbers out again, so a handle from an older listing can name someone
# else's rule by the time the delete runs.
reset_rules
echo 'oifname "lo" tcp dport 10800 counter packets 0 bytes 0 drop comment "watchdog-tproxy-self-dial" # handle 2' > "$RULES_FILE"
echo 'oifname "lo" tcp dport 10800 counter packets 0 bytes 0 drop comment "watchdog-tproxy-self-dial" # handle 3' >> "$RULES_FILE"
echo 'ip saddr 172.16.9.9 accept # handle 3' > "$RULES_FILE.gen2"
: > "$ARGV_FILE"
NFT_SWAP_AFTER=1 $FUNC
if grep -q 'delete rule' "$ARGV_FILE"; then
	bad "deleted handle 3 after the table was rebuilt under it"
else
	ok "a handle that changed generation is not deleted"
fi
if grep -q '172.16.9.9' "$RULES_FILE.gen2"; then
	ok "the other generation's rule is untouched"
else
	bad "the other generation lost a rule"
fi

# --- case 6h: a tagged port range is not our rule -----------------------
reset_rules
echo 'oifname "lo" tcp dport 10800-10810 counter packets 0 bytes 0 drop comment "watchdog-tproxy-self-dial" # handle 2' > "$RULES_FILE"
$FUNC
if [ "$(rule_count)" -eq 1 ] && grep -q 'tcp dport 10800 ' "$RULES_FILE"; then
	ok "a tagged port range is replaced by the exact rule"
else
	bad "the range was adopted as ours: $(cat "$RULES_FILE")"
fi

# --- case 6i: no whole-table probe on the steady path -------------------
reset_rules
: > "$ARGV_FILE"
$FUNC
if grep -q 'list table' "$ARGV_FILE"; then
	bad "a whole-table listing is back on the steady path"
else
	ok "the steady path lists only the chain"
fi

# --- case 9: lifecycle coverage, asserted as a property -----------------
icmp=$(grep -c '^[[:space:]]*_patch_surflare_icmp_lan$' "$WD")
paired=$(grep -A1 '^[[:space:]]*_patch_surflare_icmp_lan$' "$WD" \
	| grep -c "^[[:space:]]*$FUNC$")
if [ "$paired" -eq "$icmp" ] && [ "$icmp" -gt 0 ]; then
	ok "paired with every ICMP-patch site ($paired/$icmp)"
else
	bad "not paired with the ICMP-patch sites ($paired/$icmp)"
fi
# Every path that runs `surflare connect` rebuilds the table, so each of
# those functions must re-apply the guard itself: a guard that only runs on
# a healthy tick waits for the loop to stop pinning the CPU, and the loop
# keeps pinning it precisely because probes fail.  The grep is anchored so a
# commented-out call cannot satisfy it.
for fn in connect_vpn _start_surflare_proxy probe_best_transit; do
	if awk -v f="$fn" '$0 ~ "^" f "\\(\\)" {inb=1} inb {print} inb && /^}$/ {exit}' "$WD" \
		| grep -q "^[[:space:]]*$FUNC$"; then
		ok "$fn re-applies the guard after rebuilding the table"
	else
		bad "$fn rebuilds the table with no guard"
	fi
done
# connect_vpn forks into a poll branch and a legacy branch; a call that only
# sits inside the poll branch leaves the legacy one unguarded, so the call has
# to land before the split.
start_ln=$(awk '/^connect_vpn\(\)/{print NR; exit}' "$WD")
guard_ln=$(awk -v s="$start_ln" -v f="$FUNC" 'NR>s && $0 ~ "^[[:space:]]*" f "$" {print NR; exit}' "$WD")
split_ln=$(awk -v s="$start_ln" 'NR>s && /_use_poll" -eq 1/ {print NR; exit}' "$WD")
if [ -n "$guard_ln" ] && [ -n "$split_ln" ] && [ "$guard_ln" -lt "$split_ln" ]; then
	ok "connect_vpn applies the guard before the settle-branch split"
else
	bad "connect_vpn guard is not ahead of the settle split (guard=$guard_ln split=$split_ln)"
fi
# The main loop calls it before any health gate, so a rebuild the watchdog
# did not drive is still covered while the verdict is failing.
if awk '/^while true; do$/{f=1;next} f&&/^[[:space:]]*[^[:space:]#]/{print;exit}' "$WD" \
	| grep -q "^[[:space:]]*$FUNC$"; then
	ok "main loop applies the guard unconditionally, above the health gate"
else
	bad "guard sits behind the health gate in the main loop"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]