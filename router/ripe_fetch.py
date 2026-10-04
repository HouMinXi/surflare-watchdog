"""Start the RIPE curls and wait for each one.

Each argument is url and output path, separated by a tab.  The curls
are children of this process, so os.waitid(P_PID) reaps that pid and
cannot collect a sibling such as the heartbeat.  A shell builtin wait
can, which is how the updater wedged for four days.
"""
import os
import subprocess
import sys


def curl_argv(url, path):
    return ["curl", "-fsSL", "--connect-timeout", "30",
            "--max-time", "300", url, "-o", path]


_held = []
CGROUP = "/sys/fs/cgroup/ripe-fetch"


def _enter_cgroup():
    try:
        os.makedirs(CGROUP, exist_ok=True)
        with open(CGROUP + "/cgroup.procs", "w") as fh:
            fh.write(str(os.getpid()))
    except OSError:
        return False
    return True


def _kill_cgroup():
    try:
        me = str(os.getpid())
        with open("/sys/fs/cgroup/cgroup.procs", "w") as fh:
            fh.write(me)
        with open(CGROUP + "/cgroup.kill", "w") as fh:
            fh.write("1")
    except OSError as exc:
        print("ripe_fetch: cgroup kill failed: %s" % exc, file=sys.stderr)
        return
    left = open(CGROUP + "/cgroup.procs").read().strip()
    if left:
        print("ripe_fetch: cgroup not empty after kill: %s" % left,
              file=sys.stderr)
        return
    try:
        os.rmdir(CGROUP)
    except OSError as exc:
        print("ripe_fetch: cgroup remove failed: %s" % exc, file=sys.stderr)


def main(pairs):
    _enter_cgroup()
    procs = []
    for url, path in pairs:
        procs.append(subprocess.Popen(curl_argv(url, path)))
    for proc in procs:
        os.waitid(os.P_PID, proc.pid, os.WEXITED)
    _held[:] = procs
    _kill_cgroup()


if __name__ == "__main__":
    pairs = []
    for line in open(sys.argv[1]):
        line = line.rstrip("\n")
        if not line:
            continue
        url, path = line.split("\t", 1)
        pairs.append((url, path))
    main(pairs)
