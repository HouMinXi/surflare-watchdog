---
phase: 02-cleanup-ops-hardening
plan: 03
status: complete
commit: a6bd495
---

## Summary

Created scripts/surflare_deploy.sh -- safe deploy wrapper for N100 watchdog
with syntax validation, .prev backup, user confirmation gate, and auto-rollback
on crash within 30s.

## Tasks Completed

1. **OPS-01 + OPS-05**: Created 83-line deploy script with:
   - bash -n local syntax check before deploy
   - scp to .new with failure check (|| exit 1)
   - .prev backup before atomic mv (first-run guard if no prior version)
   - User confirmation prompt (local read -p, not SSH)
   - Rollback on user abort (mv .prev back)
   - 30s crash check via PID file kill -0 (not pgrep)
   - Auto-rollback on crash if .prev exists
   - bypass-macs.conf excluded by design (scp single-file)

## Verification

- bash -n passes on deploy script
- grep confirms: bash -n, read -p, .prev, REMOTE_WATCHDOG, surflare_watchdog.pid
- shellcheck: 5x SC2029 info (intentional client-side expansion of constants)
- Non-ASCII check: PASS
