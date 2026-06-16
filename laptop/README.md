# Laptop Deployment (Fedora / RHEL / systemd)

Scripts and service files for Fedora, RHEL, or any systemd-based distribution.

## Files

| File | Purpose |
|------|---------|
| `surflare_early_detector.sh` | TCP degradation sensor via `ss` cwnd/rto/backoff. Sends SIGUSR1 to watchdog. Requires NetworkManager (`nm-online`). |
| `surflare_node_probe.sh` | Manual diagnostic probe: L4 RTT, L7 TTFB, exit country, GFW signal analysis. Needs tcpdump + root SO_MARK. |
| `surflare_route_updater.sh` | Updates CN route lists (cn_ipv4.txt, cn_ipv6.txt) from chnroute. |
| `services/systemd/` | systemd units: watchdog, early-detector, route-updater timer, update timer. |
| `services/openrc/` | OpenRC init scripts (Alpine, Gentoo). |
| `services/runit/` | runit service directories (Void Linux). |

## Quick Start

```bash
sudo bash install.sh          # auto-detects systemd
sudo bash setup_auth.sh       # optional: TPM2-backed auth
sudo systemctl start surflare-watchdog surflare-early-detector
```

## Dependencies

```bash
sudo dnf install curl procps-ng nftables util-linux python3
sudo dnf install tcpdump   # optional: for node probe
```

## Platform Notes

- Requires `nm-online` (NetworkManager) for sleep-resume reconnect.
  Falls back to 15s fixed sleep if not available.
- Sleep hook installed at `/etc/systemd/system-sleep/surflare-resume.sh`.
- `surflare_early_detector.sh` monitors surflare TCP connections via `ss -tnp`.

## Update After git pull

```bash
sudo cp laptop/services/systemd/*.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl restart surflare-watchdog
```
