#!/usr/bin/env python3
"""Build the offline item-quality table (itemID -> 0..7) for GarchaDex.

Why: this client has no GetItemInfo / GetItemQualityByID, so an item the player has never seen has
no quality at runtime. The card wants to colour the undiscovered "?" slots by rarity, which is the
whole point of a dex: knowing a purple is out there. Quality is static, so it ships as data.

Input : AzerothCore's item_template.sql (16 MB, raw GitHub) — vanilla item ids keep their quality
Output: GarchaDex/data/gdx_items.lua

    python3 tools/build_items.py                # download (cached) and regenerate
    python3 tools/build_items.py --sql path.sql # use a local dump

Only ids that appear in the seed's pools are written: 7.4k rows instead of 46k.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import urllib.request

SOURCE = "https://raw.githubusercontent.com/azerothcore/azerothcore-wotlk/master/data/sql/base/db_world/item_template.sql"
CACHE = "/tmp/gdx_zone_cache/item_template.sql"
SEED = "GarchaDex/data/gdx_seed.lua"
OUT = "GarchaDex/data/gdx_items.lua"


def fetch(path: str, cache: str) -> str:
    if os.path.exists(cache) and os.path.getsize(cache) > 1_000_000:
        return open(cache, encoding="utf-8", errors="replace").read()
    os.makedirs(os.path.dirname(cache), exist_ok=True)
    req = urllib.request.Request(path, headers={"User-Agent": "GarchaDex/item-quality"})
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read().decode("utf-8", "replace")
    open(cache, "w", encoding="utf-8").write(data)
    return data


def columns_of(sql: str, table: str) -> list[str]:
    """Column order from the CREATE TABLE: the dumps write `INSERT INTO x VALUES` with no list."""
    m = re.search(r"CREATE TABLE\s+`?%s`?\s*\((.*?)\n\)\s*ENGINE" % table, sql, re.S | re.I)
    if not m:
        return []
    cols = []
    for line in m.group(1).split("\n"):
        hit = re.match(r"\s*`([^`]+)`\s+\w", line)
        if hit:
            cols.append(hit.group(1).lower())
    return cols


def rows_of(sql: str, table: str):
    """Yield the field list of every VALUES row of an INSERT for `table`, quote and paren aware."""
    for m in re.finditer(r"(INSERT INTO\s+`?%s`?\s*(?:\(([^)]*)\))?\s*VALUES)" % table, sql, re.I):
        if m.group(2):
            cols = [c.strip().strip("`").lower() for c in m.group(2).split(",")]
        else:
            cols = columns_of(sql, table)
        pos = m.end()
        n = len(sql)
        while pos < n:
            while pos < n and sql[pos] in " \t\r\n,":
                pos += 1
            if pos >= n or sql[pos] != "(":
                break
            fields, cur, quote, depth = [], [], None, 0
            pos += 1
            while pos < n:
                ch = sql[pos]
                if quote:
                    if ch == "\\" and pos + 1 < n:
                        # escaped character inside a quoted field: keep both, do not close the quote
                        cur.append(ch)
                        cur.append(sql[pos + 1])
                        pos += 2
                        continue
                    if ch == quote:
                        if pos + 1 < n and sql[pos + 1] == quote:
                            cur.append(ch)
                            pos += 2
                            continue
                        quote = None
                    else:
                        cur.append(ch)
                elif ch in "'\"":
                    quote = ch
                elif ch == "(":
                    depth += 1
                    cur.append(ch)
                elif ch == ")":
                    if depth == 0:
                        fields.append("".join(cur).strip())
                        pos += 1
                        break
                    depth -= 1
                    cur.append(ch)
                elif ch == "," and depth == 0:
                    fields.append("".join(cur).strip())
                    cur = []
                else:
                    cur.append(ch)
                pos += 1
            yield cols, fields


def catalog_ids() -> set[int]:
    """Every item id the seed's pools mention: the only ids the dex can ever show."""
    src = open(SEED, encoding="utf-8", errors="replace").read()
    ids = set()
    for name in ("loot", "wgrp"):
        m = re.search(r"^ns\.%s = \{$" % name, src, re.M)
        if not m:
            continue
        end = src.find("\n}", m.end())
        for hit in re.finditer(r"(\d+):-?[\d.]+", src[m.end():end]):
            ids.add(int(hit.group(1)))
    return ids


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sql", help="local item_template.sql instead of downloading")
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args(argv[1:])

    print("catalogo: %d items en el seed" % len(catalog_ids()))
    need = catalog_ids()
    sql = open(args.sql, encoding="utf-8", errors="replace").read() if args.sql else fetch(SOURCE, CACHE)
    print("sql: %.1f MB" % (len(sql) / 1048576))

    quality = {}
    for cols, fields in rows_of(sql, "item_template"):
        if len(fields) != len(cols):
            continue
        try:
            entry = int(fields[cols.index("entry")])
            q = int(fields[cols.index("quality")])
        except (ValueError, IndexError):
            continue
        if entry in need:
            quality[entry] = q
    print("con calidad resuelta: %d / %d (%.1f%%)" % (
        len(quality), len(need), 100.0 * len(quality) / max(1, len(need))))

    lines = [
        "-- GarchaDex item quality -- GENERATED FILE, do not edit by hand.",
        "-- source: AzerothCore item_template (vanilla ids keep their quality)",
        "-- this client has no GetItemInfo/GetItemQualityByID, so the rarity of an item you have never",
        "-- seen has to be data. 0 junk, 1 common, 2 uncommon, 3 rare, 4 epic, 5 legendary, 6 artifact.",
        "local _, ns = ...",
        "ns.itemQuality = {",
    ]
    for item in sorted(quality):
        lines.append("[%d]=%d," % (item, quality[item]))
    lines.append("}")
    open(args.out, "w", encoding="utf-8").write("\n".join(lines) + "\n")
    print("escrito %s" % args.out)
    for probe in (117, 2589, 2774):
        print("   id %d -> %s" % (probe, quality.get(probe, "no esta")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
