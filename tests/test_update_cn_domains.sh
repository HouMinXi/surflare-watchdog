#!/bin/sh
# The daily CN domain-list updater has one job with a failure mode that
# is invisible: it prints "updated: N domains" whether or not the files
# landed.  These cases pin the two places where that can go wrong -- a
# destination directory that does not exist yet, and a move that fails.
set -u
cd "$(dirname "$0")/.." || exit 1

SUT=./router/update-cn-domains.sh
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

mkdir -p "$TMP/bin"
# 5 lines instead of 100 000: MIN_LINES is what the floor is measured with.
cat > "$TMP/src.conf" <<'EOS'
server=/example-cn-a.test/114.114.114.114
server=/example-cn-b.test/114.114.114.114
server=/example-cn-c.test/114.114.114.114
server=/example-cn-d.test/114.114.114.114
server=/example-cn-e.test/114.114.114.114
server=/example-cn-f.test/114.114.114.114/extra
EOS
cat > "$TMP/bin/curl" <<EOS
#!/bin/sh
# curl -sf --max-time 30 URL -o FILE
while [ \$# -gt 0 ]; do
	case "\$1" in -o) shift; out="\$1" ;; esac
	shift
done
cat "$TMP/src.conf" > "\$out"
EOS
cat > "$TMP/bin/logger" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP/logger"
EOS
cat > "$TMP/smartdns-init" <<EOS
#!/bin/sh
echo restarted >> "$TMP/restarts"
EOS
chmod +x "$TMP/bin/curl" "$TMP/bin/logger" "$TMP/smartdns-init"

run() { # $1 = destination directory
	: > "$TMP/logger"
	: > "$TMP/restarts"
	PATH="$TMP/bin:$PATH" DEST_DIR="$1" SMARTDNS_INIT="$TMP/smartdns-init" \
		MIN_LINES=3 sh "$SUT" > "$TMP/out" 2>&1
	echo $?
}

# --- T1: the destination directory does not exist yet ---------------
rc=$(run "$TMP/fresh/domain-set")
if [ "$rc" -eq 0 ] &&
	[ -s "$TMP/fresh/domain-set/cn_domains.conf" ] &&
	[ -s "$TMP/fresh/domain-set/cn_domain_flat.txt" ] &&
	[ "$(wc -l < "$TMP/restarts")" -eq 1 ] &&
	grep -q 'updated: 6 domains installed' "$TMP/logger"; then
	if grep -qx 'example-cn-f.test' "$TMP/fresh/domain-set/cn_domain_flat.txt"; then
		ok "a line with a trailing field yields the domain alone"
	else
		bad "greedy match folded the address into the domain: $(grep example-cn-f "$TMP/fresh/domain-set/cn_domain_flat.txt" 2>/dev/null)"
	fi
	ok "a missing destination directory is created and both files land"
else
	bad "fresh destination: rc=$rc, files=$(find "$TMP/fresh/domain-set" -maxdepth 1 -type f 2>/dev/null | tr '\n' ' '), log=$(cat "$TMP/logger")"
fi

# --- T1b: the local list is counted in what was installed -----------
mkdir -p "$TMP/withlocal"
printf 'local-only.test\n' > "$TMP/withlocal/local-cn.txt"
rc=$(run "$TMP/withlocal")
if [ "$rc" -eq 0 ] && grep -q 'updated: 7 domains installed (6 from felixonmars)' "$TMP/logger"; then
	ok "the log reports installed domains, not just the downloaded count"
else
	bad "installed count not reported honestly: $(cat "$TMP/logger")"
fi

# --- T2: the move fails ---------------------------------------------
# Read-only destination: mkdir -p succeeds (it exists), the mv does not.
mkdir -p "$TMP/ro"
chmod 555 "$TMP/ro"
rc=$(run "$TMP/ro")
chmod 755 "$TMP/ro"
if [ "$rc" -eq 1 ] && grep -q 'cannot install' "$TMP/logger" && ! grep -q 'updated:' "$TMP/logger"; then
	ok "a failed install is reported and does not claim an update"
else
	bad "read-only destination: rc=$rc, log=$(cat "$TMP/logger")"
fi

# --- T3: a short download is refused --------------------------------
: > "$TMP/logger"
PATH="$TMP/bin:$PATH" DEST_DIR="$TMP/t3" SMARTDNS_INIT="$TMP/smartdns-init" \
	MIN_LINES=99 sh "$SUT" > "$TMP/out" 2>&1
rc=$?
if [ "$rc" -eq 1 ] && grep -q 'too few lines' "$TMP/logger" && [ ! -d "$TMP/t3" ]; then
	ok "a truncated download stops before touching the live list"
else
	bad "short download: rc=$rc, log=$(cat "$TMP/logger")"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
