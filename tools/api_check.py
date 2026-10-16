#!/usr/bin/env python3
"""Check every WoW API name an addon uses against the client's own API dump.

Catches typos and Classic-Era leftovers (GetSpellInfo, COMBAT_LOG_EVENT_UNFILTERED
registration is fine, but a misspelled C_Spell.GetInfo is not).

Usage:
    python3 api_check.py Probe.lua [--dump api.json]

Exit code 0 = every API name found in the dump, 1 = unknown names (listed).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

DEFAULT_DUMP = os.path.expanduser("~/.cache/wow-forever-api/api.json")

# names that come from the UI globals the dump does not enumerate as functions
KNOWN_UI = {
    "UIParent", "SlashCmdList", "ChatFontNormal", "GameFontNormal", "GameFontHighlight",
    "DEFAULT_CHAT_FRAME", "BackdropTemplateMixin", "GameTooltip", "NORMAL_FONT_COLOR",
}


def load_dump(path: str) -> tuple[set[str], dict[str, set[str]]]:
    with open(path, "rb") as fh:
        dump = json.load(fh)
    globals_raw = dump.get("globals", {})
    globals_ = set(globals_raw)
    namespaces: dict[str, set[str]] = {}
    # namespace members are published two ways: as a system (name without the C_ prefix)
    # and as a global table whose value is the member list
    for sysd in dump.get("systems", []):
        members = {fn["name"] for fn in sysd.get("functions", [])}
        if members:
            namespaces.setdefault(sysd["name"], set()).update(members)
            namespaces.setdefault("C_" + sysd["name"], set()).update(members)
    for name, kind in globals_raw.items():
        if isinstance(kind, list):
            namespaces.setdefault(name, set()).update(kind)
    return globals_, namespaces


def strip_noise(src: str) -> str:
    out, i, n = [], 0, len(src)
    while i < n:
        m = re.match(r"--\[(=*)\[", src[i:]) or re.match(r"\[(=*)\[", src[i:])
        if m:
            closer = "]" + m.group(1) + "]"
            end = src.find(closer, i + len(m.group(0)))
            end = n if end == -1 else end + len(closer)
            out.append(re.sub(r"[^\n]", " ", src[i:end])); i = end; continue
        if src.startswith("--", i):
            end = src.find("\n", i); end = n if end == -1 else end
            out.append(" " * (end - i)); i = end; continue
        if src[i] in "\"'":
            j = i + 1
            while j < n:
                if src[j] == "\\": j += 2; continue
                if src[j] == src[i]: break
                j += 1
            out.append(re.sub(r"[^\n]", " ", src[i:j + 1])); i = j + 1; continue
        out.append(src[i]); i += 1
    return "".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--dump", default=DEFAULT_DUMP)
    args = ap.parse_args()

    globals_, namespaces = load_dump(args.dump)
    meta_note = ""
    bad = 0
    for path in args.files:
        src = open(path, encoding="utf-8", errors="replace").read()
        code = strip_noise(src)
        own = set(re.findall(r"local\s+([A-Za-z_]\w*)", code))
        own |= set(re.findall(r"function\s+([A-Za-z_]\w*)", code))
        # 1. namespaced calls: C_Foo.Bar or Settings.Foo
        unknown = []
        for m in re.finditer(r"\b(C_[A-Za-z]+|Settings|Enum)\.([A-Za-z_]\w*)", code):
            ns, fn = m.group(1), m.group(2)
            if ns in namespaces and fn not in namespaces[ns]:
                line = code.count("\n", 0, m.start()) + 1
                unknown.append((line, f"{ns}.{fn}", "not in that namespace"))
            elif ns not in namespaces:
                line = code.count("\n", 0, m.start()) + 1
                unknown.append((line, f"{ns}.{fn}", "namespace not in dump"))
        # 2. bare globals that look like API: UpperCamelCase and not ours
        for m in re.finditer(r"(?<![\w.:])([A-Z][A-Za-z0-9_]{2,})\s*\(", code):
            name = m.group(1)
            if name in own or name in KNOWN_UI or name in globals_:
                continue
            if name in {"SLASH_GDXPROBE1", "SLASH_GDXPROBE2"}:
                continue
            line = code.count("\n", 0, m.start()) + 1
            unknown.append((line, name, "not a global in the dump"))
        print(f"== {path}{meta_note}")
        if not unknown:
            print("   every API name found in the client dump")
        for line, name, why in sorted(set(unknown)):
            print(f"   line {line}: {name} ({why})")
        bad += 1 if unknown else 0
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
