#!/bin/bash
# Host-side inventory gate. shfmt parses shell syntax; no candidate is sourced.
# With no argument, every source that writes nft under the shared lock is
# inventoried against its own enrollment manifest. With one source, its own
# manifest is chosen by name; anything else needs an explicit --manifest.
set -u
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || exit 2
PY="$ROOT/check_nft_locked_writes.py"
if [ "$#" -gt 0 ]; then
	manifest_seen=0
	for arg in "$@"; do
		[ "$arg" = "--manifest" ] && manifest_seen=1
		case "$arg" in --manifest=*) manifest_seen=1 ;; esac
	done
	if [ "$manifest_seen" -eq 1 ]; then
		exec python3 "$PY" "$@"
	fi
	shift_source=$1
	shift
	case "$shift_source" in
	surflare_watchdog.sh)
		exec python3 "$PY" "$shift_source" \
			--manifest "$ROOT/nft-write-sites.json" "$@" ;;
	router/zoro-exit | zoro-exit)
		exec python3 "$PY" "$shift_source" \
			--manifest "$ROOT/nft-write-sites-zoro-exit.json" "$@" ;;
	esac
	printf 'unknown source %s: pass --manifest explicitly\n' "$shift_source" >&2
	exit 2
fi
rc=0
python3 "$PY" surflare_watchdog.sh \
	--manifest "$ROOT/nft-write-sites.json" || rc=$?
python3 "$PY" router/zoro-exit \
	--manifest "$ROOT/nft-write-sites-zoro-exit.json" || rc=$?
exit "$rc"
