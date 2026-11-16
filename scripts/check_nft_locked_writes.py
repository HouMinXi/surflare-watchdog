#!/usr/bin/env python3
"""Inventory nft calls with shfmt; compare exact sites to reviewed records.

This is a host-side change detector, not a proof of shell lock ownership.
Runtime call-site tests establish that enrolled wrappers actually hold a lock.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

ANSI_C_SIMPLE = {
    "a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f",
    "n": "\n", "r": "\r", "t": "\t", "v": "\v", "\\": "\\",
    "'": "'", '"': '"', "?": "?",
}


class UnresolvedWord(ValueError):
    """A spelling the gate refuses to guess at rather than silently drop."""


def decode_ansi_c(text):
    """Decode $'...' escapes, which the shell expands without any evaluation."""
    out = []
    i = 0
    while i < len(text):
        char = text[i]
        if char != "\\" or i + 1 >= len(text):
            out.append(char)
            i += 1
            continue
        escape = text[i + 1]
        if escape in ANSI_C_SIMPLE:
            out.append(ANSI_C_SIMPLE[escape])
            i += 2
            continue
        if escape in "01234567":
            digits = text[i + 1:i + 4]
            keep = ""
            for digit in digits:
                if digit not in "01234567":
                    break
                keep += digit
            out.append(chr(int(keep, 8) & 0xFF))
            i += 1 + len(keep)
            continue
        if escape == "x":
            digits = ""
            for digit in text[i + 2:i + 4]:
                if digit not in "0123456789abcdefABCDEF":
                    break
                digits += digit
            if digits:
                out.append(chr(int(digits, 16)))
                i += 2 + len(digits)
                continue
        if escape in "uU":
            width = 4 if escape == "u" else 8
            digits = ""
            for digit in text[i + 2:i + 2 + width]:
                if digit not in "0123456789abcdefABCDEF":
                    break
                digits += digit
            if digits:
                try:
                    out.append(chr(int(digits, 16)))
                except ValueError:
                    raise UnresolvedWord(f"invalid ANSI-C escape in {text!r}")
                i += 2 + len(digits)
                continue
        if escape == "c" and i + 2 < len(text):
            out.append(chr(ord(text[i + 2].upper()) ^ 0x40))
            i += 3
            continue
        out.append(char)
        out.append(escape)
        i += 2
    # The shell executes a word as a C string: an encoded NUL ends it there,
    # so $'\x6e\x66\x74\x00' runs nft.  Truncate instead of keeping a
    # character the shell never passes on.
    return "".join(out).split("\0", 1)[0]


INDIRECTIONS = {"eval", "sudo", "doas", "sh", "bash", "ash", "dash",
                "busybox", "xargs", "builtin", "env"}
BRACE_EXPANSION = re.compile(r"\{[^{}\s]*(,|\.\.)[^{}\s]*\}")


def unquote(text, in_double=False):
    """Apply shell quote removal to a literal, never evaluating it."""
    out = []
    i = 0
    while i < len(text):
        char = text[i]
        if char != "\\" or i + 1 >= len(text):
            out.append(char)
            i += 1
            continue
        following = text[i + 1]
        if following == "\n":
            i += 2
            continue
        if in_double and following not in '$`"\\':
            out.append(char)
            out.append(following)
            i += 2
            continue
        out.append(following)
        i += 2
    return "".join(out)


def word(node, in_double=False):
    """Canonicalise the word the shell executes, without evaluating it."""
    if isinstance(node, list):
        return "".join(word(x, in_double) for x in node)
    if not isinstance(node, dict):
        return ""
    kind = node.get("Type")
    if kind == "Lit":
        value = node.get("Value", "")
        if not in_double and BRACE_EXPANSION.search(value):
            # The shell expands one word into several; refuse instead of
            # reporting an inventory that silently omits those words.
            raise UnresolvedWord(f"brace expansion {value!r}")
        return unquote(value, in_double)
    if kind == "SglQuoted":
        value = node.get("Value", "")
        return decode_ansi_c(value) if node.get("Dollar") else value
    if kind == "ParamExp":
        name = node.get("Param", {}).get("Value", "?")
        return "${" + name + "}"
    if kind == "CmdSubst":
        return "$(command)"
    parts = node.get("Parts", [])
    return word(parts, in_double or kind == "DblQuoted")


def spelling(node):
    """Retain the written spelling: quoting drift stays an enrollment change."""
    if isinstance(node, list):
        return "".join(spelling(x) for x in node)
    if not isinstance(node, dict):
        return ""
    kind = node.get("Type")
    if kind in ("Lit", "SglQuoted"):
        return node.get("Value", "").replace("\\\n", "")
    if kind == "ParamExp":
        name = node.get("Param", {}).get("Value", "?")
        return "${" + name + "}"
    if kind == "CmdSubst":
        return "$(command)"
    return spelling(node.get("Parts", []))


def semantic(node):
    """Drop source coordinates, retaining quoting and expansion operators."""
    if isinstance(node, list):
        return [semantic(x) for x in node]
    if not isinstance(node, dict):
        return node
    return {k: semantic(v) for k, v in node.items()
            if k not in ("Pos", "End", "Comments", "Last")
            and not (isinstance(v, dict) and "Offset" in v and "Line" in v)}


def prefix_option(name, flag):
    """Classify one launch-prefix option: (takes a value, is standalone)."""
    if name in ("nice", "ionice") and flag in ("-n", "-c"):
        return True, False
    if flag in ("--adjustment", "--class", "--classdata", "--input",
                "--output", "--error"):
        return True, False
    if re.fullmatch(r"-\d+", flag):
        return False, True
    if name == "ionice" and flag in ("-p", "-P", "-u"):
        return True, False
    if name == "stdbuf" and flag in ("-i", "-o", "-e"):
        return True, False
    if re.fullmatch(r"-[ioe].+", flag) or re.fullmatch(r"-[cnpPu].+", flag):
        return False, True
    if flag.startswith(("--adjustment=", "--class=", "--classdata=",
                        "--input=", "--output=", "--error=")):
        return False, True
    if name in ("nohup", "setsid") and flag in ("-v", "--verbose"):
        return False, True
    return False, False


def launcher_value(args, option):
    """Consume one required literal word without interpreting its contents."""
    if not args:
        raise ValueError(f"missing argument for launcher option {option}")
    return args[1:]


def indirection_command(name, args):
    """Return the argument that names the command an indirection runs."""
    if name in ("sh", "bash", "ash", "dash"):
        if "-c" in args:
            after = args[args.index("-c") + 1:]
            return after[0] if after else ""
        return None
    for arg in args:
        if arg.startswith("-"):
            continue
        return arg
    return None


def nft_command(args):
    """Unwrap explicit launcher grammars; refuse unparsed launcher options."""
    args = list(args)
    if args and args[0] == "nft_apply_locked":
        args = args[2:]
    while args:
        name = Path(args[0]).name
        if name == "command":
            args = args[1:]
            while args and args[0].startswith("-"):
                flag, args = args[0], args[1:]
                if flag == "--":
                    break
                if flag in ("-v", "-V", "-pv", "-pV"):
                    return []  # command discovery does not execute its operand
                if flag != "-p":
                    raise ValueError(f"unsupported command option {flag}")
        elif name == "exec":
            args = args[1:]
            while args and args[0].startswith("-"):
                flag, args = args[0], args[1:]
                if flag == "--":
                    break
                if flag == "-a":
                    args = launcher_value(args, flag)
                elif flag.startswith("-a") and len(flag) > 2:
                    pass
                elif not re.fullmatch(r"-[cl]+", flag):
                    raise ValueError(f"unsupported exec option {flag}")
        elif name == "timeout":
            args = args[1:]
            while args and args[0].startswith("-"):
                flag, args = args[0], args[1:]
                if flag == "--":
                    break
                if flag in ("-k", "-s", "--kill-after", "--signal"):
                    args = launcher_value(args, flag)
                elif (flag.startswith(("--kill-after=", "--signal="))
                      or re.fullmatch(r"-[ks].+", flag)
                      or flag in ("--preserve-status", "--foreground", "-v",
                                  "--verbose")):
                    pass
                else:
                    raise ValueError(f"unsupported timeout option {flag}")
            args = launcher_value(args, "timeout duration")
        elif name in ("nice", "nohup", "setsid", "ionice", "stdbuf"):
            # Ordinary launch prefixes: skip their own options and keep looking
            # for the command that actually runs.
            args = args[1:]
            while args and args[0].startswith("-"):
                flag, args = args[0], args[1:]
                if flag == "--":
                    break
                takes_value, standalone = prefix_option(name, flag)
                if takes_value:
                    args = launcher_value(args, flag)
                elif standalone:
                    continue
                else:
                    raise ValueError(f"unsupported {name} option {flag}")
            if name == "nice" and args and re.fullmatch(r"-?\d+", args[0]):
                args = args[1:]
        elif name == "env":
            args = args[1:]
            while args:
                flag = args[0]
                if flag == "--":
                    args = args[1:]
                    break
                if flag in ("-i", "-", "--ignore-environment", "-v", "--debug"):
                    args = args[1:]
                elif flag in ("-u", "--unset", "-C", "--chdir"):
                    args = launcher_value(args[1:], flag)
                elif (flag.startswith(("--unset=", "--chdir="))
                      or re.fullmatch(r"-[uC].+", flag)):
                    args = args[1:]
                elif flag.startswith("-"):
                    # In particular, env -S interprets an embedded command
                    # language. Never guess at it or silently lose the call.
                    raise ValueError(f"unsupported env option {flag}")
                else:
                    break
            while args and "=" in args[0]:
                args = args[1:]
        else:
            break
    if args and args[0] == "$(command)":
        raise UnresolvedWord("command substitution names the program")
    if args:
        name = Path(args[0]).name
        if name in INDIRECTIONS:
            command = indirection_command(name, args[1:])
            # Only a mention of nft is actionable: the daemon legitimately runs
            # `sh -c` with script text full of expansions (sexpect sessions),
            # and a command computed at runtime cannot be enumerated here.
            if command is not None and "nft" in command:
                # Same precedent as env -S and brace expansion: refuse a
                # spelling the inventory cannot follow instead of dropping it.
                raise UnresolvedWord(f"{name} indirection cannot be followed: "
                                     + " ".join(args))
    if args and (Path(args[0]).name == "nft"
                 or args[0] in ("${NFT}", "_cn_domain_nft")):
        return args
    return []


def literal_read(args):
    """Only a small literal single-statement list/get grammar is exempt."""
    tokens = args[1:]
    while tokens and tokens[0] in ("-a", "-n", "-nn", "-j", "--handle"):
        tokens = tokens[1:]
    if tokens in (["--version"], ["--help"]):
        return True
    if not tokens or tokens[0] not in ("list", "get"):
        return False
    # No semicolons, expansions, file options, newlines or expressions can be
    # hidden behind an initial read verb. Conservative enrollment is safe.
    return all(re.fullmatch(r"[A-Za-z0-9_.:/-]+", t)
               and not t.startswith("-") for t in tokens)


def inventory(path):
    proc = subprocess.run(
        [os.environ.get("SHFMT", "shfmt"), "-ln=bash", "--to-json"], input=path.read_bytes(),
        capture_output=True, timeout=30, check=False,
    )
    if proc.returncode:
        raise ValueError("shell parse failed: " + proc.stderr.decode().strip())
    ast = json.loads(proc.stdout)
    result = []
    seen = Counter()

    def walk(node, owner="<top-level>", redirs=()):
        if isinstance(node, list):
            for child in node:
                walk(child, owner, redirs)
            return
        if not isinstance(node, dict):
            return
        if node.get("Type") == "FuncDecl":
            owner = node["Name"]["Value"]
        if "Redirs" in node:
            redirs = node["Redirs"]
        if node.get("Type") == "CallExpr":
            args = [word(a) for a in node.get("Args", [])]
            spelled = [spelling(a) for a in node.get("Args", [])]
            wrapped = bool(args and args[0] == "nft_apply_locked")
            cmd = nft_command(args)
            if cmd:
                read_only = not wrapped and literal_read(cmd)
                if not read_only:
                    data = {
                        "owner": owner,
                        "args": semantic(node.get("Args", [])),
                        "redirections": semantic(redirs),
                    }
                    encoded = json.dumps(data, sort_keys=True).encode()
                    digest = hashlib.sha256(encoded).hexdigest()
                    seen[digest] += 1
                    result.append({
                        "id": f"{digest}:{seen[digest]}",
                        "owner": owner, "command": " ".join(spelled),
                        "executed": " ".join(args),
                        "wrapped": wrapped, "line": node["Pos"]["Line"],
                    })
        # Heredoc words are data, but command substitutions in their Parts
        # remain shell code and must be walked. Lit nodes contain no calls.
        for key, child in node.items():
            if key not in ("Comments", "Last", "Pos", "End"):
                walk(child, owner, redirs)

    walk(ast)
    if not result:
        raise ValueError("empty nft write inventory")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--manifest", type=Path,
                        default=Path(__file__).with_name("nft-write-sites.json"))
    parser.add_argument("--inventory", action="store_true")
    args = parser.parse_args()
    try:
        sites = inventory(args.source)
        if args.inventory:
            print(json.dumps(sites, indent=2))
            return 0
        records = json.loads(args.manifest.read_text())
        if not isinstance(records, list) or not records:
            raise ValueError("manifest must contain site records")
        expected = {r["id"]: r for r in records}
        if len(expected) != len(records):
            raise ValueError("duplicate manifest site")
        failures = []
        for site in sites:
            record = expected.pop(site["id"], None)
            if record is None:
                detail = site["command"]
                if site.get("executed") != site["command"]:
                    detail += f" (executes: {site['executed']})"
                failures.append(f"new site {site['owner']}:{site['line']}: "
                                + detail)
            elif (record.get("wrapped") != site["wrapped"]
                  or record.get("command") != site["command"]
                  or record.get("owner") != site["owner"]):
                failures.append(f"identity mismatch: {site['id']}")
            elif not isinstance(record.get("reason"), str) or not re.search(
                    r"[A-Za-z]", record["reason"]):
                failures.append(f"reason missing: {site['id']}")
        failures.extend(f"stale site: {r['owner']} {r['command']}"
                        for r in expected.values())
        if failures:
            print("FAIL: nft write inventory drift\n" + "\n".join(failures))
            return 1
        wrapped = sum(s["wrapped"] for s in sites)
        print(f"OK: {len(sites)} exact nft write sites; {wrapped} wrapper calls; "
              "runtime lock coverage is checked separately")
        return 0
    except (OSError, ValueError, KeyError, TypeError,
            subprocess.TimeoutExpired) as exc:
        print(f"ERROR: nft write inventory unavailable: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
