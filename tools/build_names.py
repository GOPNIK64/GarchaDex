#!/usr/bin/env python3
"""Build the offline creature-name and area tables from warcraftforever.games.

Why this file exists: the client refuses to hand some creatures' names to addons (`UnitName` returns
a secret value for the custom Forever ids), so an entry can be born from a corpse with nothing but an
id. That site records the beta with the ForeverLog addon, so it carries the names, the levels and the
area (dungeon or zone) for those ids — and the size of each area's roster, which is the denominator
of the index bar.

    python3 tools/build_names.py                 # download everything and regenerate
    python3 tools/build_names.py --html page.html --no-dungeons   # parse a saved copy

Output: GarchaDex/data/gdx_names.lua
    ns.names     = { [250484] = "Spider|3-4|Humanoid", ... }  -- name | level range | type
    ns.areaOf    = { [250484] = "Ruins of Lordaeron", ... }    -- the group the index files it under
    ns.areaTotal = { ["Ruins of Lordaeron"] = 34, ... }        -- roster size, the bar denominator
"""
import argparse
import html
import os
import re
import sys
import time
import urllib.request

BASE = "https://warcraftforever.games"
SOURCE = BASE + "/npcs"
OUT = "GarchaDex/data/gdx_names.lua"
CACHE = "/tmp/gdx_zone_cache"

LINK = re.compile(r'href="/npcs/(\d+)"')
NAME = re.compile(r'class="text-foreground">([^<]+)<')
LEVEL = re.compile(r'class="block truncate text-xs text-muted">([^<]+)<')
TITLE = re.compile(r"<title>([^<·]+)·")

# The site has no zone for these and does not list them on the dungeon page, but they are documented
# bosses of that dungeon by the community guides (wowhead.com/forever/zone=16611, warcrafttavern,
# wowforever.be all name the same six: Witherfang, The Baron, Viktor the Vile, The Abandoned, Bjork,
# Rath'mael). Curated by hand, so it is kept separate from anything scraped.
CURATED = {
    "250483": "Ruins of Lordaeron",   # Witherfang
    "250619": "Ruins of Lordaeron",   # name unknown in every database; looted there, id sits in the block
    "250631": "Ruins of Lordaeron",   # The Abandoned
    "250657": "Ruins of Lordaeron",   # Rath'mael
    "250660": "Ruins of Lordaeron",   # The Baron
    "256035": "Ruins of Lordaeron",   # Viktor the Vile
    "256097": "Ruins of Lordaeron",   # Bjork
}

# The site files cities under /dungeons too. A city is a zone: a creature that lives in Dalaran and
# that you met outside Orgrimmar belongs where you met it, not in the city's page.
NOT_INSTANCE = {"City of Dalaran"}

# the site embeds its whole NPC list as JSON; custom ids arrive with type/level/zone as null
NPC = re.compile(
    r'\{"id":(\d+),"name":"((?:[^"\\]|\\.)*)","title":(null|"(?:[^"\\]|\\.)*"),'
    r'"type":(null|"(?:[^"\\]|\\.)*"),"level":(null|"(?:[^"\\]|\\.)*"),'
    r'"hostile":(true|false),"zone":(null|"(?:[^"\\]|\\.)*"),'
    r'"sub":(null|"(?:[^"\\]|\\.)*"),"kills":(\d+),"drops":(\d+)\}'
)


def fetch(url, force=False):
    if url.startswith(BASE) and not force:
        os.makedirs(CACHE, exist_ok=True)
        local = os.path.join(CACHE, url[len(BASE):].strip("/").replace("/", "_") + ".html")
        if os.path.exists(local) and os.path.getsize(local) > 2000:
            return open(local, encoding="utf-8", errors="replace").read()
    req = urllib.request.Request(url, headers={"User-Agent": "GarchaDex/name-table"})
    with urllib.request.urlopen(req, timeout=60) as r:
        data = r.read().decode("utf-8", "replace")
    if url.startswith(BASE):
        os.makedirs(CACHE, exist_ok=True)
        local = os.path.join(CACHE, url[len(BASE):].strip("/").replace("/", "_") + ".html")
        open(local, "w", encoding="utf-8").write(data)
        time.sleep(0.25)
    return data


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


def unjsonish(v):
    """'null' or a JSON string with its escapes -> None or a plain string."""
    if v == "null":
        return None
    v = v[1:-1]
    return html.unescape(v.replace('\\"', '"').replace("\\\\", "\\"))


def parse_areas(page):
    """id -> its zone plus whether it is hostile. The index groups by zone ("The Barrens" whole), not
    by subzone, so a creature found at Jaggedswine Farm files under The Barrens. A dungeon roster
    overrides this later."""
    area, sub2zone, hostile = {}, {}, {}
    raw = page.replace('\\"', '"')
    for m in NPC.finditer(raw):
        nid, zone, sub = m.group(1), unjsonish(m.group(7)), unjsonish(m.group(8))
        hostile[nid] = (m.group(6) == "true")
        if zone:
            area[nid] = zone
        if sub and zone:
            sub2zone[sub] = zone
    return area, sub2zone, hostile


def dungeons(names):
    """dungeon name -> the set of npc ids its page lists, plus any name only that page carries."""
    found, extra = {}, {}
    index = fetch(BASE + "/dungeons")
    slugs = sorted(set(re.findall(r"/dungeons/([a-z0-9\-]+)", index)))
    for slug in slugs:
        page = fetch(BASE + "/dungeons/" + slug)
        title = TITLE.search(page)
        dungeon = html.unescape(title.group(1)).strip() if title else slug.replace("-", " ").title()
        ids = set(LINK.findall(page))
        found[dungeon] = ids
        for nid in ids:
            if nid not in names:
                for m in LINK.finditer(page):
                    if m.group(1) == nid:
                        nm = NAME.search(page[m.end():m.end() + 900])
                        if nm:
                            extra[nid] = {"name": html.unescape(nm.group(1)).strip(), "level": "", "type": ""}
                        break
        print("   %-26s %3d npcs" % (dungeon, len(ids)))
    return found, extra


def clean(text):
    """One line, no quotes, no backslashes.

    The site wraps long names across lines (a real creature name arrives as "Telenos '\\nLeafwhisper"),
    and a newline inside a Lua string literal makes the WHOLE file fail to compile — the table then
    loads as nil and every lookup silently returns nothing. Hence this.
    """
    text = re.sub(r"\s+", " ", text or "").strip()
    return text.replace('"', "'").replace("\\", "/").replace("|", "/")


def lua(out, area, total, sub2zone, dungeons_set):
    lines = [
        "-- GarchaDex creature names and areas -- GENERATED FILE, do not edit by hand.",
        "-- source: warcraftforever.games/npcs and /dungeons/<slug>, recorded in the Forever beta with",
        "-- the ForeverLog addon.",
        "-- PROVENANCE: third-party play sessions, not the server's tables and not measured here.",
        "-- Used only as a fallback: when the client refuses to name a creature (UnitName returns a",
        "-- secret value) or when an entry carries no area, the addon reads it here. It never overrides",
        "-- a name the client gave.",
        "-- format: [id] = \"name|level range|creature type\"",
        "local _, ns = ...",
        "ns.names = {",
    ]
    for nid in sorted(out, key=int):
        rec = out[nid]
        value = "|".join([clean(rec["name"]), clean(rec["level"]), clean(rec["type"])]).rstrip("|")
        lines.append('[%s]="%s",' % (nid, value))
    lines.append("}")
    lines.append("")
    lines.append("-- the group the index files each creature under: its zone, or its dungeon when it is one")
    lines.append("ns.areaOf = {")
    for nid in sorted(area, key=int):
        lines.append('[%s]="%s",' % (nid, clean(area[nid])))
    lines.append("}")
    lines.append("")
    lines.append("-- how many creatures each area holds in total: the denominator of the index bar")
    lines.append("ns.areaTotal = {")
    for group in sorted(total):
        lines.append('["%s"]=%d,' % (clean(group), total[group]))
    lines.append("}")
    lines.append("")
    lines.append("-- subzone -> zone, used to fold areas captured before the index grouped by zone.")
    lines.append("-- Dungeon names are never folded into their parent zone even when the site files them as a")
    lines.append("-- subzone of it: the Ruins of Lordaeron is its own dungeon above Undercity, not Undercity.")
    lines.append("ns.zoneOfSub = {")
    for sub in sorted(sub2zone):
        lines.append('["%s"]="%s",' % (clean(sub), clean(sub2zone[sub])))
    lines.append("}")
    lines.append("")
    lines.append("-- which areas are instances: the index lists them before the open zones and never merges")
    lines.append("-- one of them into the zone it sits in")
    lines.append("ns.areaDungeon = {")
    for name in sorted(dungeons_set):
        lines.append('["%s"]=true,' % clean(name))
    lines.append("}")
    return "\n".join(lines) + "\n"


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--html", help="parse a saved copy of /npcs instead of downloading")
    ap.add_argument("--no-dungeons", action="store_true", help="skip the dungeon rosters")
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args(argv[1:])

    page = open(args.html, encoding="utf-8").read() if args.html else fetch(SOURCE)
    table = parse(page)
    if not table:
        print("no creatures parsed: the page markup changed", file=sys.stderr)
        return 1
    print("   /npcs: %d creatures" % len(table))

    area, sub2zone, hostile = parse_areas(page)
    dungeons_set = set()
    if not args.no_dungeons:
        print("   dungeons:")
        found, extra = dungeons(table)
        table.update(extra)
        dungeons_set = set(found) - NOT_INSTANCE
        for dungeon, ids in found.items():
            for nid in ids:
                area[nid] = dungeon
    # a subzone that is really an instance keeps its own name instead of folding into the zone
    sub2zone = {s: z for s, z in sub2zone.items() if s not in dungeons_set}
    for nid, dungeon in CURATED.items():
        area[nid] = dungeon
    total = {}
    for nid, group in area.items():
        # only creatures you can fight: a capital has hundreds of NPCs and no enemies, and counting
        # civilians made "Undercity 1/132" look like a hunting ground
        if hostile.get(nid, True):
            total[group] = total.get(group, 0) + 1

    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(lua(table, area, total, sub2zone, dungeons_set))
    print("names: %d | areas: %d | groups: %d -> %s" % (len(table), len(area), len(total), args.out))
    for probe in ("Ruins of Lordaeron", "Tirisfal Glades", "The Barrens", "Durotar", "Scarlet Monastery"):
        print("   %-22s total %d" % (probe, total.get(probe, 0)))
    for probe in ("250484", "256040", "250660", "250619"):
        rec = table.get(probe)
        print("   id %s -> %s | %s" % (probe, rec["name"] if rec else "-", area.get(probe, "-")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
