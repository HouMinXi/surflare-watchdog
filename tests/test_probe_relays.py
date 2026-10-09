#!/usr/bin/env python3
"""Tests for scripts/probe_relays.py.

Uses synthetic configs with fake credentials (u1/p1, exitu/exitp) -- never
real ones. Network functions are exercised against FakeSocket stubs; the
real path is covered by running the script on the router.
"""
# Test files exercise private helpers and keep method names terse.
# pylint: disable=missing-class-docstring,missing-function-docstring
# pylint: disable=protected-access
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from importlib.util import module_from_spec, spec_from_file_location
from unittest.mock import patch

_spec = spec_from_file_location(
    "probe_relays_mod",
    os.path.join(os.path.dirname(__file__), "..", "scripts", "probe_relays.py"))
pr = module_from_spec(_spec)
_spec.loader.exec_module(pr)

FAKE_RELAY_PW = "p1"
FAKE_EXIT_PW = "exitp"


def _relay_ob(tag, ip, port=443):
    return {"type": "http", "tag": tag, "server": ip, "server_port": port,
            "username": "u1", "password": FAKE_RELAY_PW,
            "tls": {"enabled": True, "insecure": True}}


def _config_json(members_kind="socks"):
    outbounds = [
        _relay_ob("public_109", "64.118.144.240"),
        _relay_ob("public_75", "166.0.188.190"),
        _relay_ob("public_17", "61.111.247.52"),
        # vless twin must NOT be counted as a relay
        {"type": "vless", "tag": "public_109_vless", "server": "64.118.144.240",
         "server_port": 443, "uuid": "x"},
        {"type": "socks", "tag": "mh_option_via_public_109_to_private_885",
         "detour": "udp_public_109", "server": "12.104.12.149",
         "server_port": 13258, "username": "exitu", "password": FAKE_EXIT_PW},
        {"type": "socks", "tag": "mh_option_via_public_75_to_private_885",
         "detour": "udp_public_75", "server": "12.104.12.149",
         "server_port": 13258, "username": "exitu", "password": FAKE_EXIT_PW},
        {"type": "urltest", "tag": "mh_via_auto_to_private_885",
         "outbounds": ["mh_option_via_public_109_to_private_885",
                       "mh_option_via_public_75_to_private_885"]},
    ]
    if members_kind == "none":
        outbounds = outbounds[:4]
    return {"outbounds": outbounds}


def _write_cfg(obj):
    fd, path = tempfile.mkstemp(suffix=".json")
    with os.fdopen(fd, "w") as fh:
        json.dump(obj, fh)
    return path


class FakeSocket:
    """Scripted socket: recv() replays queued byte strings, sendall records."""

    def __init__(self, replies=()):
        self.replies = list(replies)
        self.sent = b""
        self.closed = False

    def settimeout(self, _t):
        pass

    def sendall(self, data):
        self.sent += data

    def recv(self, _n):
        if not self.replies:
            raise OSError("FakeSocket: no more scripted replies")
        return self.replies.pop(0)

    def close(self):
        self.closed = True


class TestParseConfig(unittest.TestCase):
    def setUp(self):
        self.path = _write_cfg(_config_json())

    def tearDown(self):
        os.unlink(self.path)

    def test_relays_extracted_from_plain_http_outbounds(self):
        relays, group, members = pr.parse_config(self.path)
        tags = sorted(r.tag for r in relays)
        self.assertEqual(tags, ["public_109", "public_17", "public_75"])
        self.assertEqual(group, "mh_via_auto_to_private_885")
        self.assertEqual(len(members), 2)
        m0 = members[0]
        self.assertEqual(m0.relay_tag, "public_109")
        self.assertEqual(m0.host, "12.104.12.149")
        self.assertEqual(m0.kind, "socks")
        self.assertEqual(m0.password, FAKE_EXIT_PW)
        by_tag = {r.tag: r for r in relays}
        self.assertEqual(by_tag["public_109"].host, "64.118.144.240")
        self.assertEqual(by_tag["public_109"].port, 443)
        self.assertEqual(by_tag["public_109"].password, FAKE_RELAY_PW)
        self.assertTrue(by_tag["public_109"].tls)

    def test_no_group_is_not_an_error(self):
        path = _write_cfg(_config_json(members_kind="none"))
        try:
            relays, group, members = pr.parse_config(path)
            self.assertEqual(group, "")
            self.assertEqual(members, [])
            self.assertEqual(len(relays), 3)
        finally:
            os.unlink(path)

    def test_missing_member_tag_is_skipped(self):
        cfg = _config_json()
        cfg["outbounds"][-1]["outbounds"].append("mh_option_via_ghost")
        path = _write_cfg(cfg)
        try:
            _relays, _group, members = pr.parse_config(path)
            self.assertEqual(len(members), 2)
            self.assertEqual([m.relay_tag for m in members],
                             ["public_109", "public_75"])
        finally:
            os.unlink(path)


class TestSummarize(unittest.TestCase):
    def test_sort_and_errors(self):
        results = {
            "public_75": [{"ok": True, "total_ms": 200},
                          {"ok": True, "total_ms": 400}],
            "public_109": [{"ok": True, "total_ms": 100},
                           {"ok": True, "total_ms": 300}],
            "public_52": [{"ok": False, "error": "TimeoutError"},
                          {"ok": False, "error": "TimeoutError"}],
        }
        rows = pr.summarize(results)
        self.assertEqual([r["tag"] for r in rows],
                         ["public_109", "public_75", "public_52"])
        self.assertEqual(rows[0]["mean_ms"], 200)
        self.assertEqual(rows[1]["mean_ms"], 300)
        self.assertEqual(rows[2]["ok"], 0)
        self.assertEqual(rows[2]["errors"], {"TimeoutError": 2})

    def test_empty_and_missing_total_ms(self):
        rows = pr.summarize({"ghost": [], "bare": [{"ok": True}]})
        by_tag = {r["tag"]: r for r in rows}
        self.assertEqual(by_tag["ghost"],
                         {"tag": "ghost", "ok": 0, "n": 0,
                          "mean_ms": 0, "errors": {}})
        self.assertEqual(by_tag["bare"]["ok"], 1)
        self.assertEqual(by_tag["bare"]["mean_ms"], 0)


class TestSocks5(unittest.TestCase):
    def test_auth_ok_rep_zero(self):
        sock = FakeSocket([b"\x05\x02", b"\x01\x00",
                           b"\x05\x00\x00\x01"])
        rep = pr._socks5_auth_and_connect(sock, "1.1.1.1", 443, "u", "p")
        self.assertEqual(rep, 0)
        self.assertIn(b"\x05\x01\x02", sock.sent)

    def test_auth_rejected_raises_distinct_error(self):
        sock = FakeSocket([b"\x05\x02", b"\x01\x01"])
        with self.assertRaises(OSError) as cm:
            pr._socks5_auth_and_connect(sock, "1.1.1.1", 443, "u", "bad")
        self.assertIn("auth rejected", str(cm.exception))

    def test_fragmented_head_is_reassembled(self):
        sock = FakeSocket([b"\x05\x02", b"\x01\x00",
                           b"\x05\x00", b"\x00\x01"])
        rep = pr._socks5_auth_and_connect(sock, "1.1.1.1", 443, "u", "p")
        self.assertEqual(rep, 0)

    def test_fragmented_http_headers_are_reassembled(self):
        sock = FakeSocket([b"HTTP/1.1 200 Connection established\r\n",
                           b"\r\n"])
        pr._http_connect(sock, "t.example", 443, "u", "p", 3)

    def test_general_failure_rep_passes_through(self):
        sock = FakeSocket([b"\x05\x02", b"\x01\x00",
                           b"\x05\x01\x00\x01"])
        rep = pr._socks5_auth_and_connect(sock, "1.1.1.1", 443, "u", "p")
        self.assertEqual(rep, 0x01)

    def test_unknown_auth_method_raises(self):
        sock = FakeSocket([b"\x05\x03"])
        with self.assertRaises(OSError):
            pr._socks5_auth_and_connect(sock, "1.1.1.1", 443, "u", "p")

    def test_domain_target_uses_atyp3(self):
        sock = FakeSocket([b"\x05\x02", b"\x01\x00",
                           b"\x05\x00\x00\x03\x01\x00"])
        rep = pr._socks5_auth_and_connect(sock, "example.com", 443, "u", "p")
        self.assertEqual(rep, 0)
        self.assertIn(b"\x05\x01\x00\x03\x0bexample.com", sock.sent)

    def test_ipv6_target_uses_atyp4(self):
        sock = FakeSocket([b"\x05\x02", b"\x01\x00",
                           b"\x05\x00\x00\x04\x00\x00"])
        rep = pr._socks5_auth_and_connect(sock, "::1", 443, "u", "p")
        self.assertEqual(rep, 0)
        self.assertIn(b"\x05\x01\x00\x04" + b"\x00" * 15 + b"\x01",
                      sock.sent)

    def test_socks5_addr_encodings(self):
        self.assertEqual(pr._socks5_addr("1.2.3.4"),
                         b"\x01\x01\x02\x03\x04")
        self.assertTrue(pr._socks5_addr("::1").startswith(b"\x04"))
        self.assertEqual(pr._socks5_addr("example.com"),
                         b"\x03\x0bexample.com")


class TestProbeExit(unittest.TestCase):
    """Full chain with stubbed TCP/TLS layers."""

    def _member(self, kind="socks"):
        return pr.ExitMember(
            tag="mh_option_via_public_109_to_private_885",
            relay_tag="public_109", host="12.104.12.149", port=13258,
            kind=kind, user="exitu", password=FAKE_EXIT_PW)

    def _relay(self):
        return pr.Relay(tag="public_109", host="64.118.144.240", port=443,
                        user="u1", password=FAKE_RELAY_PW, tls=False)

    def test_socks_success(self):
        sock = FakeSocket([b"HTTP/1.1 200 OK\r\n\r\n",
                           b"\x05\x02", b"\x01\x00",
                           b"\x05\x00\x00\x01"])
        with patch.object(pr, "_tcp_connect", return_value=sock):
            res = pr.probe_exit(self._member(), self._relay(),
                                "1.1.1.1", 443, 5)
        self.assertTrue(res["ok"])
        self.assertEqual(res["rep"], 0)
        self.assertIn("relay_exit_ms", res)
        self.assertIn("exit_target_ms", res)

    def test_socks_rep_01_is_reported_not_raised(self):
        sock = FakeSocket([b"HTTP/1.1 200 OK\r\n\r\n",
                           b"\x05\x02", b"\x01\x00",
                           b"\x05\x01\x00\x01"])
        with patch.object(pr, "_tcp_connect", return_value=sock):
            res = pr.probe_exit(self._member(), self._relay(),
                                "1.1.1.1", 443, 5)
        self.assertFalse(res["ok"])
        self.assertEqual(res["rep"], 1)
        self.assertEqual(res["error"], "socks rep:01 (general-failure)")

    def test_http_exit_success(self):
        sock = FakeSocket([b"HTTP/1.1 200 OK\r\n\r\n",
                           b"HTTP/1.1 200 OK\r\n\r\n"])
        with patch.object(pr, "_tcp_connect", return_value=sock):
            res = pr.probe_exit(self._member(kind="http"), self._relay(),
                                "1.1.1.1", 443, 5)
        self.assertTrue(res["ok"])

    def test_http_exit_rejected_connect(self):
        sock = FakeSocket([(b"HTTP/1.1 407 Proxy Authentication Required\r\n"
                            b"\r\n")])
        with patch.object(pr, "_tcp_connect", return_value=sock):
            res = pr.probe_exit(self._member(kind="http"), self._relay(),
                                "1.1.1.1", 443, 5)
        self.assertFalse(res["ok"])
        self.assertIn("407", res["error"])

    def test_tls_relay_exit_wraps_once(self):
        inner = FakeSocket([b"HTTP/1.1 200 OK\r\n\r\n", b"\x05\x02",
                            b"\x01\x00", b"\x05\x00\x00\x01"])
        calls = []

        def fake_wrap(_sock, host):
            calls.append(host)
            return inner

        relay = pr.Relay(tag="public_109", host="64.118.144.240", port=443,
                         user="u1", password=FAKE_RELAY_PW, tls=True)
        with patch.object(pr, "_tcp_connect", return_value=FakeSocket()), \
                patch.object(pr, "_tls_wrap", side_effect=fake_wrap):
            res = pr.probe_exit(self._member(), relay, "1.1.1.1", 443, 5)
        self.assertTrue(res["ok"], res["error"])
        self.assertEqual(calls, ["64.118.144.240"])


class TestProbeQuickTiming(unittest.TestCase):
    def test_tls_ms_excludes_tcp_ms(self):
        relay = pr.Relay("public_1", "h", 443, "u", "p", True)
        clock = iter([10.0, 11.0, 12.5])  # t0, ts, after-close
        with patch.object(pr, "_tcp_connect", return_value=FakeSocket()), \
                patch.object(pr, "_tls_wrap", return_value=FakeSocket()), \
                patch.object(pr.time, "monotonic",
                             side_effect=lambda: next(clock)):
            res = pr.probe_quick(relay, 3)
        self.assertEqual(res["tcp_ms"], 1000)
        self.assertEqual(res["tls_ms"], 1500)
        self.assertEqual(res["total_ms"], 2500)

    def test_plaintext_total_equals_tcp(self):
        relay = pr.Relay("public_1", "h", 443, "u", "p", False)
        clock = iter([10.0, 11.25])  # t0, after connect (probe ends here)
        with patch.object(pr, "_tcp_connect", return_value=FakeSocket()), \
                patch.object(pr.time, "monotonic",
                             side_effect=lambda: next(clock)):
            res = pr.probe_quick(relay, 3)
        self.assertEqual(res["tcp_ms"], 1250)
        self.assertEqual(res["tls_ms"], 0)
        self.assertEqual(res["total_ms"], 1250)


class TestProbeChain(unittest.TestCase):
    def _run(self, relay_tls):
        relay = pr.Relay("public_1", "h", 443, "u", "p", relay_tls)
        sock = FakeSocket([b"HTTP/1.1 200 Connection established\r\n\r\n"])
        calls = []

        def fake_wrap(s, host):
            calls.append(host)
            return s

        with patch.object(pr, "_tcp_connect", return_value=sock), \
                patch.object(pr, "_tls_wrap", side_effect=fake_wrap):
            return pr.probe_chain(relay, "target.example", 443, 3), calls

    def test_relay_tls_wraps_once(self):
        res, calls = self._run(relay_tls=True)
        self.assertTrue(res["ok"], res["error"])
        self.assertEqual(calls, ["h"])

    def test_plain_relay_wraps_target(self):
        res, calls = self._run(relay_tls=False)
        self.assertTrue(res["ok"], res["error"])
        # Plain relay transport: no relay wrap, target wrapped directly.
        self.assertEqual(calls, ["target.example"])
        self.assertEqual(res["hs_ms"], 0)

    def test_rejected_connect_keeps_status_in_error(self):
        relay = pr.Relay("public_1", "h", 443, "u", "p", False)
        sock = FakeSocket([b"HTTP/1.1 403 Forbidden\r\n\r\n"])
        with patch.object(pr, "_tcp_connect", return_value=sock):
            res = pr.probe_chain(relay, "target.example", 443, 3)
        self.assertFalse(res["ok"])
        self.assertIn("403", res["error"])


class TestParseTarget(unittest.TestCase):
    def test_ipv4(self):
        self.assertEqual(pr._parse_target("1.1.1.1:443"), ("1.1.1.1", 443))

    def test_domain(self):
        self.assertEqual(pr._parse_target("example.com:443"),
                         ("example.com", 443))

    def test_ipv6_brackets(self):
        self.assertEqual(pr._parse_target("[::1]:443"), ("::1", 443))

    def test_ipv6_missing_port_raises(self):
        with self.assertRaises(ValueError):
            pr._parse_target("[::1]")


class TestRedaction(unittest.TestCase):
    def test_map_output_never_contains_passwords(self):
        path = _write_cfg(_config_json())
        try:
            buf = io.StringIO()
            args = pr.build_parser().parse_args(
                ["--config", path, "map"])
            with redirect_stdout(buf):
                rc = pr.cmd_map(args)
            out = buf.getvalue()
            self.assertEqual(rc, 0)
            self.assertNotIn(FAKE_RELAY_PW, out)
            self.assertNotIn(FAKE_EXIT_PW, out)
            self.assertIn("public_109", out)
            self.assertIn("mh_via_auto_to_private_885", out)
        finally:
            os.unlink(path)


class TestRunPool(unittest.TestCase):
    def test_groups_by_custom_key_and_counts_failures(self):
        items = [("m1", "a"), ("m2", "b")]

        def fn(item):
            if item[1] == "b":
                raise TimeoutError("boom")
            return {"ok": True, "total_ms": 10}

        results = pr._run_pool(items, fn, 3, 4, key=lambda it: it[1])
        self.assertEqual(len(results["a"]), 3)
        self.assertTrue(all(r["ok"] for r in results["a"]))
        self.assertEqual(len(results["b"]), 3)
        self.assertTrue(all(not r["ok"] for r in results["b"]))
        self.assertEqual(results["b"][0]["error"], "TimeoutError")

    def test_default_key_groups_by_tag(self):
        items = [pr.Relay("public_1", "h", 443, "u", "p", False),
                 pr.Relay("public_2", "h", 443, "u", "p", False)]
        results = pr._run_pool(items, lambda r: {"ok": True, "total_ms": 1},
                               2, 2)
        self.assertEqual(sorted(results), ["public_1", "public_2"])
        self.assertEqual(len(results["public_1"]), 2)
        self.assertEqual(len(results["public_2"]), 2)


if __name__ == "__main__":
    unittest.main()
