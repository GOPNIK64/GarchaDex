# GarchaDex

An enemy Pokédex for the **WoW: Forever** client (interface `16001`, build `70425`, project id `18`).

Target an enemy, open the card, and you get everything known about that creature:

- **Spells it casts** — the readable list comes from the vanilla 1.12 reference; the casts you
  actually see are drawn live, because this client hands addons the spell only as an opaque value.
- **Drops with percentages** — the *measured* drop rate from the corpses you looted, next to the
  *reference* chance from the 1.12 database.
- Identity: name, level range, creature type, rank, zone, plus every counter the addon keeps
  (times seen, kills, corpses looted, times it killed you).
- The creature's own art: portrait or 3D model, spell and item icons, item names in the game's
  quality colours, and the client's own tooltips on hover. No custom texture files ship with it.

## Data layers

Every screen separates the two, and never mixes them:

| Layer | Where it comes from | Trust |
|---|---|---|
| **MEDIDO** | events captured in your client: loot source -> creature id, casts, kills | what actually happened |
| **REFERENCIA** | a seed generated offline from the *cmangos classic-db* (vanilla 1.12) | an emulator's data, **not** measured in Forever |

The measured layer is account-wide: one `GarchaDexDB`, shared by every character, and the seed
records which character saw what.

## Commands

| Command | What it does |
|---|---|
| `/gdx` | card for your current target |
| `/gdx <npcID>` | card for an id |
| `/gdx text` | the full card as text in chat |
| `/gdx stats` | counters |
| `/gdx loot` | the last loot events, raw (diagnostic) |
| `/gdx seed` | seed status and accessors |
| `/gdx art` | art audit: which atlases and texture paths this client actually has |
| `/gdx lang es\|en\|auto` | language of the addon's own text |
| `/gdx wipe` / `/gdx wipe all` | clear measurements |
| `/gdxwin` | open the card window |

There is also a floating toolbar (one button per tool, draggable, right click hides it,
`/gdx bar` brings it back).

## Repository layout

```
GarchaDex/            the addon itself (what gets copied into Interface/AddOns)
  GarchaDex.toc       interface 16001, SavedVariables, AllowLoadGameType: forever
  Core.lua            namespace, saved variables, secret-safe helpers, event dispatcher
  Locale.lua          phrase table for the addon's own text (the code writes Spanish)
  Skin.lua            the whole look: classic palette, borders, buttons, scroll body
  Capture.lua         loot attribution, cast capture, kill counters
  Display.lua         the text reports and the slash commands
  UI.lua              the card: header, stat chips, spells, drops, percentage bars
  Widgets.lua         toolbar, index of every npc found, text windows, art audit
  data/gdx_seed.lua   GENERATED static reference seed (do not hand edit)
GDXProbe/             a read-only capability probe used to learn what this client allows
tools/                lua_check.py, api_check.py, build_seed.py, deploy.sh
```

`tools/` is how the addon was developed against a client with no Lua interpreter available:
`lua_check.py` validates structure without executing anything, `api_check.py` validates every API
name used against a dump of the client's own API documentation, `build_seed.py` regenerates the
reference seed, `deploy.sh` copies the addon into the client and reports hash mismatches.

## Regenerating the seed

The seed is built from a copy of the cmangos classic-db database:

```sh
python3 tools/build_seed.py --db classicdb.sql --out GarchaDex/data/gdx_seed.lua
python3 tools/build_seed.py --all-loot   # bundle loot contents for every mob (2.3 MB)
python3 tools/build_seed.py --no-elites  # keep world elites out of the static set
```

Measured sizes with the current database: 1,768 mobs with contents / 1.18 MB by default,
**4,046 mobs / 2.28 MB with `--all-loot`**.

## Client facts this addon is built around

Verified against build 70425 with `GDXProbe` (numbers are from the probe's own reports):

- **The combat log is closed to addons.** `CombatLogGetCurrentEventInfo` and both
  `C_CombatLog*` variants are absent, and registering `COMBAT_LOG_EVENT_UNFILTERED` gets the addon
  blocked by the client ("an action only available to the Blizzard UI"). Kills are therefore
  counted by polling the target, not from combat events.
- **Spell ids of enemy casts are opaque values.** They can be stored and drawn, but not compared,
  printed, formatted, concatenated or used as a table key — any comparison raises. The spell name
  and icon render correctly on screen, and `C_Spell.RequestLoadSpellData` fixes the early
  "no name" cases.
- **Identity is not opaque.** `guid`, `name`, `level`, `creatureType` and
  `C_CreatureInfo.GetCreatureID` all read as plain values, inside and outside combat.
- **Loot attribution works.** `GetLootSourceInfo` returns the corpse's guid, and its second return
  is the amount; `C_CreatureInfo.GetCreatureID(source)` turns that into the npc id that keys the
  whole dex. Money arrives as a loot slot (`slotType = 2`, no link).
- **Item ids resolve by link**, not by name: `C_Item.GetItemInfoInstant` returns a usable icon and
  `C_Item.GetItemQualityByID` the quality, while lookups by name come back empty in this client.
- **`SetBackdrop` needs `BackdropTemplate`** and that template is not available here, so all frames,
  borders and panels are built from plain textures.
- `C_Texture.GetAtlasExists` **is** available, which is how the skin verifies client art at runtime
  instead of guessing texture paths and rendering green checkerboards.

## Credits and data provenance

Not affiliated with Blizzard Entertainment. No game assets are redistributed: the addon draws with
textures and fonts that ship inside the client, and ships no art of its own.

The generated reference seed (`data/gdx_seed.lua`) is derived from the **cmangos classic-db**
database and carries its provenance in the file header. It is a *reference* layer only, clearly
labelled as such everywhere it appears.
