#!/bin/sh
# Learn CN domains from SmartDNS audit log during VPN-up.
# Parses audit CSV, checks if result IPs are in CN CIDRs,
# adds unknown CN domains to local-cn.txt.
# Safety: only learns during VPN-up (foreign DNS via VPN, not GFW-poisoned).
# Limitation: IPv4-only. N100 has force-AAAA-SOA=yes (no IPv6 DNS results).
# If IPv6 is enabled in the future, add IPv6 CIDR matching here.
[ -f /var/log/smartdns-audit.csv ] || exit 0
[ -f /etc/surflare/cn_ipv4.txt ] || exit 0

python3 << 'PYEOF'
import ipaddress, os, re

AUDIT = os.environ.get("AUDIT", "/var/log/smartdns-audit.csv")
LOCAL = os.environ.get("LOCAL", "/etc/smartdns/domain-set/local-cn.txt")
CN_LIST = os.environ.get("CN_LIST", "/etc/smartdns/domain-set/cn_domains.conf")
CN_CIDRS = os.environ.get("CN_CIDRS", "/etc/surflare/cn_ipv4.txt")
EXTRA_CIDRS = os.environ.get("EXTRA_CIDRS", "/etc/surflare/cn_ipv4_extra.txt")

nets = []
for f in [CN_CIDRS, EXTRA_CIDRS]:
    try:
        with open(f) as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#"):
                    try:
                        nets.append(ipaddress.ip_network(line, strict=False))
                    except ValueError:
                        pass
    except FileNotFoundError:
        pass

known = set()
for f in [CN_LIST, LOCAL]:
    try:
        with open(f) as fh:
            for line in fh:
                m = re.search(r"/([^/]+)/|^([a-z0-9][\w.-]+)$", line.strip())
                if m:
                    known.add(m.group(1) or m.group(2))
    except FileNotFoundError:
        pass

learned = set()
with open(AUDIT) as fh:
    for line in fh:
        m = re.match(
            r"\[.*?\]\s+\S+\s+query\s+(\S+),.*?result\s+(\d+\.\d+\.\d+\.\d+)",
            line,
        )
        if not m:
            continue
        domain, ip_str = m.group(1), m.group(2)
        if domain in known or domain in learned:
            continue
        try:
            ip = ipaddress.ip_address(ip_str)
            if any(ip in net for net in nets):
                learned.add(domain)
        except ValueError:
            pass

if learned:
    with open(LOCAL, "a") as fh:
        for d in sorted(learned):
            fh.write(d + "\n")
    sample = ", ".join(sorted(learned)[:5])
    print(f"learned {len(learned)} CN domains: {sample}")
else:
    print("no new CN domains found")
PYEOF

# Truncate audit log after processing (keep last 100 lines for next run)
tail -100 /var/log/smartdns-audit.csv > /var/log/smartdns-audit.csv.tmp && \
    mv /var/log/smartdns-audit.csv.tmp /var/log/smartdns-audit.csv
