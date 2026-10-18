#!/usr/bin/env python3
"""Build the offline creature-name table from warcraftforever.games.

Why this file exists: the client refuses to hand some creatures' names to addons (`UnitName` returns
a secret value for the custom Forever ids), so an entry can be born from a corpse with nothing but an
id. That site records the beta with the ForeverLog addon, so it carries the names — and the levels —
for those ids, which the addon reads as a last resort.

    python3 tools/build_names.py                    # download and regenerate
    python3 tools/build_names.py --html page.html   # parse a saved copy

Output: GarchaDex/data/gdx_names.lua
    ns.names = { [250484] = "Spider|3-4|Humanoid", ... }   -- name | level range | creature type
"""
import argparse
import html
import json
import re
import subprocess
import sys
import urllib.request

SOURCE = "https://warcraftforever.games/npcs"
OUT = "GarchaDex/data/gdx_names.lua"

LINK = re.compile(r'href="/npcs/(\d+)"')
NAME = re.compile(r'class="text-foreground">([^<]+)<')
LEVEL = re.compile(r'class="block truncate text-xs text-muted">([^<]+)<')


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "GarchaDex/name-table"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read().decode("utf-8", "replace")


def parse(page):
    out = {}
    # every item is an <a href="/npcs/ID"> followed by the name and the "level X–Y · Type" line
    for m in LINK.finditer(page):
        nid = m.group(1)
        chunk = page[m.end():m.end() + 900]
        name = NAME.search(chunk)
        if not name:
            continue
        label = LEVEL.search(chunk)
        level, ctype = "", ""
        if label:
            parts = [p.strip() for p in label.group(1).split("·")]
            lv = parts[0].replace("level", "").strip().replace("\u2013", "-").replace("\u2014", "-")
            if re.fullmatch(r"\d+(-\d+)?", lv):
                level = lv
            if len(parts) > 1:
                ctype = parts[1]
        out[nid] = {"name": html.unescape(name.group(1)).strip(), "level": level, "type": ctype}
    return out


def clean(text):
    """One line, no quotes, no backslashes.

    The site wraps long names across lines (a real creature name arrives as "Telenos '\\nLeafwhisper"),
    and a newline inside a Lua string literal makes the WHOLE file fail to compile — the table then
    loads as nil and every lookup silently returns nothing. Hence this.
    """
    text = re.sub(r"\s+", " ", text or "").strip()
    return text.replace('"', "'").replace("\\", "/").replace("|", "/")


def lua(out):
    lines = [
        "-- GarchaDex creature names -- GENERATED FILE, do not edit by hand.",
        "-- source: warcraftforever.games/npcs, recorded in the Forever beta with the ForeverLog addon",
        "-- PROVENANCE: third-party play sessions, not the server's tables and not measured here.",
        "-- Used only as a last resort: when the client refuses to name a creature (UnitName returns a",
        "-- secret value), the addon reads the name from this table instead of showing \"npc <id>\".",
        "-- format: [id] = \"name|level range|creature type\"",
        "local _, ns = ...",
        "ns.names = {",
    ]
    for nid in sorted(out, key=int):
        rec = out[nid]
        value = "|".join([clean(rec["name"]), clean(rec["level"]), clean(rec["type"])]).rstrip("|")
        lines.append('[%s]="%s",' % (nid, value))
    lines.append("}")
    return "\n".join(lines) + "\n"


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--html", help="parse a saved copy instead of downloading")
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args(argv[1:])

    page = open(args.html, encoding="utf-8").read() if args.html else fetch(SOURCE)
    table = parse(page)
    if not table:
        print("no creatures parsed: the page markup changed", file=sys.stderr)
        return 1
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(lua(table))
    print("names: %d creatures -> %s" % (len(table), args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
