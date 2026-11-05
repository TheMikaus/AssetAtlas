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
| `search_assets` | "what have I got called X?" Terms are ANDed across name, path and tags, so `jump femn` finds `A_Jump_Running_Femn.fbx`. Filter by `type`, `pack`, `folder`, `ext`. |
| `get_asset` | Everything about one file: catalog entry, then the file itself — geometry counts, bounds, units, rig family, bone count, materials, the textures it asks for, and the images sitting beside it. `inspect: "full"` also lists every node and bone. |
| `list_packs` | One row per pack, with files / meshes / clips / textures / Unreal assets. |
| `browse` | The folder tree, one level per call, like the Atlas folder pane. |
| `catalog_stats` | Totals, scanned roots, and where the data is thin. |
| `find_animations` | Clips, optionally only those on a given rig. Pass a character's path and the rig is read off that character. Matching means reading each clip, so it is slower than a search. |
| `find_attachments` | Kit in a character's own pack that could be worn on it, grouped by body part. |
| `get_texture` | Hands back an image so it can be looked at rather than described. |

Paths look like `zip:<archive>::<entry>` for files inside an archive. Pass them
back verbatim; the server reads the entry out of the zip in place.

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

39 of them, over a catalog the tests build themselves — the protocol handshake,
the search semantics, the folder walk, and a mirror test that reads the
`attachPoints` table out of `lib/main.dart` and fails if the copy here has
drifted from it. That table is restated in a second language, which is the kind
of duplication that goes quietly wrong.
