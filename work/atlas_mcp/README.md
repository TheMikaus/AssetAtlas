# Atlas over MCP

Lets a model ask Atlas about the asset library: search it, walk its folders,
and read individual files — a model's rig, bone count, node names, bounds,
units and which textures it asks for.

It talks to the two things Atlas is built on rather than to Atlas itself:

- the **catalog**, a SQLite file, read-only — Atlas owns that file and a
  browsing tool has no business writing to it;
- the **FBX reader**, `asset_atlas_mesh_importer.exe`, the same executable the
  app shells out to.

Neither needs the app running, so the server works whether Atlas is open or
closed. The search semantics deliberately mirror the app's (`assetMatchesSearch`
and `AssetItem.effectiveType` in `lib/main.dart`): the same question asked here
and in the Atlas window should not come back with different answers.

## Installing

`.mcp.json` at the repository root already registers it for this project:

```json
{ "mcpServers": { "atlas": { "command": "python", "args": ["-I", "work/atlas_mcp/atlas_mcp.py"] } } }
```

To use it everywhere rather than in this checkout, register it globally with an
absolute path:

```bash
claude mcp add --scope user atlas -- python -I C:/Users/white/Documents/Codex/2026-07-08/woul/work/atlas_mcp/atlas_mcp.py
```

Standard library only, on purpose. No virtualenv, no `pip install`, nothing to
go stale — "pip install failed inside an MCP launch" is a worse failure than
the hundred lines of JSON-RPC it would have saved.

Check it without a client:

```bash
python -I work/atlas_mcp/atlas_mcp.py --selftest
```

## What it finds by default

| | |
| --- | --- |
| catalog | `%APPDATA%\com.example\asset_atlas_native\asset_atlas_native.db` |
| FBX reader | beside this file, else the repo's `build/.../Release` |
| read cache | `%LOCALAPPDATA%\atlas-mcp\summary-cache.json` |

Override any of them with `ATLAS_MCP_DB`, `ATLAS_MCP_IMPORTER`,
`ATLAS_MCP_CACHE`.

Reading a big FBX is not cheap — the 261,410-face Polygon mech takes about
twelve seconds — so every read is cached by the file's size and timestamp.

## Tools

| Tool | Answers |
| --- | --- |
| `search_assets` | "what have I got called X?" Terms are ANDed across name, path and tags, so `jump femn` finds `A_Jump_Running_Femn.fbx`. Filter by `type`, `pack`, `folder`, `ext`, and by `build` / `engine` for a particular engine build. Identical copies collapse by default. |
| `get_asset` | Everything about one file: catalog entry, then the file itself — geometry counts, bounds, units, rig family, bone count, materials, the textures it asks for, and the images sitting beside it. `inspect: "full"` also lists every node and bone. |
| `list_packs` | One row per pack, with files / meshes / clips / textures / Unreal assets. |
| `browse` | The folder tree, one level per call, like the Atlas folder pane. |
| `catalog_stats` | Totals, scanned roots, and where the data is thin. |
| `find_animations` | Clips, optionally only those on a given rig. Pass a character's path and the rig is read off that character. Matching means reading each clip, so it is slower than a search. |
| `find_attachments` | Kit in a character's own pack that could be worn on it, grouped by body part. |
| `get_texture` | Hands back an image so it can be looked at rather than described. |
| `find_packs` | One row per **pack** rather than per archive, with the builds it ships -- source files, and Unreal or Unity per engine version. Takes `engine="5.4"`. Start here. |
| `find_duplicates` | What the library holds more than one copy of, biggest waste first. |
| `export_assets` | Writes assets out of their archives into a folder, keeping archive-relative paths. The step that turns a search into files. |
| `inspect_model` | Whether a model is actually usable: which textures resolve, whether it is one model or a sheet or a kit, its real authored size, its rig, the kit pieces that fit it. **Needs Atlas running.** |
| `rig_compatibility` | Whether a clip will drive a character, and how far apart their rest poses sit. **Needs Atlas running.** |
| `render_asset` | Draws a model with Atlas's own renderer and hands back the picture. **Needs Atlas running.** |

Paths look like `zip:<archive>::<entry>` for files inside an archive. Pass them
back verbatim; the server reads the entry out of the zip in place.

## Building in Unreal

A pack arrives several times over, and only the archive name says which engine
a build targets -- an `.uasset` does not. So ask `find_packs` first:

```
find_packs(query="dungeon")        -> which packs exist, and their builds
find_packs(engine="5.4")           -> packs with a 5.4 build
search_assets(query="crate", engine="5.4")
export_assets(dest="D:/MyGame/Content", pack="CityZombies", engine="5.4")
```

A **source** build holds FBX and OBJ: that is what `get_asset` can read
geometry, rigs and bounds out of, and what you import yourself. An **unreal**
build holds `.uasset` and `.umap` only -- no geometry readable outside the
engine, and tied to its engine version -- but it is what drops straight into a
project, materials and blueprints included.

`export_assets` requires a destination and a selection, keeps files already
there unless `overwrite=true`, never deletes anything, and refuses archive
entries whose names would write outside the destination.

## The three tools that need Atlas open

Most of this server reads the catalog and the FBX reader directly and works
whether or not the app is running. Three tools do not, because what they
answer is not in the database: does this model's textures resolve, is this
file one model or a sheet of twelve, will this clip drive that character.
Atlas computes all of it already, and restating any of it here would be a
second copy of load-bearing logic drifting out of step with the one the app
uses.

So those three ask the app. Atlas opens a loopback HTTP server when its window
opens and writes the port and a token to `atlas_bridge.json` beside the
catalog; this server reads that file. Nothing is exposed off the machine, and
a request without the token is refused.

```
inspect_model(path="...SK_Dungeon_GoblinChief_01.fbx")
rig_compatibility(character="...GoblinChief_01.fbx", clip="...A_Idle.fbx")
render_asset(path="...SM_Prop_RubbishBin_02.fbx", size=512)
```

With Atlas closed they say so and name the alternative; everything else keeps
working. `catalog_stats` reports whether the app is up.

`inspect_model` is the tool to run before importing anything: a name and a
file size do not say whether a model will arrive whole. It reports the real
authored size too, which is the number that decides whether a prop lands in a
level a hundred times too big.

## Prompts: the sequences, written down

A tool description says what one tool does. It does not say what order to
call six of them in, and that is the part a model gets wrong here -- it will
search for files before asking which build of the pack it wants, or import a
prop without ever asking how big the prop is. So the six sequences this
library gets asked for are served as MCP prompts:

| Prompt | For |
| --- | --- |
| `survey_the_library` | Orientation. What is here, what the catalog knows, and the two things that mislead. |
| `set_up_a_level` | `theme`, `engine` -- packs to exported files for a themed level. |
| `import_a_model` | `asset` -- the check to run before spending an import. |
| `animate_a_character` | `character`, `motion` -- the rig question, which is two questions. |
| `dress_a_character` | `character` -- helmets, hair, capes, and what the attach point is not. |
| `choose_a_build` | `pack`, `engine` -- source files or a built project. |

Every argument is optional, because a client may offer a prompt with none of
them filled in. An absent one reads as `Theme: (not given -- ask, or see the
themes find_packs lists)` on its own labelled line, rather than being
interpolated into the middle of a sentence -- which is how "Get the assets for
a the theme you want level" happened, and is what
`test_an_absent_argument_never_lands_inside_a_sentence` now pins.

The prompts name tools, so they can drift when a tool is renamed. A test
reads every tool name out of a rendered prompt and fails on one this server
does not have.

## The rig_family gap

Atlas fills `rig_family` in lazily — it reads a file when a filter needs the
answer. That is right for an app, and it leaves the column nearly empty: 7 of
27,652 FBX files at the time of writing. `search_assets type=character` and
`find_animations rig=...` lean on it, and `catalog_stats` says so.

`backfill_rigs.py` fills it in one pass, about a minute over the whole library.
**Close Atlas first** — it writes to the database Atlas owns.

```bash
python -I work/atlas_mcp/backfill_rigs.py --dry-run
python -I work/atlas_mcp/backfill_rigs.py
```

It fixes the rig filter inside Atlas too, for the same reason.

## Tests

```bash
cd work/atlas_mcp && python -I -m unittest
```

122 of them, over catalogs the tests build themselves — the protocol handshake,
the search semantics, the folder walk, and a mirror test that reads the
`attachPoints` table out of `lib/main.dart` and fails if the copy here has
drifted from it. That table is restated in a second language, which is the kind
of duplication that goes quietly wrong.
