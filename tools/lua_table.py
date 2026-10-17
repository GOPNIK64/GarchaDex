#!/usr/bin/env python3
"""Read the Lua tables this project writes and reads: SavedVariables and the generated seed.

There is no Lua interpreter on this machine, so analysis of what the addon actually stored is done
by parsing the serialized tables directly. The subset handled is the one both sides emit: nested
`key = value` tables, string keys in brackets, quoted strings with backslash escapes, numbers,
`true`/`false`/`nil`. Enough for counts and joins; not a general Lua parser.

usage:
    python3 tools/lua_table.py <file.lua> [table-name ...]   # prints entry counts per table
"""
import re
import sys

_TOK = re.compile(r"""
    (?P<ws>\s+)
  | (?P<comment>--\[\[.*?\]\]|--[^\n]*)
  | (?P<name>\{\}|[A-Za-z_][A-Za-z0-9_.]*)
  | (?P<number>-?\d+\.?\d*(?:[eE][-+]?\d+)?)
  | (?P<string>"(?:[^"\\]|\\.)*")
  | (?P<punct>\.\.\.|[{}\[\]=,;])
""", re.X | re.S)


def _unescape(s):
    return (s.replace("\\n", "\n").replace("\\r", "\r").replace("\\t", "\t")
             .replace('\\"', '"').replace("\\'", "'").replace("\\\\", "\\"))


def _tokens(text):
    pos, n = 0, len(text)
    while pos < n:
        m = _TOK.match(text, pos)
        if not m:
            raise SyntaxError("cannot tokenize at offset %d: %r" % (pos, text[pos:pos + 40]))
        pos = m.end()
        kind = m.lastgroup
        if kind in ("ws", "comment"):
            continue
        yield kind, m.group()


class _P:
    def __init__(self, text):
        self.toks = list(_tokens(text))
        self.i = 0

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else (None, None)

    def next(self):
        t = self.peek()
        self.i += 1
        return t

    def value(self):
        kind, val = self.next()
        if kind == "punct" and val == "...":
            return None         # Lua varargs (`local _, ns = ...`): nothing to keep
        if kind == "punct" and val == "{":
            return self.table()
        if kind == "string":
            return _unescape(val[1:-1])
        if kind == "number":
            return float(val) if ("." in val or "e" in val or "E" in val) else int(val)
        if kind == "name":
            if val == "true":
                return True
            if val == "false":
                return False
            if val == "nil":
                return None
            return val          # bare identifier: keep it as text
        raise SyntaxError("unexpected %r" % (val,))

    def table(self):
        out = {}
        pos = 0
        while True:
            kind, val = self.peek()
            if kind is None:
                raise SyntaxError("unterminated table")
            if kind == "punct" and val == "}":
                self.next()
                return out
            if kind == "punct" and val in (",", ";"):
                self.next()
                continue
            key = None
            if kind == "punct" and val == "[":
                self.next()
                key = self.value()
                k2, v2 = self.next()
                if (k2, v2) != ("punct", "]"):
                    raise SyntaxError("expected ] after key, got %r" % (v2,))
            elif kind == "name" and self.toks[self.i + 1] == ("punct", "="):
                key = self.next()[1]
            if key is None:
                # positional entry ({a, b, c}): Lua numbers them from 1
                pos += 1
                out[pos] = self.value()
                continue
            self.next()             # the '='
            out[key] = self.value()


def load_tables(path):
    """Return {table_name: table} for every `name = {...}` at the file's top level."""
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    p = _P(text)
    found = {}
    while True:
        kind, val = p.peek()
        if kind is None:
            return found
        # only a `name =` pair is a table definition at this level; everything else (`local _, ns = ...`,
        # a stray identifier) is not, and is skipped one token at a time
        if kind == "name" and p.i + 1 < len(p.toks) and p.toks[p.i + 1] == ("punct", "="):
            p.next()
            p.next()
            found[val] = p.value()
            continue
        p.next()


def main(argv):
    path = argv[1]
    tables = load_tables(path)
    names = argv[2:] or sorted(tables)
    for name in names:
        t = tables.get(name)
        print("%s: %s entries" % (name, len(t) if isinstance(t, dict) else type(t).__name__))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
