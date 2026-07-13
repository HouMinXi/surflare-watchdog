# Alert Bridge Deployment to X500

## Pre-flight Verification (Task 0)

Before deploying, verify on X500:

```bash
# 1. Discover hermes-agent venv python
VENV_PYTHON=$(ls ~/code/hermes-agent/venv/bin/python3 2>/dev/null || \
    ls ~/code/hermes-agent/.venv/bin/python3 2>/dev/null || \
    which python3)
echo "VENV_PYTHON=${VENV_PYTHON}"

# 2. hermes-agent exists and weixin module is importable
[ -d ~/code/hermes-agent ] || { echo "ABORT: ~/code/hermes-agent not found"; exit 1; }
[ -d ~/code/hermes-agent/gateway/platforms ] || { echo "ABORT: weixin module not found"; exit 1; }
cd ~/code/hermes-agent && "$VENV_PYTHON" -c "from gateway.platforms.weixin import send_weixin_direct; print('OK')"

# 3. send_weixin_direct signature (verify async keyword-only)
grep -n 'def send_weixin_direct' ~/code/hermes-agent/gateway/platforms/weixin.py

# 4. Port 8377 is free
ss -tlnp | grep 8377 && { echo "ABORT: port 8377 in use"; exit 1; }

# 5. python3 version (need >= 3.7)
"$VENV_PYTHON" --version
```

Record `VENV_PYTHON` value -- needed for the systemd service file.

## Deploy Steps (Task 1 + Task 2)

```bash
# 1. Copy files to X500
scp deploy/x500/alert-bridge.py houminxi@192.168.100.10:~/alert-bridge.py
scp deploy/x500/alert-bridge.service houminxi@192.168.100.10:~/.config/systemd/user/alert-bridge.service

# 2. Make executable
ssh houminxi@192.168.100.10 "chmod +x ~/alert-bridge.py"

# 3. Provision credentials (from local machine, from pass store)
WT=$(pass show api/weixin-token | head -1)
WA=$(pass show api/weixin-account-id | head -1)
WC=$(pass show api/weixin-chat-id | head -1)

ssh houminxi@192.168.100.10 "cat > ~/.surflare-bridge-creds << EOF
WEIXIN_TOKEN=${WT}
WEIXIN_ACCOUNT_ID=${WA}
WEIXIN_CHAT_ID=${WC}
EOF
chmod 600 ~/.surflare-bridge-creds"

# 4. Generate shared bridge token
BT=$(openssl rand -hex 16)
echo "$BT" | ssh root@192.168.100.1 "cat > /root/.surflare-bridge-token && chmod 600 /root/.surflare-bridge-token"
echo "$BT" | ssh houminxi@192.168.100.10 "cat > ~/.surflare-bridge-token && chmod 600 ~/.surflare-bridge-token"

# 5. Enable and start service
ssh houminxi@192.168.100.10 "systemctl --user daemon-reload && systemctl --user enable alert-bridge.service && systemctl --user start alert-bridge.service"

# 6. Enable lingering (service starts at boot without login)
ssh houminxi@192.168.100.10 "loginctl enable-linger houminxi"

# 7. Update systemd service ExecStart if VENV_PYTHON differs from /usr/bin/python3
# Edit ~/.config/systemd/user/alert-bridge.service and replace ExecStart path
```

## Verification

```bash
# Health check from X500
ssh houminxi@192.168.100.10 "curl -sf http://192.168.100.10:8377/health"

# Health check from N100
ssh root@192.168.100.1 "curl -sf --max-time 5 http://192.168.100.10:8377/health"

# Test alert from N100 (with bridge token)
BT=$(ssh root@192.168.100.1 "cat /root/.surflare-bridge-token")
ssh root@192.168.100.1 "curl -sf --max-time 5 -X POST http://192.168.100.10:8377/alert -H 'Content-Type: application/json' -H 'X-Bridge-Token: ${BT}' -d '{\"title\":\"test\",\"body\":\"alert-bridge smoke test\"}'"

# Service status
ssh houminxi@192.168.100.10 "systemctl --user status alert-bridge.service"
ssh houminxi@192.168.100.10 "journalctl --user -u alert-bridge --no-pager -n 10"
```
