#!/usr/bin/env python3
"""Load a tproxy template into a network namespace, send one datagram
to the control address from a peer namespace, and report whether it
reaches the control return.  Prints HIT or MISS.

The template's control set is filled with 203.0.113.10 and the return
rule gets a counter.  A packet that a rule in front stops never moves
that counter.
"""
import ctypes
import os
import re
import socket
import subprocess
import sys

libc = ctypes.CDLL(None, use_errno=True)
CLONE_NEWNET = 0x40000000


def sh(*args):
    """Run a command, return the completed process (rc inspected)."""
    return subprocess.run(args, capture_output=True, text=True,
                          check=False)


def main():
    """Load the template, send one datagram, print HIT or MISS."""
    with open(sys.argv[1], encoding="utf-8") as f:
        src = f.read()
    # Tolerate any run of whitespace between the set and the verdict.
    # A literal single-space needle misses '@surflare_control  return'
    # silently and the probe then measures the wrong rule.
    src, n = re.subn(
        r"@surflare_control\s+return", "@surflare_control counter return", src)
    if n == 0:
        print("LOAD_FAIL")
        return
    sh("ip", "link", "add", "veth0", "type", "veth", "peer", "name", "veth1")
    sh("ip", "link", "set", "veth0", "name", "br-lan")
    sh("ip", "link", "set", "br-lan", "up")
    sh("ip", "addr", "add", "198.51.100.1/24", "dev", "br-lan")
    # Listen on the control address.  The SYN reaches it only if no
    # rule stops or redirects the packet.  A counter on the return can
    # be faked by a decoy rule; a completed handshake cannot.
    sh("ip", "addr", "add", "203.0.113.10/32", "dev", "lo")
    sh("ip", "link", "set", "lo", "up")
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("203.0.113.10", 443))
    listener.listen(1)
    listener.settimeout(0.5)
    loaded = subprocess.run(
        ["nft", "-f", "-"], input=src, capture_output=True, text=True,
        check=False)
    if loaded.returncode != 0:
        print("LOAD_FAIL")
        return
    sh("nft", "add", "element", "inet", "sw_lan_tproxy",
       "surflare_control", "{", "203.0.113.10", "}")
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(write_fd)
        libc.unshare(CLONE_NEWNET)
        os.read(read_fd, 1)
        for cmd in (
            ["ip", "link", "set", "lo", "up"],
            ["ip", "link", "set", "veth1", "up"],
            ["ip", "addr", "add", "198.51.100.2/24", "dev", "veth1"],
            ["ip", "route", "add", "203.0.113.10/32", "via", "198.51.100.1"],
        ):
            sh(*cmd)
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(0.5)
        try:
            sock.connect(("203.0.113.10", 443))
        except OSError:
            pass  # a refused connect is the MISS signal
        os._exit(0)
    os.close(read_fd)
    sh("ip", "link", "set", "veth1", "netns", str(pid))
    os.write(write_fd, b"x")
    os.close(write_fd)
    os.waitpid(pid, 0)
    # the child writes HIT or MISS on the pipe; the listener only
    # accepts if the packet was not stopped or redirected
    try:
        conn, _ = listener.accept()
        conn.close()
        print("HIT")
    except TimeoutError:
        print("MISS")


if __name__ == "__main__":
    main()
