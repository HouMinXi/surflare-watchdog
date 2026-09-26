#!/bin/bash
# Tests for the screen-reading TUI navigation in pin_dedicated
# (scripts/tui-supervisor.sh). The function is EXTRACTED verbatim from
# the real supervisor script and driven against a stub `sexpect` whose
# screen output is a pre-recorded sequence of server-list frames -- one
# frame per keypress -- so a pass proves the production stepping logic,
# not a copy.
#
# Background (2026-09-26, surflare v4.3.1): the search box is
# mouse-only; the old search-filter-then-two-arrows path landed on the
# FIRST dedicated row, which was the retired Verizon IP, not ours. The
# new logic steps the cursor and reads the cursor row after every
# keypress until it contains DED_NODE (single key: search and verify
# must agree or a sibling dedicated row can be walked onto).
#
# Frame model (matches the production log the real sexpect -logf
# writes): one cumulative pty log; the spawn writes the initial screen
# (frame 1); every arrow-key appends exactly one new cursor row. The
# loop's first read therefore sees frame 1, and after step n it sees
# frame n+1 at the tail.
#
# shellcheck disable=SC2016  # single quotes around harness bodies are intentional

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
SUP=scripts/tui-supervisor.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
SANDBOXES=()

cleanup() {
	local sb
	for sb in "${SANDBOXES[@]:-}"; do
		[ -n "$sb" ] && rm -rf "$sb"
	done
}
trap cleanup EXIT INT TERM

extract_fn() {
	awk -v fn="$2" '
		$0 ~ "^" fn "\\(\\)" { f=1 }
		f { print }
		f && /^}/ { exit }
	' "$1"
}

# --------------------------------------------------------------------
# Harness: build a sandbox with stub sexpect/surflare on PATH, write a
# frame sequence (one line per simulated screen state), then run the
# extracted pin_dedicated with the stub env.
#
# FRAME_FILE format: one cursor row per line, in order. Frame 1 is the
# state when the list first opens (cursor on the first row); each
# subsequent line is the cursor row after the next down-arrow.
# STATUS_FILE: what `surflare status | grep Server:` finally reports.
# --------------------------------------------------------------------
run_pin() {
	local frames="$1" status_line="$2" log="$3" sup="${4:-$SUP}"
	local sb
	sb=$(mktemp -d /tmp/tuinav_XXXXXX)
	SANDBOXES+=("$sb")
	mkdir -p "$sb/bin"

	# Stub sexpect. Real call layout is `sexpect -s SOCK <sub> ...`:
	# $1=-s $2=SOCK $3=subcommand $4=-c $5=keys.
	cat > "$sb/bin/sexpect" << 'STUB'
#!/bin/bash
case "$3" in
	kill|close) exit 0 ;;
	spawn)
		# -logf starts capturing immediately: the opening screen
		# (frame 1, cursor on the first row) lands in the log
		# before any keypress.
		sed -n '1p' "$FRAMES" >> "$TUI_LOG"
		exit 0 ;;
	expect) exit 0 ;;
	send)
		# Enter: the connect keypress.
		if [ "$4" = "-cr" ]; then
			echo x >> "$ENTER_COUNTER"
			exit 0
		fi
		if [ "$4" = "-c" ] && [ "$5" = '\x1b[B' ]; then
			n=$(cat "$STEP_COUNTER" 2>/dev/null || echo 0)
			n=$((n + 1))
			echo "$n" > "$STEP_COUNTER"
			# one new cursor row per keypress
			line=$(sed -n "$((n + 1))p" "$FRAMES")
			printf '%s\n' "$line" >> "$TUI_LOG"
			# Optional redraw-flash model: when the frame just
			# appended is the target row, the TUI redraws once
			# more and moves the marker to the next row ~1s
			# later -- after the loop's 0.6s read window (so the
			# loop breaks on the flash) but before the settle
			# re-read 1s after that.
			if [ -n "${AFTER_MATCH_LAG:-}" ] \
				&& printf '%s' "$line" | grep -qF "$DED_NODE" \
				&& [ "$(wc -l < "$FRAMES")" -ge "$((n + 2))" ]; then
				( sleep 1; sed -n "$((n + 2))p" "$FRAMES" >> "$TUI_LOG" ) &
			fi
		fi
		exit 0 ;;
esac
exit 0
STUB
	chmod +x "$sb/bin/sexpect"

	cat > "$sb/bin/surflare" << STUB
#!/bin/bash
if [ "\$1" = "status" ]; then echo "  Server:      \$STATUS_LINE"; exit 0; fi
exit 0
STUB
	chmod +x "$sb/bin/surflare"

	cp "$frames" "$sb/frames.txt"
	: > "$sb/steps"
	: > "$sb/tui.log"
	: > "$sb/enters"

	local pin_fn cursor_fn
	pin_fn=$(extract_fn "$sup" pin_dedicated)
	[ -n "$pin_fn" ] || { echo "EXTRACT_FAIL pin_dedicated" > "$log"; return 99; }
	cursor_fn=$(extract_fn "$sup" _cursor_row)
	[ -n "$cursor_fn" ] || { echo "EXTRACT_FAIL _cursor_row" > "$log"; return 99; }

	env PATH="$sb/bin:/usr/bin:/bin" \
		SOCK="$sb/tui.sock" TUI_LOG="$sb/tui.log" \
		STEP_COUNTER="$sb/steps" FRAMES="$sb/frames.txt" \
		ENTER_COUNTER="$sb/enters" AFTER_MATCH_LAG="${AFTER_MATCH_LAG:-}" \
		STATUS_LINE="$status_line" \
		DED_NODE="United States(12.104.12.149)" \
		bash -c "$cursor_fn
$pin_fn
pin_dedicated" > "$log" 2>&1
	return $?
}

# Read the step count from the most recently finished sandbox.
last_steps() {
	local sb last=""
	for sb in "${SANDBOXES[@]:-}"; do
		[ -f "$sb/steps" ] && last="$sb"
	done
	[ -n "$last" ] || { echo ""; return; }
	cat "$last/steps" 2>/dev/null || echo ""
}

last_enters() {
	local sb last=""
	for sb in "${SANDBOXES[@]:-}"; do
		[ -f "$sb/enters" ] && last="$sb"
	done
	[ -n "$last" ] || { echo ""; return; }
	wc -l < "$last/enters" 2>/dev/null || echo ""
}

steps_is() {
	local want="$1" label="$2" got
	got=$(last_steps)
	if [ -n "$got" ] && [ "$got" = "$want" ]; then
		ok "$label (got $got)"
	else
		bad "$label: expected $want, got '${got:-none}'"
	fi
}

# --------------------------------------------------------------------
echo "== T1: cursor walks to the new-IP row and connects (3 dedicated rows) =="

FRAMES=$(mktemp /tmp/tuinav_f1_XXXXXX)
cat > "$FRAMES" << 'EOF'
  ▸ ← 返回
  ▸ ↺ 刷新服务器列表
  ▸ 🇺🇸 Washington(65.195.35.200)
  ▸ 🇺🇸 United States(12.104.10.184)AT&T
  ▸ 🇺🇸 United States(12.104.12.149)AT&T
EOF
LOG=$(mktemp /tmp/tuinav_l1_XXXXXX)
if run_pin "$FRAMES" "United States(12.104.12.149)AT&T" "$LOG"; then
	ok "pin succeeds walking to row 5 (new IP)"
else
	bad "pin failed; log: $(tail -3 "$LOG")"
fi
# 4 down-arrows: return -> refresh -> old-verizon -> old-att -> new
steps_is 4 "took exactly 4 steps"
rm -f "$FRAMES" "$LOG"

# --------------------------------------------------------------------
echo "== T2: sibling dedicated row ambiguity -- walk must step PAST it =="

# The retired AT&T (12.104.10.184) row still matches a loose "12.104"
# search key but NOT the full "United States(12.104.12.149)" node key:
# the walk must step past it to the real target. (Regression guard for
# the search-key/verify-key split that used DED_SEARCH.)
FRAMES=$(mktemp /tmp/tuinav_f2_XXXXXX)
cat > "$FRAMES" << 'EOF'
  ▸ ← 返回
  ▸ ↺ 刷新服务器列表
  ▸ 🇺🇸 United States(12.104.10.184)AT&T
  ▸ 🇺🇸 United States(12.104.12.149)AT&T
EOF
LOG=$(mktemp /tmp/tuinav_l2_XXXXXX)
if run_pin "$FRAMES" "United States(12.104.12.149)AT&T" "$LOG"; then
	ok "pin walks past sibling dedicated row to the real target"
else
	bad "pin failed on sibling-ambiguity list; log: $(tail -3 "$LOG")"
fi
steps_is 3 "took exactly 3 steps (past the sibling row)"
rm -f "$FRAMES" "$LOG"

# --------------------------------------------------------------------
echo "== T3: target missing from list -- MAX_STEPS bounds the walk, pin fails =="

FRAMES=$(mktemp /tmp/tuinav_f3_XXXXXX)
# 60 filler rows, none matching DED_NODE: the walk must give up at 40.
{ echo "  ▸ ← 返回"; for i in $(seq 1 60); do echo "  ▸ 🇺🇸 filler city $i"; done; } > "$FRAMES"
LOG=$(mktemp /tmp/tuinav_l3_XXXXXX)
if run_pin "$FRAMES" "filler city 40" "$LOG"; then
	bad "pin should FAIL when target absent (connected to wrong node)"
else
	ok "pin fails when target row never appears"
fi
steps_is 40 "walk stopped at MAX_STEPS=40"
rm -f "$FRAMES" "$LOG"

# --------------------------------------------------------------------
echo "== T4: connect lands on wrong node (status mismatch) -- pin returns failure =="

FRAMES=$(mktemp /tmp/tuinav_f4_XXXXXX)
cat > "$FRAMES" << 'EOF'
  ▸ ← 返回
  ▸ 🇺🇸 United States(12.104.12.149)AT&T
EOF
LOG=$(mktemp /tmp/tuinav_l4_XXXXXX)
if run_pin "$FRAMES" "Los Angeles" "$LOG"; then
	bad "pin must fail when surflare status shows a different node"
else
	ok "pin fails on status/node mismatch"
fi
steps_is 1 "walked to the target row before the failed connect"
rm -f "$FRAMES" "$LOG"

# --------------------------------------------------------------------
echo "== T5: injection -- drop the screen-read (blind fixed steps) and the tests must catch it =="

INJ=$(mktemp -d /tmp/tuinav_inj_XXXXXX)
SANDBOXES+=("$INJ")
cp "$SUP" "$INJ/sup.sh"
# Restore the OLD buggy behavior: fixed 2 arrows, no screen reading.
python3 - "$INJ/sup.sh" << 'PYEOF'
import sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
old_loop = '''\twhile :; do
\t\trow=$(_cursor_row)
\t\tcase "$row" in
\t\t\t*"$DED_NODE"*) break ;;
\t\tesac
\t\t[ "$steps" -ge "$MAX_STEPS" ] && return 1
\t\tsexpect -s "$SOCK" send -c "\\x1b[B"
\t\tsteps=$((steps + 1))
\t\tsleep 0.6
\tdone'''
new_loop = '''\twhile :; do
\t\trow=$(_cursor_row)
\t\t[ "$steps" -ge 2 ] && break
\t\tsexpect -s "$SOCK" send -c "\\x1b[B"
\t\tsteps=$((steps + 1))
\t\tsleep 0.6
\tdone'''
if old_loop not in src:
	print("INJECTION_ANCHOR_NOT_FOUND")
	sys.exit(1)
open(p, "w", encoding="utf-8").write(src.replace(old_loop, new_loop))
print("INJECTED")
PYEOF
if [ $? -eq 0 ] && grep -q 'steps" -ge 2 ] && break' "$INJ/sup.sh"; then
	ok "injection landed (blind 2-step loop restored)"
else
	bad "injection failed to land"
fi

# Drive the injected function with T1's frames: blind 2 steps lands on
# the old-Verizon row (row 3 of 5), status then mismatches AND the
# step count (2) betrays the blind walk.
FRAMES=$(mktemp /tmp/tuinav_f5_XXXXXX)
cat > "$FRAMES" << 'EOF'
  ▸ ← 返回
  ▸ ↺ 刷新服务器列表
  ▸ 🇺🇸 Washington(65.195.35.200)
  ▸ 🇺🇸 United States(12.104.10.184)AT&T
  ▸ 🇺🇸 United States(12.104.12.149)AT&T
EOF
LOG=$(mktemp /tmp/tuinav_l5_XXXXXX)
if run_pin "$FRAMES" "Washington(65.195.35.200)" "$LOG" "$INJ/sup.sh"; then
	bad "blind 2-step injection CONNECTED to old Verizon"
else
	ok "blind 2-step injection: pin fails via status mismatch"
fi
inj_steps=$(last_steps)
if [ -n "$inj_steps" ] && [ "$inj_steps" != "4" ]; then
	ok "injected walk took $inj_steps steps (not 4) -- step-count assert has teeth"
else
	bad "injected walk reported 4 steps; step assert is blind"
fi
rm -f "$FRAMES" "$LOG"

# --------------------------------------------------------------------
echo "== T6: redraw flash -- target row appears then the marker moves off; settle re-read must fail the pin =="

# Redraw-lag model (AFTER_MATCH_LAG=1): when the frame appended by the
# last keypress carries the target node, the stub appends ONE more row
# 1s later -- after the loop's 0.6s read window (so the loop breaks on
# the flash row) but before the settle re-read. The settle re-read must
# catch the move and fail the pin without sending Enter.
AFTER_MATCH_LAG=1
FRAMES=$(mktemp /tmp/tuinav_f6_XXXXXX)
cat > "$FRAMES" << 'EOF'
  ▸ ← 返回
  ▸ ↺ 刷新服务器列表
  ▸ 🇺🇸 United States(12.104.12.149)AT&T
  ▸ 🇺🇸 Recommended
EOF
LOG=$(mktemp /tmp/tuinav_l6_XXXXXX)
if run_pin "$FRAMES" "United States(12.104.12.149)AT&T" "$LOG"; then
	bad "pin must FAIL when the cursor marker moves off the target after the flash"
else
	ok "settle re-read catches the redraw flash (no blind Enter)"
fi
enters=$(last_enters)
# The pin always sends ONE Enter to open the server-selection menu;
# the connect Enter is a second one. Guarded flash: exactly 1 (menu
# only -- the settle re-read stopped the connect).
if [ -n "$enters" ] && [ "$enters" = "1" ]; then
	ok "no connect Enter on the flash scenario (menu Enter only)"
else
	bad "flash scenario Enter count: ${enters:-none} (expected 1, menu only)"
fi
rm -f "$FRAMES" "$LOG"
AFTER_MATCH_LAG=""

# Injection: drop the settle re-read; the same flash scenario must
# then wrongly connect -- proving the guard is load-bearing.
INJ2=$(mktemp -d /tmp/tuinav_inj2_XXXXXX)
SANDBOXES+=("$INJ2")
cp "$SUP" "$INJ2/sup.sh"
python3 - "$INJ2/sup.sh" << 'PYEOF'
import sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
old_settle = '''	sleep 1
	case "$(_cursor_row)" in
		*"$DED_NODE"*) ;;
		*) return 1 ;;
	esac

'''
if old_settle not in src:
	print("INJECTION_ANCHOR_NOT_FOUND")
	sys.exit(1)
open(p, "w", encoding="utf-8").write(src.replace(old_settle, ""))
print("INJECTED")
PYEOF
if [ $? -eq 0 ] && ! grep -qF 'case "$(_cursor_row)"' "$INJ2/sup.sh"; then
	ok "settle-injection landed (re-read guard removed)"
else
	bad "settle-injection failed to land"
fi
AFTER_MATCH_LAG=1
FRAMES=$(mktemp /tmp/tuinav_f7_XXXXXX)
cat > "$FRAMES" << 'EOF'
  ▸ ← 返回
  ▸ ↺ 刷新服务器列表
  ▸ 🇺🇸 United States(12.104.12.149)AT&T
  ▸ 🇺🇸 Recommended
EOF
LOG=$(mktemp /tmp/tuinav_l7_XXXXXX)
if run_pin "$FRAMES" "Recommended" "$LOG" "$INJ2/sup.sh"; then
	bad "without the settle re-read the flash scenario connects blind -- guard is load-bearing"
else
	ok "settle injection caught: pin fails (blind Enter landed on Recommended, status grep caught it)"
fi
enters=$(last_enters)
if [ -n "$enters" ] && [ "$enters" = "2" ]; then
	ok "injected run sent the blind connect Enter (guard was the only thing stopping it)"
else
	bad "injected run Enter count: ${enters:-none} (expected 2: menu + blind connect)"
fi
rm -f "$FRAMES" "$LOG"
AFTER_MATCH_LAG=""

# --------------------------------------------------------------------
echo
echo "Results: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 1
