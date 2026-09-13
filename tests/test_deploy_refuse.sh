#!/usr/bin/env bash
# T15 unit level for the deploy refuse gate (I10): _live_cfg_guard must
# refuse when local NODE=/TRANSIT= differ from live, unless --force, and
# --force still prompts.  Sources the real script (BASH_SOURCE guard
# keeps main from running).  Last block neuters the guard in a copy to
# prove the refusal comes from that code, not from the test itself.
set -u
cd "$(dirname "$0")/.."
DEPLOY="scripts/surflare_deploy.sh"
fail=0

ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# shellcheck source=scripts/surflare_deploy.sh
source "$DEPLOY"

A="$(printf 'NODE="x"\nTRANSIT="y"')"
B="$(printf 'NODE="u"\nTRANSIT="v"')"

if _live_cfg_guard "$A" "$A" 0 2>/dev/null; then
    ok "equal cfg passes"
else
    bad "equal cfg refused"
fi

if _live_cfg_guard "$A" "$B" 0 2>/dev/null; then
    bad "differ accepted without --force"
else
    ok "differ refused without --force"
fi

if printf 'n\n' | _live_cfg_guard "$A" "$B" 1 2>/dev/null; then
    bad "--force + answer n accepted"
else
    ok "--force + answer n refused"
fi

if printf 'y\n' | _live_cfg_guard "$A" "$B" 1 2>/dev/null; then
    ok "--force + answer y accepted"
else
    bad "--force + answer y refused"
fi

# _cfg_vals: strips trailing comments, keeps quotes, tolerates missing lines
FIX="$(mktemp)"
trap 'rm -f "$FIX"' EXIT
printf 'NODE="x"    # soak pin, do not revert\nTRANSIT="y"\n' > "$FIX"
V="$(_cfg_vals "$FIX")"
[ "$V" = "$A" ] && ok "_cfg_vals strips comments" || bad "_cfg_vals comment strip: [$V]"

printf 'TRANSIT="y"\n' > "$FIX"
V="$(_cfg_vals "$FIX")"
[ "$V" = 'TRANSIT="y"' ] && ok "_cfg_vals missing NODE tolerated" || bad "_cfg_vals missing NODE: [$V]"

# Injection: neuter the equality short-circuit in a COPY; the differ case
# must then be accepted.  Proves the refusal above comes from the guard.
NEUT="$(mktemp --suffix=.sh)"
python3 - "$DEPLOY" "$NEUT" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
needle = '[ "$1" = "$2" ] && return 0'
assert needle in text, "guard line not found; injection target drifted"
open(dst, "w", encoding="utf-8").write(text.replace(needle, "return 0  # INJECTED", 1))
PYEOF
if [ ! -s "$NEUT" ]; then
    bad "injection copy not produced"
elif (
        # shellcheck disable=SC1090
        source "$NEUT"
        _live_cfg_guard "X" "Y" 0 2>/dev/null
    ); then
    ok "injection (guard neutered) accepts differ -- teeth proven"
else
    bad "neutered guard still refuses; injection ineffective"
fi
rm -f "$NEUT"

bash -n "$DEPLOY" && ok "bash -n deploy" || bad "bash -n deploy"

exit "$fail"
