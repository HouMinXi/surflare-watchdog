---
phase: 02-cleanup-ops-hardening
plan: 01
status: complete
commit: 7e2d06a (urltest comment, combined with 02-02)
---

## Summary

N100 operational config changes completed: orphan files deleted, sysupgrade.conf
populated with 14 surflare paths, log buffer increased from 1024 to 4096, cron
watchdog-of-watchdog installed with anchored pgrep pattern, urltest comment
clarified in surflare_watchdog.sh.

## Tasks Completed

1. **SEC-03**: Deleted /usr/local/lib/surflare_watchdog.sh (171KB) and
   /etc/init.d/surflare-watchdog.bak from N100
2. **OPS-03**: Populated /etc/sysupgrade.conf with 14 surflare file paths
   (15 entries including comment line); excludes surflare-proxy binary
3. **OPS-04**: uci set system.@system[0].log_size=4096, committed, log restarted
4. **OPS-02**: Cron entry `*/5 * * * * pgrep -f 'surflare_watchdog\.sh$'` with
   anchored pattern to prevent cron shell self-match
5. **DOC-01**: Added urltest clarification comment before 503 storm detection block

## Verification

All 5 tasks verified via SSH to N100 (192.168.100.1):
- Task 1: `test ! -f` confirms both files absent
- Task 2: grep confirms watchdog path + /etc/surflare/ present, 15 surflare entries
- Task 3: `uci get` returns 4096
- Task 4: `crontab -l | grep surflare_watchdog` returns anchored entry
- Task 5: `grep 'urltest.*sing-box subscription'` matches in surflare_watchdog.sh
