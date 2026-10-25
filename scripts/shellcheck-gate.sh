#!/bin/sh
# Lint every shell file this repository ships.
#
# The old gate was `git ls-files '*.sh'`, which quietly skipped the procd init
# scripts and the hotplug hook -- the files that run as root on every boot.  A
# typo there (an empty assignment where 1 was meant) passed that gate for a week.
#
# Selection is by shebang, not by suffix, and only for files this tree installs:
# the vendored copies under router/services (smartdns, early-detector) are
# third-party and are not ours to fix.
set -u
cd "$(dirname "$0")/.." || exit 2

list=scripts/installed-files.list
[ -f "$list" ] || { echo "FATAL: $list missing" >&2; exit 2; }

installed=$(grep -v '^#' "$list" | grep -v '^$' | cut -d: -f1 | sed 's|@MODE@|rule|')

files=$(git ls-files | while IFS= read -r f; do
	case "$f" in
	*.sh) echo "$f" ;;
	*)
		printf '%s\n' "$installed" | grep -qxF "$f" || continue
		head -1 "$f" 2>/dev/null | grep -qE '^#!.*\b(ba|da|k)?sh\b' && echo "$f"
		;;
	esac
done)

[ -n "$files" ] || { echo "FATAL: no shell files found" >&2; exit 2; }

# shellcheck disable=SC2086  # one path per word, from a newline-separated list
if out=$(shellcheck -S warning -f gcc $files 2>&1); then
	echo "RESULT: $(printf '%s\n' "$files" | wc -l) shell files clean at warning level"
	exit 0
fi
printf '%s\n' "$out"
exit 1
