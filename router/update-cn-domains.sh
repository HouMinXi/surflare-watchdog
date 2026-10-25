#!/bin/sh
# Daily update of CN domain list from felixonmars/dnsmasq-china-list.
# Converts dnsmasq format to SmartDNS nameserver + flat domain-set.
# Appends local-cn.txt (learned + manual) after felixonmars base.
URL="${URL:-https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf}"
DEST_DIR="${DEST_DIR:-/etc/smartdns/domain-set}"
SMARTDNS_INIT="${SMARTDNS_INIT:-/etc/init.d/smartdns}"
MIN_LINES="${MIN_LINES:-100000}"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

curl -sf --max-time 30 "$URL" -o "$TMP" || { logger -t cn-domains "download failed"; exit 1; }

LINES=$(wc -l < "$TMP")
[ "$LINES" -gt "$MIN_LINES" ] || { logger -t cn-domains "too few lines: $LINES"; exit 1; }

CONF_TMP=$(mktemp)
FLAT_TMP=$(mktemp)
trap 'rm -f "$TMP" "$CONF_TMP" "$FLAT_TMP"' EXIT

sed "s|^server=/\([^/]*\)/.*|nameserver /\1/domestic|" "$TMP" > "$CONF_TMP"
sed "s|^server=/\([^/]*\)/.*|\1|" "$TMP" > "$FLAT_TMP"

[ -f "$DEST_DIR/local-cn.txt" ] && {
    while read -r d; do
        [ -n "$d" ] && {
            echo "nameserver /$d/domestic" >> "$CONF_TMP"
            echo "$d" >> "$FLAT_TMP"
        }
    done < "$DEST_DIR/local-cn.txt"
}

# The destination is not guaranteed to exist: a freshly restored system
# has the package but not necessarily the directory, and this script is
# what creates the two files in it.  Both moves are checked -- an
# unchecked failure here still reached the "updated: N domains" line,
# so the log claimed an update that had not happened.
mkdir -p "$DEST_DIR" || { logger -t cn-domains "cannot create $DEST_DIR"; exit 1; }
mv "$CONF_TMP" "$DEST_DIR/cn_domains.conf" || { logger -t cn-domains "cannot install cn_domains.conf"; exit 1; }
mv "$FLAT_TMP" "$DEST_DIR/cn_domain_flat.txt" || { logger -t cn-domains "cannot install cn_domain_flat.txt"; exit 1; }
"$SMARTDNS_INIT" restart
# Report what was installed, not what was downloaded: local-cn.txt adds
# rows on top of the source list, so the raw count understates the file.
INSTALLED=$(wc -l < "$DEST_DIR/cn_domain_flat.txt")
logger -t cn-domains "updated: $INSTALLED domains installed ($LINES from felixonmars)"
