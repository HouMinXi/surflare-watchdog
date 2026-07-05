#!/bin/sh
# Daily update of CN domain list from felixonmars/dnsmasq-china-list.
# Converts dnsmasq format to SmartDNS nameserver + flat domain-set.
# Appends local-cn.txt (learned + manual) after felixonmars base.
URL="https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

curl -sf --max-time 30 "$URL" -o "$TMP" || { logger -t cn-domains "download failed"; exit 1; }

LINES=$(wc -l < "$TMP")
[ "$LINES" -gt 100000 ] || { logger -t cn-domains "too few lines: $LINES"; exit 1; }

CONF_TMP=$(mktemp)
FLAT_TMP=$(mktemp)
trap 'rm -f "$TMP" "$CONF_TMP" "$FLAT_TMP"' EXIT

sed "s|^server=/\(.*\)/.*|nameserver /\1/domestic|" "$TMP" > "$CONF_TMP"
sed "s|^server=/\(.*\)/.*|\1|" "$TMP" > "$FLAT_TMP"

[ -f /etc/smartdns/domain-set/local-cn.txt ] && {
    while read -r d; do
        [ -n "$d" ] && {
            echo "nameserver /$d/domestic" >> "$CONF_TMP"
            echo "$d" >> "$FLAT_TMP"
        }
    done < /etc/smartdns/domain-set/local-cn.txt
}

mv "$CONF_TMP" /etc/smartdns/domain-set/cn_domains.conf
mv "$FLAT_TMP" /etc/smartdns/domain-set/cn_domain_flat.txt
/etc/init.d/smartdns restart
logger -t cn-domains "updated: $LINES domains from felixonmars"
