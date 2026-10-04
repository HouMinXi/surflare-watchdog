"""Blank quoted strings in a shell file.

Quoted text is data, not code: a structural scan must not treat a
quoted 'for ... do' as a loop.  Reads a path, writes <path>.nq.

Handled quoting: single quotes, double quotes (with backslash escapes),
$'...' strings, and ${name} / ${name-default} expansions inside quotes
(kept, because they name the variable the command actually uses).
"""
import sys

src = open(sys.argv[1], "rb").read().decode()
out = []
i, n = 0, len(src)


def keep_expansion(buf, k):
    """Append the $var at buf[k] to out; return the index after it."""
    m = k + 1
    if m < len(buf) and buf[m] == "{":
        depth = 1
        m += 1
        q = None
        while m < len(buf) and depth:
            c2 = buf[m]
            if q is not None:
                if c2 == "\\":
                    m += 2
                    continue
                if c2 == q:
                    q = None
                m += 1
                continue
            if c2 in ("'", '"'):
                q = c2
            elif c2 == "{":
                depth += 1
            elif c2 == "}":
                depth -= 1
            m += 1
        out.append(buf[k:m])
        return m
    while m < len(buf) and (buf[m].isalnum() or buf[m] == "_"):
        m += 1
    out.append(buf[k:m])
    return m


while i < n:
    c = src[i]
    # $'...' ansi-quoted string
    if c == "$" and i + 1 < n and src[i + 1] == "'":
        i += 2
        while i < n and src[i] != "'":
            if src[i] == "\\":
                i += 2
                continue
            if src[i] == "$":
                i = keep_expansion(src, i)
                continue
            i += 1
        i += 1
        continue
    if c in ("'", '"'):
        quote = c
        i += 1
        while i < n and src[i] != quote:
            if quote == '"' and src[i] == "\\":
                i += 2
                continue
            if src[i] == "$":
                i = keep_expansion(src, i)
                continue
            i += 1
        i += 1
        continue
    out.append(c)
    i += 1

open(sys.argv[1] + ".nq", "w").write("".join(out))
