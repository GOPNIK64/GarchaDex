#!/usr/bin/env python3
"""Structural Lua check for WoW addon files (no Lua interpreter needed).

It is not a parser: it tokenises out comments and strings, then verifies that
blocks (function/if/for/while/do/repeat) and (){}[] are balanced, and that no
Lua 5.2+ syntax slipped in (goto, integer division //, bitwise operators, _ENV,
and the libraries WoW does not have).

Usage: python3 lua_check.py <file.lua> [...]
Exit code 0 = clean, 1 = problems found.
"""
from __future__ import annotations

import re
import sys

OPENERS = {"function", "if", "for", "while", "do", "repeat"}
CLOSERS = {"end": 2, "until": 1}  # 'end' closes any block, 'until' closes 'repeat'


def strip_noise(src: str) -> str:
    """Replace comments and string bodies with spaces, keeping newlines."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        # long bracket string / comment
        m = re.match(r"--\[(=*)\[", src[i:]) or re.match(r"\[(=*)\[", src[i:])
        if m:
            eq = m.group(1)
            closer = "]" + eq + "]"
            end = src.find(closer, i + len(m.group(0)))
            end = n if end == -1 else end + len(closer)
            out.append(re.sub(r"[^\n]", " ", src[i:end]))
            i = end
            continue
        if src.startswith("--", i):
            end = src.find("\n", i)
            end = n if end == -1 else end
            out.append(" " * (end - i))
            i = end
            continue
        if c in "\"'":
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == c:
                    break
                j += 1
            out.append(re.sub(r"[^\n]", " ", src[i:j + 1]))
            i = j + 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def check(path: str) -> list[str]:
    src = open(path, encoding="utf-8", errors="replace").read()
    code = strip_noise(src)
    problems: list[str] = []

    # 0. a string literal left open at the end of a line: the file will not compile at all, and a
    #    generator that wraps a long name across lines produces exactly this. Each line must carry an
    #    even number of unescaped quotes (long strings and comments already stripped by strip_noise).
    for no, raw_line in enumerate(src.split("\n"), start=1):
        quotes = len(re.findall(r'(?<!\\)"', raw_line))
        if quotes % 2:
            problems.append(f"line {no}: unterminated string literal (odd number of quotes) -> {raw_line.strip()[:60]}")

    # 1. forbidden / non-5.1 syntax
    for pat, msg in (
        (r"(?<![\w:])goto\s+\w+", "goto is not available in WoW's Lua 5.1"),
        (r"[^/\n]//", "integer division // is Lua 5.3+"),
        (r"[^-\w][&|~][^=&|~]", "bitwise operators are not available (use the bit library)"),
        (r"\b_ENV\b", "_ENV does not exist in Lua 5.1"),
        (r"\brequire\s*\(\s*['\"]", "require is not available"),
        (r"\bdofile\s*\(", "dofile is not available"),
        (r"\bloadfile\s*\(", "loadfile is not available"),
        (r"\bio\.\w+", "the io library is not available"),
        (r"\bos\.\w+", "the os library is not available (date/time are globals)"),
    ):
        for m in re.finditer(pat, code):
            line = code.count("\n", 0, m.start()) + 1
            problems.append(f"line {line}: {msg} -> {m.group(0).strip()}")

    # 2. block balance
    tokens = re.findall(r"[A-Za-z_]\w*|::|==|~=|<=|>=|\.\.|[\r\n]", code)
    depth, line = 0, 1
    stack: list[tuple[str, int]] = []
    idx = 0
    words = []
    for t in re.finditer(r"[A-Za-z_]\w*", code):
        words.append((t.group(0), code.count("\n", 0, t.start()) + 1))
    pending_for_do = 0
    for w, ln in words:
        if w in ("function", "if", "repeat"):
            stack.append((w, ln))
            pending_for_do += 1 if w == "function" else 0
        elif w in ("for", "while"):
            stack.append((w, ln))
            pending_for_do += 1  # a 'do' follows and belongs to this block
        elif w == "do":
            if pending_for_do > 0:
                pending_for_do -= 1
            else:
                stack.append(("do", ln))
        elif w == "end":
            if not stack:
                problems.append(f"line {ln}: 'end' without an opening block")
            else:
                stack.pop()
        elif w == "until":
            if not stack:
                problems.append(f"line {ln}: 'until' without 'repeat'")
            else:
                stack.pop()
        elif w == "then":
            if not any(s[0] in ("if",) for s in stack[-1:]):
                problems.append(f"line {ln}: 'then' outside an if")
    if stack:
        problems.append("unclosed blocks: " + ", ".join(f"{k}@{ln}" for k, ln in stack))

    # 3. bracket balance (outside strings/comments)
    pairs = {")": "(", "]": "[", "}": "{"}
    seq = []
    for ch in code:
        if ch in "([{":
            seq.append(ch)
        elif ch in ")]}":
            if not seq or seq.pop() != pairs[ch]:
                problems.append(f"unbalanced '{ch}'")
                break
    if seq:
        problems.append("unclosed brackets: " + "".join(seq))

    # 4. WoW API use without pcall/capability guard is a review flag, not an error
    risky = []
    for name in ("C_Spell.", "C_Item.", "C_CreatureInfo.", "GetLootSourceInfo", "UnitCastingInfo"):
        for m in re.finditer(re.escape(name), code):
            line = code.count("\n", 0, m.start()) + 1
            ctx = code.splitlines()[line - 1]
            if "pcall" not in ctx and "cap(" not in ctx and "type(" not in ctx:
                risky.append(f"line {line}: {name} used without a visible guard")
    return problems, risky


def main() -> int:
    bad = 0
    for path in sys.argv[1:]:
        problems, risky = check(path)
        print(f"== {path}")
        if not problems:
            print("   structure: OK (blocks and brackets balanced, no 5.2+ syntax)")
        for p in problems:
            print("   PROBLEM:", p)
        for r in risky:
            print("   review:", r)
        bad += 1 if problems else 0
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
