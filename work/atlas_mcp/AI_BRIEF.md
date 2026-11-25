# Atlas, for an AI that is going to use it

Paste this into the other model's context. It is written for the consumer, not
for whoever maintains Atlas — everything here is a fact about using the
library, not about the code. `README.md` is the maintainer's document.

If the model speaks MCP, it does not need most of this: it will read the
server's own `instructions`, 15 tool descriptions and 6 prompts on connect,
which is about 3,250 tokens and always current. This file exists for a model
that cannot speak MCP, and for briefing a person.

## What it is

A catalogue of ~221,000 local game assets — Synty POLYGON packs and others — as
FBX and OBJ models, animation clips, texture atlases, audio, and built Unreal
assets. Most of it lives inside zip archives that are read in place and never
extracted.

It answers two kinds of question a file listing cannot: *what is in this
library*, and *what is actually inside this file* — a model's rig, bone names,
bounds, real authored size, and which textures it asks for.

## Connecting

### If the model is an MCP client

Register the server and it discovers everything itself. Absolute path, because
a relative one resolves against whatever directory the client happened to
launch in:

```bash
claude mcp add --scope user atlas -- python -I C:/Users/white/Documents/Codex/2026-07-08/woul/work/atlas_mcp/atlas_mcp.py
```

Or, for a client that reads a JSON config, the equivalent entry:

```json
{
  "mcpServers": {
    "atlas": {
      "command": "python",
      "args": ["-I", "C:/Users/white/Documents/Codex/2026-07-08/woul/work/atlas_mcp/atlas_mcp.py"]
    }
  }
}
```

The server needs nothing but Python and the standard library. There is no
virtualenv, no `pip install`, and nothing to keep up to date.

### If the model cannot speak MCP but can run commands

The transport is newline-delimited JSON-RPC 2.0 on stdin and stdout, so a
one-shot pipe works. `initialize` first, then the call. This asks what is in
the library:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"catalog_stats","arguments":{}}}' | python -I C:/Users/white/Documents/Codex/2026-07-08/woul/work/atlas_mcp/atlas_mcp.py
```

Swap the second line's `name` and `arguments` for any other tool. To see every
tool and its exact arguments, call `tools/list` the same way.

## Starting Atlas, if it is not already up

Eleven of the fourteen tools work whether or not the Atlas window is open.
Three do not — `inspect_model`, `rig_compatibility` and `render_asset` — and
they are the ones worth having, so get the window open first.

**Do not test for the window by looking for its file.** Atlas writes
`atlas_bridge.json` beside the catalog when it opens, and that file **survives
the process**. A descriptor written on 13 November, naming a port and a pid,
was still sitting there three days later with nothing listening on it. Its
presence means Atlas ran once, not that it is running now.

### Step 1 — ask

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"catalog_stats","arguments":{}}}' | python -I C:/Users/white/Documents/Codex/2026-07-08/woul/work/atlas_mcp/atlas_mcp.py
```

The last line of that report is the answer, and it is unambiguous:

```
Atlas itself: running, version 1.10.28 -- inspect_model, rig_compatibility and render_asset are available
```

or

```
Atlas itself: not running, so inspect_model, rig_compatibility and render_asset cannot answer
```

An MCP client calls `catalog_stats` instead of piping, for the same answer.

### Step 2 — start it, if that said "not running"

PowerShell, and **do not wait on the process** — it is a desktop application
and will not return until the window closes:

```powershell
Start-Process -FilePath "C:\Users\white\Documents\Codex\2026-07-08\woul\work\asset_atlas_native\build\windows\x64\runner\Release\asset_atlas_native.exe"
```

The executable needs the files beside it — `flutter_windows.dll`,
`sqlite3.dll`, `data\`, and `asset_atlas_mesh_importer.exe` — so launch it
where it sits. Do not copy the `.exe` elsewhere.

### Step 3 — wait for it, by asking again

The bridge came up **1.5 seconds** after launch when this was measured. Poll
`catalog_stats` every second or two and stop when its last line says
`running`. Give up after about 60 seconds and report that Atlas would not
start, rather than carrying on and reporting three tools as broken.

Nothing else is a reliable readiness signal. The process existing is not one:
the window has to reach the catalogue screen before the bridge is listening.

### When you are finished

**Leave Atlas running.** It belongs to the person at the keyboard, it may hold
unsaved state, and closing it costs them a relaunch. Do not kill the process,
and do not delete `atlas_bridge.json` — a stale descriptor is harmless,
because the server probes the port rather than trusting the file.

## Start here, every time

**`catalog_stats`.** It is the only tool that reports live state rather than
capability, and two of the things it says change what is worth trying:

- whether Atlas is running, which decides if three of the tools can answer;
- how many files have a known rig family, which decides whether the character
  and animation filters will return anything.

Then **`find_packs`** before searching for files. See "which copy" below.

## The tools

Eleven need only the catalogue and the FBX reader, and work whether or not
Atlas is open:

| Tool | For |
| --- | --- |
| `catalog_stats` | totals, scanned roots, live state. Start here. |
| `find_packs` | packs and the builds each ships. Takes `engine="5.4"`. |
| `search_assets` | the main search. Plain words, or `tag=`-style scoping. |
| `get_asset` | reads one file: rig, bone names, node names, bounds, units, textures. |
| `list_packs`, `browse` | walk the library by pack or folder. |
| `find_animations` | clips, optionally matched to a character's rig. |
| `find_attachments` | helmets, hair, capes and other kit for a character. |
| `get_texture` | a texture image. |
| `find_similar` | ranks assets by how they **look**. The only one that can. `kind=image` for a material, `kind=model` for a shape. |
| `find_duplicates` | redundant copies and the space they cost. |
| `export_assets` | writes assets out of their archives into a folder. |

Three need Atlas open and say so plainly when it is not:

| Tool | For |
| --- | --- |
| `inspect_model` | whether a model will arrive whole: which textures resolve, whether it is one model or a sheet or a kit, its real authored size. |
| `rig_compatibility` | whether a clip will drive a character, and how far their rest poses sit apart. |
| `render_asset` | a picture of a model, drawn by Atlas's own renderer. |

Six prompts hold the sequences worth following rather than improvising:
`survey_the_library`, `set_up_a_level`, `import_a_model`,
`animate_a_character`, `dress_a_character`, `choose_a_build`.

## Scoping a search

A plain query matches the name, the path and the tags together, which is right
most of the time and wrong when a word is common. `barrel` finds the barrel and
also everything in a folder called Barrels. A term can name its field instead:

```
tag=grungy name=door
type=model rig=polygon ext=fbx
name=dog or name=cat type=model
```

- Fields: `name`, `path`, `tag`, `type`, `ext`, `rig`. Anything else is
  refused by name rather than ignored.
- `name`, `path` and `tag` match a substring. `type`, `ext` and `rig` are
  exact, so `ext=fb` finds nothing and `type=mod` is refused.
- A space means and. `or` groups the terms either side of it and binds
  tighter, so the third example above is (dog or cat) and model. There are no
  parentheses.
- Quote a value to keep a space or an `=` inside it: `name="rubbish bin"`.
- `path=` sees the folders, which a plain term also does; `name=` is the way
  to exclude them.
- `type=` takes the resolved type -- `texture` is an image that a model uses
  or that sits in a textures folder, and `image` is the images that are not
  textures. The older `type` argument draws that one line differently:
  `type="image"` includes textures, where `type=image` excludes them. Every
  other value agrees between the two, `animation` included.
- `type=animation` works without a probe, from the folder name. See the data
  gaps at the end: it is a guess, and a good one.

The filter box in Atlas reads the same grammar, from the same shared fixture,
so a query that works in one works in the other.

## Six things that will produce wrong answers if you do not know them

**1. Names in this library lie.** `SK_` is Unreal's skeletal-mesh prefix and
these packs put it on three unrelated rigs; `SM_` is the static-mesh prefix
and sits on fully skinned characters. Prefer what `get_asset` reads out of the
file over what a name suggests. The *nouns* are reliable — `Barrel`, `Helmet`,
`RubbishBin` — the prefixes are not.

**2. Style words are not in the vocabulary of any *name*.** `grungy` matches 0
of 221,183 names; `gray` matches 0. So `search_assets` cannot answer "find me
something grungy", and asking it to returns nothing or a handful of accidents.

**Use `find_similar` for appearance.** It ranks pictures against your words,
so an adjective nobody indexed still works. Four things about it:

- **Ask for one kind.** `kind=model` ranks pictures *drawn from* models and
  answers about shape. `kind=image` ranks the texture, atlas and sprite files
  themselves and answers about material — "scuffed dark metal", "rough bare
  brickwork". A shape question asked of both competes with whatever texture
  suits the words, and the other way round. The default is both.
- **Narrow it with `folder` or `pack`.** 28,490 of this library's 34,986
  images are one icon pack, so an unnarrowed material question is mostly
  answered with icons. Dressing a scene from one pack, pass that pack.
- The scores are cosines from a sigmoid-trained model. Real matches sit around
  **0.05 to 0.18** against words, and around **0.9** against another picture.
  Read the order; a score of 0.12 is not a bad match, and thresholding these
  numbers will throw away the right answer.
- It only sees what has been embedded, and says how many vectors it searched.
  That number is the real limit on its answer.

For *what a thing is*, keep using `search_assets` — the nouns in these names
are reliable.

**3. Each pack ships several times over** — the source files, and a built
project per engine version — and which engine a build targets is recorded only
in the archive name. An `.uasset` does not say. So ask `find_packs` first, and
take one build, not two:

- a **source** build is FBX and OBJ: imports anywhere, you choose the settings
  and redo the materials;
- an **unreal** build is `.uasset` and `.umap` only: drops straight into a
  project of that exact version with materials intact, and carries no geometry
  anything outside the engine can read.

**4. A great deal of the library is duplicate files.** 34,801 FBX rows are
18,948 distinct files by name and size, and the same holds across the other
formats. `search_assets` collapses identical ones by default and says
how many there were, so a match count is not a count of distinct assets unless
the tool says it collapsed them. Copies of a *source* asset are
interchangeable; a copy from an unreal build is only useful to that engine
version.

**5. Run `inspect_model` before importing anything.** A name and a file size
do not say whether a model arrives whole. It reports which materials got their
textures and which draw flat; whether the file is one model, a sheet of a
dozen characters standing in one place, or a kit whose every part ships
together; and the **real authored size**, which is what decides the import
scale. Nothing visible tells you that last one — the viewer fits a rivet and a
cathedral into the same box, and a prop landing a hundred times too large is
the commonest way this goes wrong.

**6. The rig question is two questions.** `rig_compatibility` answers both and
either can sink a clip. *Shared bone count*: zero means the clip cannot drive
that character at all, which is the normal case across rig families — the
Polygon and Sidekick rigs share no bone names whatsoever. *Rest-pose
difference in degrees*: all bones shared but around 90 degrees apart means the
clip plays and the limbs sit wrong until something retargets it.

## Known gaps in the data, as of 2026-11-16

Not bugs in the tools; they change what the answers are worth.

- **`rig_family` and `model_kind` are filled in for all 34,801 FBX files**,
  as of 2026-11-18. `search_assets type="character"` answers with 1,021
  distinct characters and `find_animations` matches on rig over 787 clips.
  Of the 34,801, 2,019 are on a recognised rig — 1,204 sidekick, 474
  polygon, 341 unreal — and the other 32,782 are static meshes with no rig,
  which is what most of a prop library is.

  Atlas fills both lazily as filters ask, and an ordinary rescan keeps what
  is already known for every file whose size has not changed. Files added by
  a rescan have no rig recorded until something asks, and a *forced* rescan
  clears the lot. Either way `backfill_rigs.py` fills the gaps in one pass.
  `catalog_stats` says which state it is in; believe it over this file.

- **`type="animation"` is the exception, and does work.** Where `model_kind`
  is unset the folder decides: an FBX under a directory named `Animations`,
  `Anim`, `Anims`, or beginning `Animation`, is taken to be a clip. That
  finds **801** where the column alone found none. Checked against the
  importer on 100 sampled files — right 98% of the time, and it misses none;
  the one error was a reference character mesh shipped inside an animation
  pack. Two limits follow from it being a guess: a probed answer always wins
  over it, and it says nothing about bones, so `rig_compatibility` still
  needs a real probe and will tell you when it has not got one.

- **Visual coverage of models is complete.** All 31,491 distinct renderable
  models are embedded. Four are not and never will be: three animation-only
  FBX files the catalog classified as models, and one OBJ with no geometry.
- **Visual coverage of images is complete too**, as of 2026-11-18: 32,084
  distinct textures, atlases and sprites. Four are not embedded and will not
  be — two JPEGs inside archives that are not zip files, a 177.7 MB PSD over
  the one-image cap, and a PSD with no readable composite.

- **Some rows should not be in the store.** The store holds 34,343 image
  vectors but ranks 32,084: the other 2,259 are images under a Unity
  project's package cache, embedded before there was a rule against them —
  documentation screenshots, not assets. The search drops them, so they
  cannot answer, but the vector file is append-only and still holds them.

`catalog_stats` reports the current state of these.

The older gap in this file — 49 unindexed archives, including both INTERFACE
HUD sprite packs — **is closed.** A rescan has happened: the catalogue holds
221,183 rows across 341 archives, and the UI sprites are in it.
