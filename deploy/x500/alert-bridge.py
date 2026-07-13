#!/usr/bin/env python3
"""Alert bridge: HTTP -> iLink -> WeChat.

Receives POST /alert from surflare-watchdog on N100, forwards to WeChat
via hermes-agent's send_weixin_direct(). Single-threaded (1 alert/10min max).
Authentication via shared token in X-Bridge-Token header.
"""
import asyncio
import json
import os
import sys
import syslog
import time
from http.server import HTTPServer, BaseHTTPRequestHandler

# Load hermes-agent and WeChat credentials
sys.path.insert(0, os.path.expanduser("~/code/hermes-agent"))

# Read WeChat credentials from secure config file (provisioned at deploy time)
_CRED_FILE = os.path.expanduser("~/.surflare-bridge-creds")
try:
    _cred_lines = open(_CRED_FILE).readlines()
except FileNotFoundError:
    syslog.syslog(syslog.LOG_ERR, f"alert-bridge: cred file not found: {_CRED_FILE}")
    _cred_lines = []
for _line in _cred_lines:
    _line = _line.strip()
    if _line and not _line.startswith('#') and '=' in _line:
        _k, _v = _line.split('=', 1)
        os.environ.setdefault(_k.strip(), _v.strip())

# Import at module level -- fails fast on startup if hermes-agent is broken
from gateway.platforms.weixin import send_weixin_direct

START_TIME = time.time()
PORT = 8377

# Shared token for authentication (written by deploy script)
BRIDGE_TOKEN_FILE = os.path.expanduser("~/.surflare-bridge-token")
BRIDGE_TOKEN = ""
if os.path.exists(BRIDGE_TOKEN_FILE):
    with open(BRIDGE_TOKEN_FILE) as f:
        BRIDGE_TOKEN = f.read().strip()

ILINK_AVAILABLE = True  # import succeeded at startup


class AlertHandler(BaseHTTPRequestHandler):
    """Handle POST /alert and GET /health."""

    def do_POST(self):
        if self.path != "/alert":
            self._respond(404, {"status": "error", "message": "not found"})
            return

        # Validate shared token
        if not BRIDGE_TOKEN:
            self._respond(503, {"status": "error", "message": "bridge token not configured"})
            return
        token = self.headers.get("X-Bridge-Token", "")
        if token != BRIDGE_TOKEN:
            self._respond(401, {"status": "error", "message": "invalid token"})
            return

        content_length = int(self.headers.get("Content-Length", 0))
        if content_length == 0:
            self._respond(400, {"status": "error", "message": "empty body"})
            return
        if content_length > 65536:  # 64KB cap
            self._respond(413, {"status": "error", "message": "payload too large"})
            return

        try:
            body = self.rfile.read(content_length)
            data = json.loads(body)
        except (json.JSONDecodeError, ValueError) as exc:
            self._respond(400, {"status": "error", "message": f"invalid JSON: {exc}"})
            return

        title = data.get("title", "").strip()
        msg_body = data.get("body", "").strip()
        metadata = data.get("metadata")

        if not title or not msg_body:
            self._respond(400, {"status": "error", "message": "missing title or body"})
            return

        # Compose WeChat message: title on first line, body below
        content = f"[{title}] {msg_body}"
        if metadata and isinstance(metadata, dict):
            meta_str = " | ".join(f"{k}={v}" for k, v in metadata.items())
            content = f"{content}\n{meta_str}"

        try:
            # send_weixin_direct is async keyword-only, call via asyncio.run()
            result = asyncio.run(send_weixin_direct(
                extra={"account_id": os.environ.get("WEIXIN_ACCOUNT_ID", "")},
                token=os.environ.get("WEIXIN_TOKEN"),
                chat_id=os.environ.get("WEIXIN_CHAT_ID", ""),
                message=content,
            ))
            if "error" in result:
                self._respond(500, {"status": "error", "message": result["error"]})
            else:
                self._respond(200, {"status": "ok"})
        except Exception as exc:
            self._respond(500, {"status": "error", "message": str(exc)})

    def do_GET(self):
        if self.path == "/health":
            uptime = int(time.time() - START_TIME)
            if ILINK_AVAILABLE:
                self._respond(200, {"status": "ok", "uptime_s": uptime})
            else:
                self._respond(503, {"status": "error", "message": "iLink unavailable"})
        else:
            self._respond(404, {"status": "error", "message": "not found"})

    def _respond(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def log_message(self, fmt, *args):
        # Suppress default stderr logging; use syslog instead
        syslog.syslog(syslog.LOG_INFO, f"alert-bridge: {fmt % args}")


def main():
    server = HTTPServer(("192.168.100.10", PORT), AlertHandler)
    print(f"alert-bridge listening on 192.168.100.10:{PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.server_close()


if __name__ == "__main__":
    main()
