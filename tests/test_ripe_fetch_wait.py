"""ripe_fetch reaps the child it started and leaves a sibling alone.

The command writes its own pid to a file.  The test reads that pid
back and checks the process, so a child that forked away from this
process is still visible.  A sibling that already exited must still be
a zombie: waitid(P_ALL) would have collected it.
"""
import importlib.util
import os
import sys
import tempfile
import time

_path = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "router", "ripe_fetch.py")
_spec = importlib.util.spec_from_file_location("ripe_fetch", _path)
ripe_fetch = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ripe_fetch)


def exists(pid):
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def test_reaps_own_child_only():
    slot = tempfile.mkdtemp()
    n = {"i": 0}

    def argv(url, path):
        n["i"] += 1
        mark = os.path.join(slot, "p%d" % n["i"])
        return ["sh", "-c", "echo $$ > %s; exec sleep %s" % (
            mark, "0.3" if n["i"] == 1 else "0.5")]

    ripe_fetch.curl_argv = argv
    real_popen = ripe_fetch.subprocess.Popen

    def only_curl(args, **kwargs):
        if not args or args[0] != "sh":
            sys.exit("launcher started something else: %s" % (args,))
        return real_popen(args, **kwargs)

    ripe_fetch.subprocess.Popen = only_curl
    sibling = os.fork()
    if sibling == 0:
        time.sleep(30)
        os._exit(0)
    exited = os.fork()
    if exited == 0:
        os._exit(0)
    time.sleep(0.05)
    t0 = time.time()
    ripe_fetch.main([("a", "a"), ("b", "b")])
    took = time.time() - t0
    os.kill(sibling, 9)
    os.waitpid(sibling, 0)
    if not exists(exited):
        sys.exit("exited sibling was reaped")
    os.waitpid(exited, 0)
    kids = set()
    me = os.getpid()
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            stat = open("/proc/%s/stat" % entry).read()
        except OSError:
            continue
        ppid = int(stat[stat.rfind(")") + 1:].split()[1])
        if ppid == me and int(entry) not in (sibling, exited):
            kids.add(int(entry))
    if kids:
        for pid in list(kids):
            try:
                os.kill(pid, 9)
            except OSError:
                pass
        sys.exit("forked children left: %s" % sorted(kids))
    left = []
    for name in sorted(os.listdir(slot)):
        pid = int(open(os.path.join(slot, name)).read().strip())
        if exists(pid):
            left.append(pid)
            try:
                os.kill(pid, 9)
            except OSError:
                pass
    if left:
        sys.exit("children left behind: %s" % left)
    print("PASS both reaped, sibling lives, %.2fs" % took)


if __name__ == "__main__":
    test_reaps_own_child_only()
