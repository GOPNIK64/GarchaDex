# GarchaDex

An enemy Pokédex for the **WoW: Forever** client (interface `16001`, build `70425`, project id `18`).

> **Status: active development.** The addon is being improved every session: versions move fast, the
> UI and the saved-variable schema still change between releases, and every fix ships with a version
> bump. Check [Releases](https://github.com/GOPNIK64/GarchaDex/releases/latest) before reporting
> something that may already be fixed, and `tools/update.sh` tells you what is newer than your build.

Target an enemy, open the card, and you get everything known about that creature:

- **Spells it casts** — the readable list is the vanilla 1.12 reference; what you actually see it cast
  is drawn live, because this client hands addons the spell only as an opaque value.
- **Drops with their reference chance** — the whole 1.12 pool is drawn as slots: what you looted shows
  its name, the rest stay as `?` with the same static chance, so the dex is something you complete.
- Identity: name, level range, creature type, rank, zone, plus every counter the addon keeps (times
  seen, kills, corpses looted, times it killed you, gold it paid).
- The creature's own art: portrait or 3D model, spell and item icons, item names in the game's
  quality colours, and the client's own tooltips on hover. No custom texture files ship with it.

## We do not have Forever's database

The server keeps its own creature, loot and spell tables **server-side, and they are not public**: no
addon, no client file and no datamine can read them. Anything an addon shows is either measured in
your own client or comes from a reference build. What that means here, concretely:

- Drop chances and the shape of every pool come from the **1.12 reference** (cmangos classic-db),
  not from Forever. That is a very good approximation for vanilla content and a **guess** for
  anything Forever changed or added.
- Content Forever added has **no reference at all**: custom creatures (ids in the `25xxxx`/`27xxxx`
  range) get their name and drops from play, the card says `no 1.12 data`, and they are deliberately
  left out of the progress bars — counting them would mean inventing a denominator.
- The same limit applies to **spell ids**: the client hands addons the spell as an opaque value, so
  the addon records that a creature cast *something* and shows the reference list beside it. A per
  spell "discovered" count is not possible on this client.
- Nothing is scraped at runtime and there is no hidden endpoint. The reference is a file generated
  offline and shipped with the addon; everything else is what your client reported.

## Data layers

Every screen separates the two, and never mixes them:

| Layer | Where it comes from | Trust |
|---|---|---|
| **MEDIDO** | events captured in your client: loot source -> creature id, drops, casts, kills, gold | what actually happened |
| **REFERENCIA** | a seed generated offline from the *cmangos classic-db* (vanilla 1.12) | an emulator's data, **not** measured in Forever |
| **NOMBRES** | an offline name/level table recorded in the beta by *warcraftforever.games* | third-party play sessions; only used when the client refuses to name a creature |

The measured layer is account-wide: one `GarchaDexDB`, shared by every character, and the seed
records which character saw what.

## Commands

| Command | What it does |
|---|---|
| `/gdx` | card for your current target |
| `/gdx <npcID>` | card for an id |
| `/gdx text` | the full card as text in chat |
| `/gdx progreso` | how complete the dex is, opens the progress tab |
| `/gdx stats` | counters |
| `/gdx news` | the discovery log |
| `/gdx loot` | the last loot events, raw (diagnostic) |
| `/gdx seed` | seed status and accessors |
| `/gdx art` | art audit: which atlases and texture paths this client actually has |
| `/gdx widget` | show the floating widget again |
| `/gdx lang es\|en\|auto` | language of the addon's own text |
| `/gdx wipe` / `/gdx wipe all` | clear measurements |

The window has two tabs: **Ficha** (one creature: what it casts and its drop pool) and
**Progreso** (two level-style bars, bestiary and drops, plus the numbers behind them). The
whole UI cost on screen is one floating widget: a small book icon, draggable, right click
hides it, `/gdx widget` brings it back.

## Updating

The client has no network access and the addon sandbox has no file IO, so **nothing inside the game
can ask GitHub for a release** — an addon cannot check for updates by itself. `tools/update.sh` is the
half that can: it asks the releases API and leaves the answer where the addon reads it.

```
tools/update.sh            # check only: prints installed vs latest, writes data/gdx_latest.lua
tools/update.sh --install  # download the release asset and replace the addon folder
```

With the stamp in place the window footer shows `a new version is out: x.y.z` until you update
(the deploy script preserves that file, the release does not ship it).

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
tools/                lua_check.py, api_check.py, text_audit.py, lua_table.py, build_seed.py, build_names.py, update.sh, deploy.sh
```

`tools/` is how the addon was developed against a client with no Lua interpreter available:
`lua_check.py` validates structure without executing anything, `api_check.py` validates every API
name used against a dump of the client's own API documentation, `text_audit.py` refuses a deploy that
would leak untranslated strings, `lua_table.py` reads the Lua tables this project writes (there is no
interpreter here), `build_seed.py` regenerates the reference seed, `update.sh` checks the latest
release, and `deploy.sh` copies the addon into the client and reports hash mismatches.

## Known gaps

- **Spell discovery cannot be counted per spell**: the id is opaque, so the card shows the reference
  list plus how many casts were seen — not "2 of 3 spells found".
- **Model variants** are the skins the reference template lists (up to four). The client picks one at
  spawn and does not expose which to addons, so a variant outside the template cannot be cycled.
- **An entry can be born from a corpse alone** (a group kill you never targeted). It takes its name
  from the unit under the cursor when the loot window opens; if nothing is there it stays as
  `npc <id>` until you target that creature again. `/gdx enrich` lists those entries and says why the
  name could not be read.
- **The reference is a snapshot**: Forever is a moving beta, so the 1.12 seed and the server disagree
  on some creatures, and the difference shows up in the card as `no 1.12 data`.

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

`data/gdx_names.lua` is generated by `tools/build_names.py` from **warcraftforever.games/npcs**, a
community record of the Forever beta made with the ForeverLog addon. It carries its provenance in the
file header and is only consulted when the client itself refuses to name a creature; nothing from it
overrides a name the client gave.
