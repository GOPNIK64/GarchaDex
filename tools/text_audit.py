#!/usr/bin/env python3
"""Audit every user-facing string: does it come out in English on an English client?

The addon writes its text in Spanish and translates with a phrase table (Locale.lua).
That table is easy to get out of sync -- a reworded string silently loses its translation and
the player reads spanglish. This simulates the exact same replacement the addon does and reports
whatever still looks Spanish afterwards, so the class of bug is caught before a deploy.

Usage:  python3 tools/text_audit.py GarchaDex/*.lua
Exit:   1 when a string would leak Spanish, 0 otherwise.
"""

import re
import sys
from pathlib import Path

# --------------------------------------------------------------------- the phrase table

DICT_ENTRY = re.compile(r'\["((?:[^"\\]|\\.)*)"\]\s*=\s*"((?:[^"\\]|\\.)*)"', re.S)


def load_dict(path: Path) -> dict:
    """Read the phrase table, entries may span lines (key on one, value on the next)."""
    src = path.read_text(encoding="utf-8")
    start = src.find("local DICT = {")
    end = src.find("\n}", start if start >= 0 else 0)
    body = src[start:end] if start >= 0 and end > start else src
    out = {}
    for m in DICT_ENTRY.finditer(body):
        key = m.group(1).replace('\\"', '"').replace("\\\\", "\\")
        val = m.group(2).replace('\\"', '"').replace("\\\\", "\\")
        out[key] = val
    return out


def translate(text: str, order: list, table: dict) -> str:
    """Same algorithm as ns.T: longest keys first, plain substring replacement."""
    out = text
    for key in order:
        if key in out:
            out = out.replace(key, table[key])
    return out


# --------------------------------------------------------------------- Spanish detection

SPANISH_WORDS = """
de del que los las una unos unas con para mas se su sus al es por cuando hasta tiene tienen
hay vez veces cadaveres cadaver los looteado looteados looteo looteos visto plata hechizos
hechizo todavia revelan revelando descubiertos descubierto descubriste puede podes andan hace
hacen pone ponen muestra muestran arriba abajo izquierda derecha pero en el la lo te tu nos mi
le les ya aca porque ya un y o tampoco ninguno ninguna todos todas algo nada donde quien
tenes tene anda anda sale salen falta faltan quedan queda falta poco antes despues entre sobre
sin segun durante mediante cada otro otra mismo misma tan tanto cuanto poco mucho mas
""".split()

ACCENTS = "áéíóúüñÁÉÍÓÚÑ¿¡"

WORD_RE = re.compile(r"[A-Za-zÁÉÍÓÚÑáéíóúñü]+")


def looks_spanish(text: str) -> list:
    hits = []
    if any(c in text for c in ACCENTS):
        hits.append("accents")
    lowered = text.lower()
    for w in WORD_RE.findall(lowered):
        if w in SPANISH_WORDS:
            hits.append(w)
    return hits


# --------------------------------------------------------------------- string literals

def strip_comments(src: str) -> str:
    """Blank out -- comments, respecting string literals."""
    out = []
    i, n = 0, len(src)
    quote = None
    while i < n:
        c = src[i]
        if quote:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(src[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in "\"'":
            quote = c
            out.append(c)
            i += 1
            continue
        if c == "-" and i + 1 < n and src[i + 1] == "-":
            # long bracket comment --[[ ... ]] or to end of line
            if src.startswith("--[[", i):
                end = src.find("]]", i)
                i = n if end < 0 else end + 2
                continue
            end = src.find("\n", i)
            i = n if end < 0 else end
            continue
        out.append(c)
        i += 1
    return "".join(out)


LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"' + r"|'((?:[^'\\\n]|\\.)*)'")


def literals(src: str):
    for m in LITERAL.finditer(strip_comments(src)):
        raw = m.group(1) if m.group(1) is not None else m.group(2)
        yield m.start(), raw.replace('\\"', '"').replace("\\\\", "\\")


SKIP = (
    "Interface\\", "|cff", "|cffff", "|r", "|H", "|h", "SLASH_", "GarchaDexDB",
    "%s", "%d", "%5.1f", "\\n",
)


def interesting(text: str) -> bool:
    if len(text) < 4:
        return False
    if not any(c.isalpha() for c in text):
        return False
    if any(s in text for s in SKIP):
        return False
    if "\\" in text:          # texture / font paths
        return False
    if re.fullmatch(r"[%0-9.\\-]+", text):
        return False
    return True


def line_of(src: str, pos: int) -> int:
    return src.count("\n", 0, pos) + 1


def main(argv):
    if len(argv) < 2:
        print("usage: text_audit.py <lua files...>")
        return 2
    files = [Path(a) for a in argv[1:]]
    locale = Path("GarchaDex/Locale.lua")
    table = load_dict(locale)
    order = sorted(table, key=len, reverse=True)

    leaks, untranslated = [], []
    for f in files:
        if f.name == "Locale.lua" or not f.exists():
            continue
        src = f.read_text(encoding="utf-8")
        for pos, text in literals(src):
            if not interesting(text):
                continue
            hits = looks_spanish(text)
            if not hits:
                continue
            after = translate(text, order, table)
            left = looks_spanish(after)
            entry = (str(f), line_of(src, pos), text, ", ".join(sorted(set(hits))), ", ".join(sorted(set(left))))
            if left:
                leaks.append(entry)
            else:
                untranslated.append(entry)

    def show(title, rows):
        print(f"\n== {title} ({len(rows)}) ==")
        for f, ln, text, why, left in rows:
            tail = f"  -> still: {left}" if left else ""
            print(f"  {f}:{ln}  [{why}]{tail}\n      {text[:110]}")

    show("LEAKS: this text reaches the player in Spanish", leaks)
    if untranslated:
        show("covered by the phrase table, but worth eyeballing", untranslated)
    print()
    if leaks:
        print(f"FAIL: {len(leaks)} string(s) would show Spanish on an English client.")
        return 1
    print("OK: every Spanish string is covered by the phrase table.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
