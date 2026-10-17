#!/usr/bin/env python3
"""Build GarchaDex's bundled static seed from the cmangos 1.12 database.

Input : ClassicDB_1_12_1_z2815.sql (the Full_DB snapshot, decompressed)
Output: data/gdx_seed.lua (single file, TOC loads it before the addon code)

What goes in:
  npc    - important mobs (dungeon/raid/rare/boss) : name, levels, rank, type, model, map
  loot   - those mobs' own drop table + shared reference groups, "item:chance,..."
  lootn  - pool size N for EVERY mob with a loot id (so the dex can count what is left)
  spell  - vanilla-reference cast list per mob (creature_template_spells)
  wgrp   - shared world-drop groups, kept apart so they never inflate N
  wloot  - which world-drop group a mob rolls on

Every number in here is a 1.12 emulator reference, NOT the live server's table.
The provenance string travels with the data so a later reader cannot mistake it.

Usage: python3 tools/build_seed.py [--db path.sql] [--out data/gdx_seed.lua]
"""
from __future__ import annotations

import argparse
import collections
import os
import re
import sys

INS = re.compile(r"INSERT INTO `([^`]+)` VALUES ")
WORLD_LO, WORLD_HI = 50000, 70000
MAX_NPC_NAME = 48


def split_row(t: str) -> list[str]:
    """Quote-aware field split (comments contain apostrophes and parentheses)."""
    out, cur, q = [], [], None
    for ch in t:
        if q:
            if ch == q:
                q = None
            else:
                cur.append(ch)
        elif ch in "'\"":
            q = ch
        elif ch == ",":
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    out.append("".join(cur))
    return out


class DB:
    def __init__(self, text: str):
        self.text = text
        self.cache: dict[str, list[list[str]]] = {}

    def rows(self, table: str) -> list[list[str]]:
        """Every row of a table, across all its INSERT statements.

        Statements are concatenated on one line, so a line-based regex would keep
        only the first one per line and silently drop the rest.
        """
        if table in self.cache:
            return self.cache[table]
        out = []
        for m in INS.finditer(self.text):
            if m.group(1) != table:
                continue
            start = m.end()
            nxt = INS.search(self.text, start)
            end = nxt.start() if nxt else len(self.text)
            chunk = self.text[start:end].rstrip()
            if chunk.endswith(";"):
                chunk = chunk[:-1]
            b = chunk.strip()
            if b.startswith("("):
                b = b[1:]
            if b.endswith(")"):
                b = b[:-1]
            out.extend(split_row(r) for r in b.split("),("))
        self.cache[table] = out
        return out

    def cols(self, table: str) -> list[str]:
        m = re.search(r"CREATE TABLE `%s` \((.*?)\n\)" % table, self.text, re.S)
        return re.findall(r"^\s*`(\w+)`", m.group(1), re.M) if m else []

    def typed(self, table: str):
        cols = self.cols(table)
        return cols, {c: i for i, c in enumerate(cols)}, [r for r in self.rows(table) if len(r) == len(cols)]


def clean(s: str) -> str:
    s = s.replace("|", "/").replace("\\", "/").replace('"', "'")
    s = re.sub(r"\s+", " ", s).strip()
    return s[:MAX_NPC_NAME]


def lua_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def build(db_path: str, out_path: str, include_elites: bool = True, all_loot: bool = False) -> dict:
    text = open(db_path, encoding="utf-8", errors="replace").read()
    db = DB(text)

    ct_cols, ci, ct_rows = db.typed("creature_template")
    ct = {r[0]: r for r in ct_rows}
    li, loot_rows = db.typed("creature_loot_template")[1], db.typed("creature_loot_template")[2]
    ri, ref_rows = db.typed("reference_loot_template")[1], db.typed("reference_loot_template")[2]
    ii, item_rows = db.typed("item_template")[1], db.typed("item_template")[2]
    items = {r[0]: r[ii["name"]] for r in item_rows}
    si, spawn_rows = db.typed("creature")[1], db.typed("creature")[2]
    ei, enc_rows = db.typed("instance_encounters")[1], db.typed("instance_encounters")[2]
    spi, spell_rows = db.typed("creature_template_spells")[1], db.typed("creature_template_spells")[2]
    inst_maps = {r[0] for r in db.typed("instance_template")[2]}

    # --- sanity: the parse must reproduce the known row counts, or every number below is fiction
    expected = {
        "creature_template": 10384, "creature_loot_template": 169994,
        "reference_loot_template": 33366, "item_template": 17718,
    }
    counts = {t: len(db.rows(t)) for t in expected}
    bad = {t: (counts[t], n) for t, n in expected.items() if counts[t] != n}
    if bad:
        raise SystemExit(f"parsed row counts disagree with the known totals: {bad}")

    loot = collections.defaultdict(list)
    for r in loot_rows:
        loot[r[li["entry"]]].append((r[li["item"]], r[li["ChanceOrQuestChance"]], r[li["mincountOrRef"]]))
    refs = collections.defaultdict(list)
    for r in ref_rows:
        refs[r[ri["entry"]]].append((r[ri["item"]], r[ri["ChanceOrQuestChance"]], r[ri["mincountOrRef"]]))

    def pool(entry: str):
        """own items + expanded shared refs, world-drop groups kept apart"""
        own, shared, world = {}, set(), set()

        def put(d, item, chance):
            try:
                c = float(chance)
            except (TypeError, ValueError):
                c = 0.0
            if item not in d or c > d[item]:
                d[item] = c

        for item, chance, ref in loot.get(entry, []):
            try:
                ri_ = int(ref)
            except ValueError:
                ri_ = 0
            if ri_ < 0:
                g = str(abs(ri_))
                (world if WORLD_LO <= int(g) < WORLD_HI else shared).add(g)
            else:
                put(own, item, chance)
        exp = {}
        for g in shared:
            for gitem, gc, gref in refs.get(g, []):
                try:
                    if int(gref) < 0:
                        continue
                except ValueError:
                    pass
                put(exp, gitem, gc)
        return own, exp, shared, world

    spawn_maps = collections.defaultdict(set)
    for r in spawn_rows:
        spawn_maps[r[si["id"]]].add(r[si["map"]])
    rare = {e for e, r in ct.items() if r[ci["Rank"]] in ("2", "4")}
    boss = {e for e, r in ct.items() if r[ci["Rank"]] == "3"}
    boss |= {r[ei["creditEntry"]] for r in enc_rows}
    important = {e for e in ct if (spawn_maps.get(e, set()) & inst_maps) or e in rare or e in boss}
    if include_elites:
        # world elites (rank 1): the named/nasty mobs a player actually looks up
        # (Hogger, Stitches, Eliza) plus elite-zone trash
        important |= {e for e, r in ct.items() if r[ci["Rank"]] == "1"}

    spells = collections.defaultdict(set)
    for r in spell_rows:
        for v in r[2:]:
            if v and v != "0":
                spells[r[0]].add(v)

    def enc(d):
        return ",".join("%s:%s" % (i, ("%g" % c)) for i, c in sorted(d.items(), key=lambda kv: int(kv[0])))

    npc, loots, lootn, spell_out, wloot = {}, {}, {}, {}, {}
    wgroups: dict[str, str] = {}
    for e, r in ct.items():
        lid = r[ci["LootId"]]
        if not lid.isdigit() or int(lid) <= 0:
            continue
        own, exp, shared, world = pool(lid)
        if not own and not exp:
            continue
        lootn[e] = len(own) + len(exp)
        if all_loot or e in important:
            # a generic mob usually has several skins: ModelId1..4 in the template. The first is the
            # one you meet most, the rest are the variants the card's arrow cycles through. Always
            # write the 8th field ("-" when there are none) because the Lua parser walks non-empty
            # fields only, and an empty one would shift every field after it.
            extra = [r[ci["ModelId%d" % k]] for k in (2, 3, 4)]
            extra = [m for m in extra if m.isdigit() and int(m) > 0]
            npc[e] = "|".join([
                clean(r[ci["Name"]]), r[ci["MinLevel"]], r[ci["MaxLevel"]],
                r[ci["Rank"]], r[ci["CreatureType"]], r[ci["ModelId1"]],
                sorted(spawn_maps.get(e, {"0"}))[0],
                ",".join(extra) or "-",
            ])
            if own:
                loots[e] = enc(own)
            if shared:
                loots[e] = (loots.get(e, "") + ("|" if e in loots else "") + enc(exp)).lstrip("|")
            if world:
                wloot[e] = ",".join("%s:1" % g for g in sorted(world))
                for g in world:
                    if g not in wgroups:
                        wgroups[g] = enc({i: float(c) for i, c, rr in refs.get(g, [])
                                         if not (rr.lstrip("-").isdigit() and int(rr) < 0)})
    for e, ids in spells.items():
        spell_out[e] = ",".join(sorted(ids, key=int))

    def table(name, d, comment):
        parts = [f"-- {comment}", f"ns.{name} = {{"]
        for k in sorted(d, key=lambda x: int(x)):
            v = d[k]
            if isinstance(v, int):
                parts.append(f"[{k}]={v},")
            else:
                parts.append('[%s]="%s",' % (k, lua_escape(v)))
        parts.append("}")
        return "\n".join(parts)

    header = "\n".join([
        "-- GarchaDex static seed -- GENERATED FILE, do not edit by hand.",
        "-- source: cmangos/classic-db Full_DB ClassicDB_1_12_1_z2815 (vanilla 1.12 emulator data)",
        "-- PROVENANCE: vanilla 1.12 reference -- NOT measured in Forever. The live server's",
        "-- loot tables and drop rates are server-side and can differ; measured rows override these.",
        "-- a NEGATIVE chance means quest-conditional (the row does not roll unless the quest is up).",
        "-- loot[id] holds own items then shared-group items separated by '|'.",
        "-- regenerate: python3 tools/build_seed.py --db <ClassicDB.sql> --out data/gdx_seed.lua",
        "local _, ns = ...",
        "ns.SEED = { version = 1, source = \"cmangos classic-db z2815\", label = \"vanilla 1.12 reference\" }",
    ])
    body = "\n\n".join([
        table("npc", npc, "npc[id] = name|minLevel|maxLevel|rank|creatureTypeType|modelId|mapId (important mobs)"),
        table("loot", loots, 'loot[id] = "itemID:chance,..." (own + shared groups; world drops excluded)'),
        table("lootn", lootn, "lootn[id] = pool size N (every mob with loot)"),
        table("spell", spell_out, 'spell[id] = "spellID,..." (vanilla reference casts)'),
        table("wgrp", wgroups, 'wgrp[refID] = "itemID:chance,..." (shared world-drop group)'),
        table("wloot", wloot, "wloot[id] = world-drop group ids the mob rolls on"),
    ])
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(header + "\n\n" + body + "\n")

    return {
        "npc": len(npc), "loot": len(loots), "lootn": len(lootn), "spell": len(spell_out),
        "wgrp": len(wgroups), "wloot": len(wloot), "important": len(important),
        "bytes": len(header) + len(body),
    }


def verify(out_path: str, stats: dict) -> list[str]:
    """Re-read the generated file and count entries, to prove it round-trips."""
    src = open(out_path, encoding="utf-8").read()
    problems = []
    for name, expect in (("npc", stats["npc"]), ("loot", stats["loot"]), ("lootn", stats["lootn"]),
                         ("spell", stats["spell"]), ("wgrp", stats["wgrp"]), ("wloot", stats["wloot"])):
        m = re.search(r"ns\.%s = \{(.*?)\n\}" % name, src, re.S)
        if not m:
            problems.append(f"{name}: table not found in the output")
            continue
        n = len(re.findall(r"^\[\d+\]=", m.group(1), re.M))
        if n != expect:
            problems.append(f"{name}: {n} entries written, expected {expect}")
    if "-- PROVENANCE" not in src or "NOT measured in Forever" not in src:
        problems.append("provenance banner missing")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="/Users/naumannthostrup/.hermes/cache/scratch/gdx/classicdb.sql")
    ap.add_argument("--out",
                    default="GarchaDex/data/gdx_seed.lua",
                    help="the path the ADDON loads (the .toc references data/gdx_seed.lua inside the "
                         "addon folder): writing anywhere else silently leaves the client on a stale seed")
    ap.add_argument("--no-elites", action="store_true", help="leave world elites (rank 1) out of the static set")
    ap.add_argument("--all-loot", action="store_true",
                    help="bundle every mob's loot contents (not just the important ones): ~1.75 MB instead of ~1.18 MB")
    args = ap.parse_args()
    stats = build(args.db, args.out, include_elites=not args.no_elites, all_loot=args.all_loot)
    print("generated %s" % args.out)
    for k, v in stats.items():
        print(f"   {k:10} {v}")
    print("   size       %.0f KB" % (stats["bytes"] / 1024))
    problems = verify(args.out, stats)
    if problems:
        print("SELF-CHECK FAILED:")
        for p in problems:
            print("   -", p)
        return 1
    print("self-check: every table round-trips with the expected entry count")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
