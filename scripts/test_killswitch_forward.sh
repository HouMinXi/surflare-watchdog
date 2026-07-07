#!/usr/bin/env bash
# Killswitch forward chain regression smoke test.
# Runs from repo host via SSH to N100.  Read-only (nft list only).
# Exit 0 = all checks pass, exit 1 = any check fails.
set -euo pipefail

N100="root@192.168.100.1"
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 $N100"
FAIL=0

check() {
	if ! $SSH "$1" >/dev/null 2>&1; then
		echo "FAIL: $2"
		FAIL=1
	else
		echo "OK: $2"
	fi
}

echo "=== Killswitch forward chain smoke test ==="

# 1. killswitch table exists
check "nft list table inet killswitch >/dev/null 2>&1" \
	"killswitch table exists"

# 2. forward chain with policy accept (implicit block via reject rule at end)
check "nft list chain inet killswitch forward 2>/dev/null | grep -q 'policy accept'" \
	"forward chain policy accept"

# 3. LAN reject rule (implicit block at chain end)
# Both IPv4 and IPv6 reject rules may exist; matching either is correct.
check "nft list chain inet killswitch forward 2>/dev/null | grep -q 'br-lan.*reject'" \
	"LAN reject rule (implicit block)"

# 4. server_ips accept rule
check "nft list chain inet killswitch forward 2>/dev/null | grep -q '@server_ips'" \
	"server_ips accept rule"

# 5. bypass_ipv4 set non-empty (at least one entry)
check "nft list set inet killswitch bypass_ipv4 2>/dev/null | grep -qE '[0-9]+\.[0-9]'" \
	"bypass_ipv4 non-empty"

# 6. output chain mark 0x1 accept (VPN-routed traffic)
check "nft list chain inet killswitch output 2>/dev/null | grep -q 'mark 0x00000001'" \
	"output mark 0x1 accept"

# 7. output chain mark 0xff accept (direct outbound: relay, DNS)
check "nft list chain inet killswitch output 2>/dev/null | grep -q 'mark 0x000000ff'" \
	"output mark 0xff accept"

echo "=== Done: $((7 - FAIL))/7 passed ==="
exit $FAIL
