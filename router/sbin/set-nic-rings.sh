#!/bin/sh
# Persist the larger rings: ethtool -G does not survive a reboot or an
# interface bounce, and the driver default of 256 costs bursts.
#
# The log names the ports that took the setting. Saying "eth0-eth3" after a
# port refused it, or was not there, is how a failed apply reads as a success.
NET=${NET:-/sys/class/net}
# ethtool -G exits non-zero when the ring is already the requested size
# ("rx unmodified, ignoring"), so the exit code cannot tell a refusal from a
# no-op. Read the current RX back; that is the only thing that says whether
# the port is at 4096.
ring_rx() {
	ethtool -g "$1" 2>/dev/null | awk '/^Current hardware/{f=1} f && /^RX:/{print $2; exit}'
}
set=0
missed=""
for i in eth0 eth1 eth2 eth3; do
	[ -e "$NET/$i" ] || { missed="$missed $i"; continue; }
	ethtool -G "$i" rx 4096 tx 4096 >/dev/null 2>&1
	if [ "$(ring_rx "$i")" = "4096" ]; then
		set=$((set + 1))
	else
		missed="$missed $i"
	fi
done
if [ "$set" -eq 4 ]; then
	logger -t ring-size "rings set to 4096 on eth0 eth1 eth2 eth3"
elif [ "$set" -gt 0 ]; then
	logger -t ring-size "rings set to 4096 on $set of 4; refused:$missed"
else
	logger -t ring-size "rings not set; refused:$missed"
fi
