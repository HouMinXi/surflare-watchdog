#!/bin/sh
# Drop leftover init scripts that procd would otherwise scan.
#
# /etc/init.d is not a backup directory. A file there named
# surflare-dedicated.bak-<date> still has START= and a shebang procd
# understands, so enable, or an upgrade that re-reads the directory, starts
# the old service beside the current one. The live script has no .bak in its
# name; only the dated copies go.
#
# Usage: surflare_drop_init_backups.sh [--remote HOST] [--dir DIR] [--dry-run]
# Exit: 0 the directory has no .bak init scripts, 1 a removal failed, 2 bad use.
set -u

REMOTE="${REMOTE:-root@192.168.100.1}"
DIR="${DIR:-/etc/init.d}"
SSH_CMD="${SSH_CMD:-ssh}"
DRY=""

while [ $# -gt 0 ]; do
	case "$1" in
	--remote)
		[ $# -ge 2 ] || { echo "usage: $0 [--remote HOST] [--dir DIR] [--dry-run]" >&2; exit 2; }
		REMOTE="$2"; shift 2 ;;
	--dir)
		[ $# -ge 2 ] || { echo "usage: $0 [--remote HOST] [--dir DIR] [--dry-run]" >&2; exit 2; }
		DIR="$2"; shift 2 ;;
	--dry-run) DRY=1; shift ;;
	*) echo "usage: $0 [--remote HOST] [--dir DIR] [--dry-run]" >&2; exit 2 ;;
	esac
done

# Only a name with .bak- in it, and only inside the directory we were given.
# A glob that is not anchored there would match a live script whose name
# happens to contain those letters somewhere else.
# Dropbear concatenates "ssh host cmd arg" back into one string, so a
# positional argument never arrives as $1 on the router. OpenSSH would pass
# it. The directory and the dry flag are therefore written into the command
# the remote shell runs, and the directory is refused unless it is a plain
# path: a space or a quote in it would change what that command means.
case "$DIR" in
*[!A-Za-z0-9/_.-]*)
	echo "refusing directory name: $DIR" >&2
	exit 2
	;;
esac

remote=$(cat <<REMOTE
d="$DIR"
dry="$DRY"
found=0
for f in "\$d"/*.bak-*; do
	[ -f "\$f" ] || continue
	found=\$((found + 1))
	if [ "\$dry" = "1" ]; then
		echo "would remove \$f"
		continue
	fi
	rm -f "\$f" || { echo "FAILED: \$f" >&2; exit 1; }
	echo "removed \$f"
done
echo "RESULT: \$found backup init scripts"
exit 0
REMOTE
)

# shellcheck disable=SC2086
$SSH_CMD -n "$REMOTE" "$remote"
