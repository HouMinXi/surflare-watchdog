#!/usr/bin/env python3
"""Quote- and comment-aware nft set-block extractor.

Extracts the body of a named set declaration from nftables config text
and reports its family.  Unlike grep/awk line matching, this skips
quoted strings and comments, so same-line decoy sets, glued '#{'
comments, and '#' inside quotes cannot smuggle a wrong family past the
check.  Used by tests/test_controlplane_lan_bypass.sh.

Usage:
    extract_set_block.py <file> <set-name>            -> prints block body, exit 0
    extract_set_block.py <file> <set-name> --family   -> prints family, exit 0

Exit codes: 0 found; 1 not found.
"""
import re
import sys


def strip_and_scan(text):
    """Yield (char, in_code) pairs with quotes and comments masked."""
    out = []
    i, n = 0, len(text)
    in_squote = in_dquote = in_comment = False
    while i < n:
        c = text[i]
        if in_comment:
            if c == "\n":
                in_comment = False
                out.append(c)
            else:
                out.append(" ")
            i += 1
            continue
        if in_squote:
            if c == "'":
                in_squote = False
            out.append(" " if c != "\n" else c)
            i += 1
            continue
        if in_dquote:
            if c == '"':
                in_dquote = False
            out.append(" " if c != "\n" else c)
            i += 1
            continue
        if c == "#":
            in_comment = True
            out.append(" ")
            i += 1
            continue
        if c == "'":
            in_squote = True
            out.append(" ")
            i += 1
            continue
        if c == '"':
            in_dquote = True
            out.append(" ")
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def extract_block(masked, set_name):
    """Return the brace-balanced block body for `set <name> {`.

    The match is anchored so that `set surflare_control2 {` never
    matches a lookup of `surflare_control`.  Left-edge safe: a decoy
    set joined before the real one is skipped because the scan finds
    only the named declaration.
    """
    pat = re.compile(r"\bset\s+" + re.escape(set_name) + r"\s*\{")
    m = pat.search(masked)
    if not m:
        return None
    depth = 1  # the opening brace is consumed by the regex match
    start = m.end()
    for i in range(start, len(masked)):
        if masked[i] == "{":
            depth += 1
        elif masked[i] == "}":
            depth -= 1
            if depth == 0:
                return masked[start:i]
    return None  # unbalanced: fail closed


def extract_quoted_after(masked, needle, max_chars=400):
    """Return the first single-quoted string after `needle` (for the
    hot-add 'nft add set ... surflare_control \'{ ... }\'' form)."""
    pat = re.compile(
            r"[\s\\]+".join(re.escape(w) for w in needle.split())
            + r"(?!\w)")
    m = pat.search(masked)
    if not m:
        return None
    window = masked[m.start(): m.start() + max_chars]
    q = window.find("'")
    if q < 0:
        return None
    end = window.find("'", q + 1)
    if end < 0:
        return None
    return window[q + 1: end]


def main():
    """CLI entry: print the named set block (or its family)."""
    if len(sys.argv) < 3:
        sys.stderr.write(__doc__ or "")
        return 2
    path, set_name = sys.argv[1], sys.argv[2]
    want_family = "--family" in sys.argv[3:]
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        masked = strip_and_scan(f.read())

    # Direct declaration first.
    body = extract_block(masked, set_name)
    if body is None:
        # Hot-add form: nft add set ... <name> '...type ipv4_addr...'
        quoted = extract_quoted_after(
            masked, "nft add set inet killswitch " + set_name)
        body = quoted
    if body is None:
        return 1
    if want_family:
        m = re.search(r"\btype\s+(ipv[46]_addr)", body)
        if not m:
            sys.stderr.write("no type declaration in block\n")
            return 1
        print(m.group(1))
    else:
        print(body.strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
