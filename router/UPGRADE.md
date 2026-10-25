# Upgrading the router across a major version

A reboot keeps everything. A minor sysupgrade keeps what `/etc/sysupgrade.conf`
and `/lib/upgrade/keep.d/*` name. A major version jump is usually flashed clean,
and then every file this repository owns has to be put back deliberately. This
is the order that was verified on 2026-10-25, written down because the day of
the upgrade is the worst day to rediscover it.

## Before flashing

1. `scripts/surflare_upgrade_audit.sh` -- every installed file must read
   `kept`. Anything reading `WOULD-BE-LOST` disappears.
2. `scripts/capture_surflare_config.sh` -- snapshot the live config. The tree
   is the source of truth for the files it installs; it is not a backup of
   `/etc/config/network`, `/etc/config/sqm` or `/etc/smartdns`.
3. Note the current values so the comparison after the flash means something:

   ```sh
   . /etc/openwrt_release; echo "$DISTRIB_DESCRIPTION"
   uname -r
   cat /sys/class/net/eth0/queues/rx-0/rps_cpus
   sysctl -n net.core.netdev_max_backlog
   uci get network.@globals[0].packet_steering
   ```

## After flashing

1. `scripts/surflare_reinstall_router.sh` -- installs all fourteen files at
   their destinations with their modes, enables both init scripts, restores the
   cron entry and the sysupgrade keep entries, applies the backlog and asserts
   the receive spread.
2. `scripts/surflare_drift_check.sh` -- every file must read `match`.
3. `scripts/surflare_upgrade_audit.sh` -- the new box must keep them next time.
4. Health: `/etc/init.d/surflare-watchdog status`, `nft list tables`,
   `netstat -ltn | grep 10800`, egress country, `dmesg | grep -i error`.

## What a major jump changes that a minor one does not

- **The packet steering implementation.** With `packet_steering=0` the 24.10
  script takes a do-nothing branch and writes no queues, which is why our value
  survives interface events. A later version may write zeros unconditionally.
  The tell is the frequency of `re-asserted` lines:

  ```sh
  logread | grep -c 'rps-wan: re-asserted'
  ```

  A handful per day is a driver reset. One after every link event means the
  steering script now clears our value and the re-assert is doing all the work.
- **Interface names and queue counts.** RPS is addressed as
  `/sys/class/net/eth0/queues/rx-0`; a renamed port or a different queue layout
  makes the assert a silent no-op. It already exits quietly when the path is
  missing, so check the value, not the exit code.
- **Kernel and driver.** A new igc build may reset the queue attributes more or
  less often than 6.6.144 does. `/sys/class/net/eth0/carrier_changes` and the
  re-assert count together describe how often the setting is lost.
- **The binaries we ship.** `/usr/bin/surflare-proxy.real` is a static Go
  binary (`ldd` reports "Not a valid dynamic program"), so a musl or OpenSSL
  bump does not break it. `/usr/bin/surflare` and the scripts in
  `/usr/local/sbin` are shell, so a busybox change can.

## The one check that only this window provides

The receive spread has never been observed coming back on its own at boot: the
box has been up since 18 October and the hook was written on the 25th. The
first boot after the upgrade is the first chance to see it. Read
`/sys/class/net/eth0/queues/rx-0/rps_cpus` and
`logread | grep rps-wan` immediately after the box comes up, before the cron
entry can hide the answer.
