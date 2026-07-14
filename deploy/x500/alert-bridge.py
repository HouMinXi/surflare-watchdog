#!/usr/bin/env python3
"""Alert bridge: HTTP -> hermes-gateway -> WeChat.

Receives POST /alert from surflare-watchdog on N100, forwards to WeChat
via hermes-gateway's /api/weixin/send endpoint.  Single-threaded (1 alert/
10min max).  Authentication via shared token in X-Bridge-Token header.

Credential file ~/.surflare-bridge-creds needs:
    GATEWAY_URL=http://127.0.0.1:8642
    GATEWAY_API_KEY=<API_SERVER_KEY from hermes-gateway config>
    WEIXIN_CHAT_ID=o9cq802aJqdIFExlaxuOBPT8OjHY@im.wechat
"""
import http.client
import json
import os
import signal
import hmac
import syslog
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

# Load credentials from secure config file (provisioned at deploy time)
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

START_TIME = time.time()
PORT = 8377

# hermes-gateway connection settings
GATEWAY_URL = os.environ.get("GATEWAY_URL", "http://127.0.0.1:8642")
GATEWAY_API_KEY = os.environ.get("GATEWAY_API_KEY", "")
WEIXIN_CHAT_ID = os.environ.get("WEIXIN_CHAT_ID", "")

# Shared token for incoming alert authentication
BRIDGE_TOKEN_FILE = os.path.expanduser("~/.surflare-bridge-token")
BRIDGE_TOKEN = ""
if os.path.exists(BRIDGE_TOKEN_FILE):
    with open(BRIDGE_TOKEN_FILE) as f:
        BRIDGE_TOKEN = f.read().strip()

# Graceful shutdown flag
_shutdown = False


def _verify_token(provided: str) -> bool:
    """Constant-time token comparison to prevent timing attacks."""
    if not BRIDGE_TOKEN:
        return False
    return hmac.compare_digest(provided.encode(), BRIDGE_TOKEN.encode())


def send_via_gateway(message: str) -> dict:
    """Send a WeChat message via hermes-gateway's HTTP API.

    Returns {"success": True} on success, {"success": False, "error": "..."}
    on failure.
    """
    parsed = urlparse(GATEWAY_URL)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 8642

    payload = json.dumps({
        "chat_id": WEIXIN_CHAT_ID,
        "message": message,
    }).encode("utf-8")

    headers = {
        "Content-Type": "application/json; charset=utf-8",
        "Content-Length": str(len(payload)),
    }
    if GATEWAY_API_KEY:
        headers["Authorization"] = f"Bearer {GATEWAY_API_KEY}"

    conn = None
    try:
        conn = http.client.HTTPConnection(host, port, timeout=30)
        conn.request("POST", "/api/weixin/send", body=payload, headers=headers)
        resp = conn.getresponse()
        raw = resp.read().decode("utf-8")
        data = json.loads(raw)
        if resp.status == 200 and data.get("success"):
            return {"success": True}
        return {
            "success": False,
            "error": data.get("error", f"HTTP {resp.status}"),
        }
    except http.client.HTTPException as exc:
        return {"success": False, "error": f"HTTP error: {exc}"}
    except ConnectionRefusedError:
        return {"success": False, "error": "gateway not reachable (connection refused)"}
    except TimeoutError:
        return {"success": False, "error": "gateway timeout (30s)"}
    except OSError as exc:
        return {"success": False, "error": f"network error: {exc}"}
    except (json.JSONDecodeError, ValueError) as exc:
        return {"success": False, "error": f"invalid response: {exc}"}
    finally:
        if conn is not None:
            try:
                conn.close()
            except OSError:
                pass


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
        if not _verify_token(token):
            self._respond(401, {"status": "error", "message": "invalid token"})
            return

        content_length = int(self.headers.get("Content-Length", 0))
        if content_length < 0:
            self._respond(400, {"status": "error", "message": "invalid Content-Length"})
            return
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

        if not GATEWAY_URL:
            self._respond(503, {"status": "error", "message": "GATEWAY_URL not configured"})
            return

        result = send_via_gateway(content)
        if result.get("success"):
            syslog.syslog(syslog.LOG_INFO, f"alert-bridge: sent alert title={title!r}")
            self._respond(200, {"status": "ok"})
        else:
            syslog.syslog(syslog.LOG_ERR, f"alert-bridge: send failed: {result.get('error')}")
            self._respond(502, {"status": "error", "message": result.get("error", "unknown")})

    def do_GET(self):
        if self.path == "/health":
            uptime = int(time.time() - START_TIME)
            self._respond(200, {"status": "ok", "uptime_s": uptime})
        else:
            self._respond(404, {"status": "error", "message": "not found"})

    def _respond(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode("utf-8"))

    def log_message(self, fmt, *args):
        # Suppress default stderr logging; use syslog instead
        syslog.syslog(syslog.LOG_INFO, f"alert-bridge: {fmt % args}")


def _handle_sigterm(signum, frame):
    global _shutdown
    _shutdown = True
    syslog.syslog(syslog.LOG_INFO, "alert-bridge: received SIGTERM, shutting down")


def main():
    signal.signal(signal.SIGTERM, _handle_sigterm)
    signal.signal(signal.SIGINT, _handle_sigterm)

    server = HTTPServer(("192.168.100.10", PORT), AlertHandler)
    server.timeout = 1  # 1s poll interval for shutdown check
    syslog.syslog(syslog.LOG_INFO, f"alert-bridge: listening on 192.168.100.10:{PORT}")
    print(f"alert-bridge listening on 192.168.100.10:{PORT}", flush=True)

    try:
        while not _shutdown:
            server.handle_request()  # handles one request per timeout cycle
    finally:
        server.server_close()
        syslog.syslog(syslog.LOG_INFO, "alert-bridge: stopped")


if __name__ == "__main__":
    main()
