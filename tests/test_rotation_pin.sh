#!/bin/bash
# Tests for the rotation-pin staleness fix: the startup node-selection
# block and the adopt-time reconcile are EXTRACTED from the real
# watchdog script, so a pass proves the production logic, not a copy.
#
# shellcheck disable=SC2015  # `[ cond ] && ok x || bad x` is safe here:
# ok()/bad() always return 0, so bad never runs after a successful ok.
# shellcheck disable=SC2016  # single quotes around harness bodies are
# intentional -- the inner $VARS must expand in the CHILD shell.

set -u
cd "$(dirname "$0")/.." || exit 1
WATCHDOG=surflare_watchdog.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# RFC 5737 TEST-NET-2 documentation address, built at runtime so no
# IPv4 literal sits in the file (the editing harness rewrites them).
DEDICATED="United States($(printf '%d.%d.%d.%d' 198 51 100 7))"

# Startup selection block: from the initial assignment through the new
# state-file persist (an if-block whose WARN is followed by its fi, so
# the terminator is that closing fi, not the WARN line itself).
extract_startup() {
	awk '
		/^[[:space:]]*_active_node="\$NODE"[[:space:]]*$/ { f=1 }
		f { print }
		f && /failed to persist rotation state/ { w=1 }
		w && /^[[:space:]]*fi[[:space:]]*$/ { exit }
	' "$1"
}

# Live-session reconcile function: extracted so T4-T26 keep working
# after the adopt inline is replaced by a call.  The function body is
# the production source of truth (same bytes as adopt + main loop).
extract_reconcile_fn() {
	awk '
		/^_reconcile_rotation_with_live_session\(\)/ { f=1 }
		f { print }
		f && /^}/ { exit }
	' "$1"
}

# Adopt reconcile block: prefer the extracted function; fall back to
# the historical inline (pre-extract trees) so T7/T8 inject still
# targets production bytes.
extract_adopt() {
	local fn
	fn=$(extract_reconcile_fn "$1")
	if [ -n "$fn" ]; then
		printf '%s\n' "$fn"
		echo '_reconcile_rotation_with_live_session'
		return
	fi
	awk '
		/Reconcile rotation state with the ADOPTED session/ { f=1 }
		f && /_start_proxy_log_monitor/ { exit }
		f { print }
	' "$1"
}

# Offline `surflare status` stub.  STATUS_OUT is the body, STATUS_RC
# the exit (124 = timeout/fail-closed).  PATH-prepended so production
# `timeout 5 surflare status` hits this, not a real CLI.
make_surflare_stub() {
	local d
	d=$(mktemp -d /tmp/rp_sf_XXXXXX)
	# STATUS_OUT/STATUS_RC baked into the stub so the child does not
	# need them exported through nested bash -c quoting.
	printf '%s\n' "#!/bin/sh" > "$d/surflare"
	printf '%s\n' "STATUS_RC=${STATUS_RC:-0}" >> "$d/surflare"
	printf '%s\n' "cat <<'STATUS_EOF'" >> "$d/surflare"
	printf '%s\n' "${STATUS_OUT:-}" >> "$d/surflare"
	printf '%s\n' "STATUS_EOF" >> "$d/surflare"
	printf '%s\n' "exit \"\$STATUS_RC\"" >> "$d/surflare"
	chmod +x "$d/surflare"
	printf '%s\n' "$d"
}

# run_startup <wd-file>: env seeds NODE, CANDS (space-separated,
# dedicated first), ROT_FILE_CONTENT (empty = no file).  Prints
# "active idx | file-content | override-log-flag".
run_startup() {
	local wd="${1:-$WATCHDOG}" blk
	blk=$(extract_startup "$wd")
	if [ -z "$blk" ] || ! printf '%s\n' "$blk" | grep -q 'ROTATION_STATE'; then
		echo "EXTRACT_FAIL"
		return 99
	fi
	local rfile
	rfile=$(mktemp /tmp/rp_rot_XXXXXX)
	if [ -n "${ROT_FILE_CONTENT:-}" ]; then
		printf '%s\n' "$ROT_FILE_CONTENT" > "$rfile"
	else
		rm -f "$rfile"
	fi
	NODE="${NODE:-}" CANDS="${CANDS:-}" RFILE="$rfile" \
	bash -c "
		set -u
		log() { LOG_BUF=\"\$LOG_BUF|\$1\"; }
		NODE=\"\$NODE\"
		ROTATION_STATE=\"\$RFILE\"
		IFS='|' read -r -a NODE_CANDIDATES <<< \"\$CANDS\"
		LOG_BUF=
		$blk
		case \"\$LOG_BUF\" in *overrides*) _o=1 ;; *) _o=0 ;; esac
		_f=; [ -f \"\$ROTATION_STATE\" ] && _f=\$(cat \"\$ROTATION_STATE\")
		echo \"\$_active_node|\$_node_idx|\$_f|\$_o\"
	" 2>/dev/null
	rm -f "$rfile"
}

# run_adopt <wd-file>: env seeds ACTIVE, STATUS_OUT, STATUS_RC, CANDS.
# CLI_LOG_CONTENT is poison-only (stale daemon log); reconcile must
# ignore it.  Prints "active idx | file-content | reconcile-log-flag".
run_adopt() {
	local wd="${1:-$WATCHDOG}" blk
	blk=$(extract_adopt "$wd")
	if [ -z "$blk" ] || ! printf '%s\n' "$blk" | grep -q '_adopted_node'; then
		echo "EXTRACT_FAIL"
		return 99
	fi
	local clog rfile stubdir
	clog=$(mktemp /tmp/rp_cli_XXXXXX)
	rfile=$(mktemp /tmp/rp_rot_XXXXXX)
	printf '%s\n' "${CLI_LOG_CONTENT:-}" > "$clog"
	[ "${CLI_LOG_CONTENT:-}" = "__MISSING__" ] && rm -f "$clog"
	printf '%s\n' "${ROT_FILE_CONTENT:-}" > "$rfile"
	stubdir=$(make_surflare_stub)
	ACTIVE="${ACTIVE:-}" CANDS="${CANDS:-}" CLOG="$clog" RFILE="$rfile" \
	STUBDIR="$stubdir" \
	bash -c "
		set -u
		log() { LOG_BUF=\"\$LOG_BUF|\$1\"; }
		PATH=\"\$STUBDIR:\$PATH\"
		export PATH
		SURFLARE_CLI_LOG=\"\$CLOG\"
		ROTATION_STATE=\"\$RFILE\"
		IFS='|' read -r -a NODE_CANDIDATES <<< \"\$CANDS\"
		LOG_BUF=
		run() {
			local _adopted_node _ai _afound=0
			local _active_node=\"\$ACTIVE\" _node_idx=1
			$blk
			case \"\$LOG_BUF\" in *Adopt\ reconcile*) _r=1 ;; *) _r=0 ;; esac
			_f=; [ -f \"\$ROTATION_STATE\" ] && _f=\$(cat \"\$ROTATION_STATE\")
			echo \"\$_active_node|\$_node_idx|\$_f|\$_r\"
		}
		run
	" 2>/dev/null
	rm -rf "$clog" "$rfile" "$stubdir"
}

echo "T1: stale file (LA) + pinned NODE -> pin wins, file rewritten"
OUT=$(NODE="$DEDICATED" CANDS="$DEDICATED|Los Angeles|Atlanta" \
	ROT_FILE_CONTENT="$(printf 'Los Angeles\t1')" run_startup)
[ "$OUT" = "$DEDICATED|0|$DEDICATED	0|1" ] && ok "pin overrides stale file" || bad "T1 wrong: $OUT"

echo "T2: no pin (city NODE) + valid saved -> saved restored (legacy kept)"
OUT=$(NODE="Chicago" CANDS="Chicago|Los Angeles|Atlanta" \
	ROT_FILE_CONTENT="$(printf 'Los Angeles\t1')" run_startup)
[ "$OUT" = "Los Angeles|1|Los Angeles	1|0" ] && ok "restore preserved without pin" || bad "T2 wrong: $OUT"

echo "T3: saved node not in candidates -> NODE"
OUT=$(NODE="Chicago" CANDS="Chicago|Los Angeles|Atlanta" \
	ROT_FILE_CONTENT="$(printf 'Miami\t9')" run_startup)
[ "$OUT" = "Chicago|0|Chicago	0|0" ] && ok "unknown saved -> NODE" || bad "T3 wrong: $OUT"

echo "T4: adopt reconcile -- status Server is the pin, rotation said LA"
OUT=$(ACTIVE="Los Angeles" CANDS="$DEDICATED|Los Angeles|Atlanta" \
	STATUS_OUT="  Server:      $DEDICATED" \
	CLI_LOG_CONTENT="+0800 [INFO]  Connected  server=Los Angeles mode=rule relay=auto" \
	ROT_FILE_CONTENT="$(printf 'Los Angeles\t1')" run_adopt)
[ "$OUT" = "$DEDICATED|0|$DEDICATED	0|1" ] && ok "adopt reconciled to live pin" || bad "T4 wrong: $OUT"

echo "T5: adopt no-op when status already matches"
OUT=$(ACTIVE="Los Angeles" CANDS="$DEDICATED|Los Angeles|Atlanta" \
	STATUS_OUT="  Server:      Los Angeles" \
	ROT_FILE_CONTENT="$(printf 'Los Angeles\t1')" run_adopt)
[ "$OUT" = "Los Angeles|1|Los Angeles	1|0" ] && ok "no-op when aligned" || bad "T5 wrong: $OUT"

echo "T6: adopt with unparseable status (no Server:) -> keep restored state"
OUT=$(ACTIVE="Los Angeles" CANDS="$DEDICATED|Los Angeles|Atlanta" \
	STATUS_OUT="garbage line without server field" \
	CLI_LOG_CONTENT="+0800 [INFO]  Connected  server=$DEDICATED mode=rule relay=auto" \
	ROT_FILE_CONTENT="$(printf 'Los Angeles\t1')" run_adopt)
[ "$OUT" = "Los Angeles|1|Los Angeles	1|0" ] && ok "unparseable -> keep" || bad "T6 wrong: $OUT"

echo "T7: bug-inject -- deleting the pin-override case must flip T1"
INJ=$(mktemp /tmp/rp_inj_XXXXXX)
python3 - "$WATCHDOG" "$INJ" << 'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
old = 'if [[ $NODE =~ \\([0-9]+\\.[0-9.]+\\) ]]; then\n'
assert s.count(old) == 1, "pin-override anchor missing"
open(dst, 'w').write(s.replace(old, 'if false; then\n', 1))
PYEOF
OUT=$(NODE="$DEDICATED" CANDS="$DEDICATED|Los Angeles|Atlanta" \
	ROT_FILE_CONTENT="$(printf 'Los Angeles\t1')" run_startup "$INJ")
[ "$OUT" = "Los Angeles|1|Los Angeles	1|0" ] && ok "pin-override deleted -> stale wins (caught)" || bad "T7 NOT caught: $OUT"
rm -f "$INJ"

echo "T8: bug-inject -- deleting the reconcile assignment must flip T4"
INJ=$(mktemp /tmp/rp_inj2_XXXXXX)
python3 - "$WATCHDOG" "$INJ" << 'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
old = '_active_node="$_adopted_node"'
assert s.count(old) == 1, "reconcile anchor missing"
open(dst, 'w').write(s.replace(old, ': reconcile deleted', 1))
PYEOF
OUT=$(ACTIVE="Los Angeles" CANDS="$DEDICATED|Los Angeles|Atlanta" \
	STATUS_OUT="  Server:      $DEDICATED" \
	CLI_LOG_CONTENT="+0800 [INFO]  Connected  server=$DEDICATED mode=rule relay=auto" \
	ROT_FILE_CONTENT="$(printf 'Los Angeles\t1')" run_adopt "$INJ")
# the essential: _active_node must NOT flip to the adopted node. The
# injected block still runs the idx search and the persist, so the
# deterministic outcome is LA kept with the pin's cursor 0.
[ "$OUT" = "Los Angeles|0|Los Angeles	0|1" ] && ok "reconcile deleted -> stale kept (caught)" || bad "T8 NOT caught: $OUT"
rm -f "$INJ"

echo "T9: pinned NODE absent from candidates (subscription lapse) -> keep restored, no dial of unlisted node"
OUT=$(NODE="$DEDICATED" CANDS="Chicago|Los Angeles|Atlanta" \
	ROT_FILE_CONTENT="$(printf 'Los Angeles\t1')" run_startup)
[ "$OUT" = "Los Angeles|1|Los Angeles	1|0" ] && ok "lapsed pin -> restored kept" || bad "T9 wrong: $OUT"

echo "T10: status Server: with extra spaces still parses (tui sed)"
OUT=$(ACTIVE="Los Angeles" CANDS="$DEDICATED|Los Angeles|Atlanta" \
	STATUS_OUT="  Server:      $DEDICATED" \
	ROT_FILE_CONTENT="$(printf 'Los Angeles\t1')" run_adopt)
[ "$OUT" = "$DEDICATED|0|$DEDICATED	0|1" ] && ok "padded Server: parsed" || bad "T10 wrong: $OUT"

echo "T11: NODE with non-IP parens (Chicago (backup)) is NOT a pin -> saved restored"
OUT=$(NODE="Chicago (backup)" CANDS="Chicago (backup)|Los Angeles|Atlanta" \
	ROT_FILE_CONTENT="$(printf 'Los Angeles\t1')" run_startup)
[ "$OUT" = "Los Angeles|1|Los Angeles	1|0" ] && ok "non-IP parens -> not a pin" || bad "T11 wrong: $OUT"

echo "T12: no state file at all + city NODE -> NODE, file created"
OUT=$(NODE="Chicago" CANDS="Chicago|Los Angeles|Atlanta" run_startup)
[ "$OUT" = "Chicago|0|Chicago	0|0" ] && ok "no file -> NODE + file created" || bad "T12 wrong: $OUT"

echo "T13: NODE with EMPTY parens '()' is NOT a pin -> saved restored"
OUT=$(NODE="()" CANDS="()|Los Angeles|Atlanta" \
	ROT_FILE_CONTENT="$(printf 'Los Angeles\t1')" run_startup)
[ "$OUT" = "Los Angeles|1|Los Angeles	1|0" ] && ok "empty parens -> not a pin" || bad "T13 wrong: $OUT"

echo "T14: NODE 'Chicago (2)' (numeric non-IP parens) is NOT a pin"
OUT=$(NODE="Chicago (2)" CANDS="Chicago (2)|Los Angeles|Atlanta" \
	ROT_FILE_CONTENT="$(printf 'Los Angeles\t1')" run_startup)
[ "$OUT" = "Los Angeles|1|Los Angeles	1|0" ] && ok "numeric non-IP -> not a pin" || bad "T14 wrong: $OUT"

echo "T15: pin at NON-ZERO index, no state file -> idx follows the pin"
OUT=$(NODE="$DEDICATED" CANDS="Los Angeles|$DEDICATED|Atlanta" run_startup)
[ "$OUT" = "$DEDICATED|1|$DEDICATED	1|0" ] && ok "pin idx recomputed" || bad "T15 wrong: $OUT"

echo "T16: adopt -- status Server NOT in candidates -> keep restored, no reconcile"
OUT=$(ACTIVE="Los Angeles" CANDS="$DEDICATED|Los Angeles|Atlanta" \
	STATUS_OUT="  Server:      Miami" \
	ROT_FILE_CONTENT="$(printf 'Los Angeles\t1')" run_adopt)
[ "$OUT" = "Los Angeles|1|Los Angeles	1|0" ] && ok "unlisted live node -> keep" || bad "T16 wrong: $OUT"

echo "T17: status=LA beats stale CLI Connected=dedicated (daemon reconnect)"
# Measured N100 2026-09-05 17:56: watchdog connect --daemon --node LA
# does not append a Connected line; CLI log still named the pin.
OUT=$(ACTIVE="Los Angeles" CANDS="$DEDICATED|Los Angeles|Atlanta" \
	STATUS_OUT="  Server:      Los Angeles" \
	CLI_LOG_CONTENT="+0800 [INFO]  Connected  server=$DEDICATED mode=rule relay=auto" \
	ROT_FILE_CONTENT="$(printf 'Los Angeles\t1')" run_adopt)
[ "$OUT" = "Los Angeles|1|Los Angeles	1|0" ] && ok "status wins over stale CLI" || bad "T17 wrong: $OUT"

echo "T18: no state file + non-pin NODE at non-zero index -> true cursor persisted"
OUT=$(NODE="Atlanta" CANDS="Chicago|Los Angeles|Atlanta" run_startup)
[ "$OUT" = "Atlanta|2|Atlanta	2|0" ] && ok "non-pin idx resolved" || bad "T18 wrong: $OUT"

echo "T19: lapsed pin + NO state file -> fall back to first listed candidate"
OUT=$(NODE="$DEDICATED" CANDS="Chicago|Los Angeles|Atlanta" run_startup)
[ "$OUT" = "Chicago|0|Chicago	0|0" ] && ok "lapsed pin fileless -> fallback" || bad "T19 wrong: $OUT"

echo "T20: unwritable ROTATION_STATE -> WARN logged (not silent)"
BLK=$(extract_startup "$WATCHDOG")
OUT=$(bash -c "
	set -u
	log() { LOG_BUF=\"\$LOG_BUF|\$1\"; }
	NODE=\"Chicago\"; ROTATION_STATE=/nonexistent_rp/state
	IFS='|' read -r -a NODE_CANDIDATES <<< \"Chicago|Los Angeles\"
	LOG_BUF=
	$BLK
	case \"\$LOG_BUF\" in *failed\\ to\\ persist*) echo WARN_SEEN ;; *) echo \"NO_WARN:\$LOG_BUF\" ;; esac
" 2>/dev/null)
[ "$OUT" = "WARN_SEEN" ] && ok "persist failure warns" || bad "T20 wrong: $OUT"

echo "T21: production SURFLARE_CLI_LOG declaration present"
grep -q '^SURFLARE_CLI_LOG="/var/log/surflare/surflare.log"' "$WATCHDOG" \
	&& ok "CLI log path declared" || bad "T21: declaration missing"

echo "T22: '(1.1)' IS pin-shaped by design (heuristic + membership guard)"
OUT=$(NODE="(1.1)" CANDS="(1.1)|Los Angeles" \
	ROT_FILE_CONTENT="$(printf 'Los Angeles\t1')" run_startup)
[ "$OUT" = "(1.1)|0|(1.1)	0|1" ] && ok "IP-ish parens pin" || bad "T22 wrong: $OUT"

echo "T23: invalid saved node + non-pin NODE at non-zero index -> lookup loop is load-bearing"
OUT=$(NODE="Atlanta" CANDS="Chicago|Los Angeles|Atlanta" \
	ROT_FILE_CONTENT="$(printf 'Miami\t9')" run_startup)
[ "$OUT" = "Atlanta|2|Atlanta	2|0" ] && ok "invalid saved + non-zero NODE" || bad "T23 wrong: $OUT"

echo "T24: non-pin NODE unlisted + no state file -> unified fallback to first candidate"
OUT=$(NODE="Miami" CANDS="Chicago|Los Angeles|Atlanta" run_startup)
[ "$OUT" = "Chicago|0|Chicago	0|0" ] && ok "unlisted city NODE -> fallback" || bad "T24 wrong: $OUT"

echo "T25: adopt persist failure -> WARN logged (not silent)"
BLK=$(extract_adopt "$WATCHDOG")
STUBDIR=$(STATUS_OUT="  Server:      $DEDICATED" make_surflare_stub)
OUT=$(PATH="$STUBDIR:$PATH" bash -c "
	set -u
	log() { LOG_BUF=\"\$LOG_BUF|\$1\"; }
	ROTATION_STATE=/nonexistent_rp/state
	IFS='|' read -r -a NODE_CANDIDATES <<< \"$DEDICATED|Los Angeles|Atlanta\"
	LOG_BUF=
	run() {
		local _adopted_node _ai _afound=0
		local _active_node=\"Los Angeles\" _node_idx=1
		$BLK
		case \"\$LOG_BUF\" in *failed\\ to\\ persist*) echo WARN_SEEN ;; *) echo \"NO_WARN:\$LOG_BUF\" ;; esac
	}
	run
" 2>/dev/null)
[ "$OUT" = "WARN_SEEN" ] && ok "adopt persist failure warns" || bad "T25 wrong: $OUT"
rm -rf "$STUBDIR"

echo "T26: status non-zero (rc=124) -> no reconcile, even if CLI log names the pin"
OUT=$(ACTIVE="Los Angeles" CANDS="$DEDICATED|Los Angeles|Atlanta" \
	STATUS_RC=124 STATUS_OUT="  Server:      $DEDICATED" \
	CLI_LOG_CONTENT="+0800 [INFO]  Connected  server=$DEDICATED mode=rule relay=auto" \
	ROT_FILE_CONTENT="$(printf 'Los Angeles\t1')" run_adopt)
[ "$OUT" = "Los Angeles|1|Los Angeles	1|0" ] && ok "status fail-closed -> keep" || bad "T26 wrong: $OUT"

echo "T27: '(1.)' (digit dot, nothing after) is NOT pin-shaped"
OUT=$(NODE="(1.)" CANDS="(1.)|Los Angeles" \
	ROT_FILE_CONTENT="$(printf 'Los Angeles\t1')" run_startup)
[ "$OUT" = "Los Angeles|1|Los Angeles	1|0" ] && ok "(1.) -> not a pin" || bad "T27 wrong: $OUT"

echo "T28: valid saved node with STALE saved index -> idx recomputed from catalog, not file"
OUT=$(NODE="Chicago" CANDS="Chicago|Los Angeles|Atlanta" \
	ROT_FILE_CONTENT="$(printf 'Los Angeles	9')" run_startup)
[ "$OUT" = "Los Angeles|1|Los Angeles	1|0" ] && ok "stale saved idx recomputed" || bad "T28 wrong: $OUT"

echo "T29: _reconcile_rotation_with_live_session is a named function (not adopt-only inline)"
grep -q '^_reconcile_rotation_with_live_session()' "$WATCHDOG" \
	&& ok "reconcile is a function" || bad "T29: function missing"

echo "T30: main loop calls reconcile every cycle (tui pin path, not just adopt)"
# The call must sit in the 20 lines immediately BEFORE the MAIN-LOOP
# assignment health=$(check_vpn_health) (single-tab indent, not the
# crash-path new_health=).
python3 - "$WATCHDOG" << 'PY'
import sys
from pathlib import Path
lines = Path(sys.argv[1]).read_text().splitlines()
idx = next(i for i, l in enumerate(lines) if l.startswith("	health=$(check_vpn_health)"))
window = "\n".join(lines[max(0, idx-20):idx])
sys.exit(0 if "_reconcile_rotation_with_live_session" in window else 1)
PY
[ $? -eq 0 ] && ok "main loop calls reconcile" || bad "T30: no loop call before check_vpn_health"

echo "T31: reconcile reads surflare status, not CLI Connected lines"
python3 - "$WATCHDOG" << 'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
start = text.find("_reconcile_rotation_with_live_session() {")
end = text.find("\n}", start)
body = text[start:end]
ok = (
    "timeout 5 surflare status" in body
    and "Server:" in body
    and "Connected" not in body
)
sys.exit(0 if ok else 1)
PY
t31_rc=$?
calls=$(grep -c '_reconcile_rotation_with_live_session' "$WATCHDOG" || true)
[ "$t31_rc" -eq 0 ] && [ "$calls" -ge 3 ] \
	&& ok "status source, >=3 call sites" || bad "T31: status-source rc=$t31_rc calls=$calls"

echo "T32: bug-inject -- deleting the loop call must fail T30 (load-bearing)"
if ! grep -q '^_reconcile_rotation_with_live_session()' "$WATCHDOG"; then
	bad "T32: no function to inject"
else
	INJ=$(mktemp /tmp/rp_inj_loop_XXXXXX)
	python3 - "$WATCHDOG" "$INJ" << 'PYEOF'
import sys
from pathlib import Path
src, dst = sys.argv[1], sys.argv[2]
s = Path(src).read_text()
old = "_reconcile_rotation_with_live_session\n"
idx = s.find(old)
assert idx >= 0, "no call"
idx2 = s.find(old, idx + len(old))
assert idx2 >= 0, "need a second call (loop)"
Path(dst).write_text(s[:idx2] + s[idx2+len(old):])
PYEOF
	if [ $? -ne 0 ]; then
		bad "T32: inject could not find two calls"
	else
		python3 - "$INJ" << 'PY'
import sys
from pathlib import Path
lines = Path(sys.argv[1]).read_text().splitlines()
idx = next(i for i, l in enumerate(lines) if l.startswith("	health=$(check_vpn_health)"))
window = "\n".join(lines[max(0, idx-20):idx])
sys.exit(0 if "_reconcile_rotation_with_live_session" in window else 1)
PY
		rc=$?
		[ "$rc" -ne 0 ] && ok "loop-call deleted -> T30 would fail" || bad "T32 NOT caught"
	fi
	rm -f "$INJ"
fi

echo "T33: reconcile wraps status in timeout 5 (same budget as connect_vpn)"
python3 - "$WATCHDOG" << 'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
start = text.find("_reconcile_rotation_with_live_session() {")
end = text.find("\n}", start)
body = text[start:end]
sys.exit(0 if "timeout 5 surflare status" in body else 1)
PY
[ $? -eq 0 ] && ok "timeout 5 around status" || bad "T33: no timeout 5 surflare status in reconcile"

echo "T34: bug-inject -- dropping the timeout wrap must fail T33"
python3 - "$WATCHDOG" << 'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
start = text.find("_reconcile_rotation_with_live_session() {")
end = text.find("\n}", start)
body = text[start:end]
sys.exit(0 if "timeout 5 surflare status" in body else 1)
PY
if [ $? -ne 0 ]; then
	bad "T34: no timeout 5 in reconcile to inject"
else
	INJ=$(mktemp /tmp/rp_inj_to_XXXXXX)
	python3 - "$WATCHDOG" "$INJ" << 'PYEOF'
import sys
from pathlib import Path
src, dst = sys.argv[1], sys.argv[2]
s = Path(src).read_text()
start = s.find("_reconcile_rotation_with_live_session() {")
end = s.find("\n}", start)
body = s[start:end]
old = "timeout 5 surflare status"
assert old in body, old
new_body = body.replace(old, "surflare status", 1)
Path(dst).write_text(s[:start] + new_body + s[end:])
PYEOF
	python3 - "$INJ" << 'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
start = text.find("_reconcile_rotation_with_live_session() {")
end = text.find("\n}", start)
body = text[start:end]
sys.exit(0 if "timeout 5 surflare status" in body else 1)
PY
	[ $? -ne 0 ] && ok "timeout wrap deleted -> T33 would fail" || bad "T34 NOT caught"
	rm -f "$INJ"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
