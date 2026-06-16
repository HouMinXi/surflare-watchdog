#!/bin/bash
# Weekly CN domain list update for SmartDNS
set -e
DEST="/etc/smartdns/domain-set/cn_domains.conf"
TMP="/tmp/cn_domains_new.conf"
URL="https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf"
MIRROR="https://cdn.jsdelivr.net/gh/felixonmars/dnsmasq-china-list@master/accelerated-domains.china.conf"

log() { logger -t cn-domains-update "$*"; }

# Download (primary then mirror)
if ! curl -sf --connect-timeout 15 --max-time 60 "$URL" -o /tmp/raw.conf 2>/dev/null; then
    log "github failed, trying mirror..."
    curl -sf --connect-timeout 15 --max-time 60 "$MIRROR" -o /tmp/raw.conf || {
        log "ERROR: both sources failed"; exit 1; }
fi

# Sanity check
COUNT=$(wc -l < /tmp/raw.conf)
[ "$COUNT" -lt 50000 ] && { log "ERROR: only $COUNT lines"; exit 1; }

# Convert: server=/domain/ip -> nameserver /domain/domestic
python3 -c "
import sys
with open('/tmp/raw.conf') as f:
    for line in f:
        line = line.strip()
        if line.startswith('server=/'):
            parts = line[8:].rsplit('/', 1)
            print('nameserver /' + parts[0] + '/domestic')
" > "$TMP"

NEW_COUNT=$(wc -l < "$TMP")
[ "$NEW_COUNT" -lt 50000 ] && { log "ERROR: only $NEW_COUNT converted"; exit 1; }

mv "$TMP" "$DEST"
rm -f /tmp/raw.conf

# Reload SmartDNS gracefully


log "updated: $NEW_COUNT domains"
# Reload: restart SmartDNS (this version does not support graceful reload)
/etc/init.d/smartdns restart
