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
the hundred lines of JSON-RPC it would have saved. Visual tagging is the one
thing that needs more than the standard library, and it is kept in a separate
component for that reason — see "Visual tagging" below.

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
answer. That is right for an app, and it leaves the column nearly empty, which
is what `search_assets type=character` and `find_animations rig=...` lean on.
Every rescan empties it again, and `catalog_stats` says which state it is in.

`backfill_rigs.py` fills it in one pass, a few minutes over the whole library
with twelve workers. Run over all 34,801 FBX files it read every one and found
2,019 on a recognised rig — 1,204 sidekick, 474 polygon, 341 unreal — with
32,782 static meshes carrying no rig at all, which is what most of a prop
library is. **Close Atlas first** — it writes to the database Atlas owns.

```bash
python -I work/atlas_mcp/backfill_rigs.py --dry-run
python -I work/atlas_mcp/backfill_rigs.py
```

It fixes the rig filter inside Atlas too, for the same reason.

## Visual tagging: dependencies and installation

Everything above runs on the standard library. Visual tagging does not: it
embeds a render of a model, and a texture, into a vector space shared with
text, so that "find grungy models" can be answered by similarity rather than
by hoping the word appears in a file name. It appears in none — `grungy`
matches 0 of 73,865 names here, `gray` matches 0.

The vectors are stored by `embedding_store.py`, which *is* standard library
only. The model that produces them is not, and lives outside the server. See
`DECISIONS.md` EMB-001 and EMB-002 for why the split falls there.

### Python packages

| Package | Verified version | Licence | Needed for | In the installer? |
| --- | --- | --- | --- | --- |
| `onnxruntime` | 1.22.0 | MIT | running the model | No — the shipped app uses the C++ `onnxruntime.dll` |
| `numpy` | 1.26.4 | BSD-3-Clause | pulled in by onnxruntime | No |
| `Pillow` | 11.2.1 | MIT-CMU | decoding a rendered PNG in dev scripts | No — Atlas will hand the tagger raw pixels |
| `sentencepiece` | 0.2.3 | Apache-2.0 | tokenising a **text query** | No — the tagger links SentencePiece in C++ |

```bash
python -m pip install onnxruntime sentencepiece
```

**A trap worth knowing.** The MCP server is launched as `python -I ...`, and
`-I` implies `-s`, which drops the user `site-packages` — exactly where pip
puts these on a Microsoft Store Python. So `python -I` cannot import
onnxruntime even when it is installed. That is harmless for the server, which
never imports it, but any tagging script must be run with plain `python`, or
with `python -P` when it reads downloaded files (`-P` keeps the current
directory off `sys.path` without hiding site-packages).

### Model files

SigLIP 2 base, patch16, 224px. Upstream
[`google/siglip2-base-patch16-224`](https://huggingface.co/google/siglip2-base-patch16-224)
is **apache-2.0** and not gated; the pre-exported ONNX copies come from
[`onnx-community/siglip2-base-patch16-224-ONNX`](https://huggingface.co/onnx-community/siglip2-base-patch16-224-ONNX).

Fetch into `work/atlas_mcp/models/siglip2-base-patch16-224/`, which is
gitignored:

```bash
BASE=https://huggingface.co/onnx-community/siglip2-base-patch16-224-ONNX/resolve/main
curl -sSL -o vision_model_bnb4.onnx "$BASE/onnx/vision_model_bnb4.onnx"
curl -sSL -o text_model_int8.onnx   "$BASE/onnx/text_model_int8.onnx"
curl -sSL -o tokenizer.model        "$BASE/tokenizer.model"
curl -sSL -o config.json            "$BASE/config.json"
curl -sSL -o preprocessor_config.json "$BASE/preprocessor_config.json"
```

Verify by exact byte count — a truncated download is otherwise a model that
loads and returns nonsense:

| File | Bytes | Role |
| --- | --- | --- |
| `vision_model_bnb4.onnx` | 57,554,105 | embeds a render. **Fastest working.** |
| `vision_model_q4f16.onnx` | 54,630,849 | smaller, slightly slower |
| `vision_model_fp16.onnx` | 186,039,516 | reference quality |
| `vision_model_int8.onnx` | 94,553,333 | **does not run — see below** |
| `text_model_int8.onnx` | 283,438,275 | embeds a query |
| `tokenizer.model` | 4,241,003 | SentencePiece vocabulary |
| `config.json` | 435 | |
| `preprocessor_config.json` | 394 | 224x224, mean 0.5, std 0.5, rescale 1/255 |

The repository also holds fp32 and `q4` variants and a combined `model.onnx`;
the whole repo is about 11GB and you need three files of it.

### Verified behaviour

Measured here on the CPU provider, onnxruntime 1.22.0:

| Variant | Size | Loads | Batch of 8 | Output |
| --- | --- | --- | --- | --- |
| `vision_model_bnb4` | 57.6 MB | 199 ms | **74 ms/image** | `pooler_output` (1, 768) |
| `vision_model_q4f16` | 54.6 MB | 445 ms | 90 ms/image | `pooler_output` (1, 768) |
| `vision_model_fp16` | 186.0 MB | 455 ms | 93 ms/image | `pooler_output` (1, 768) |
| `vision_model_int8` | 94.6 MB | **fails** | — | — |
| `text_model_int8` | 283.4 MB | 734 ms | 120 ms/query | `pooler_output` (1, 768) |

- **`vision_model_int8.onnx` does not run.** `NOT_IMPLEMENTED: Could not find
  an implementation for ConvInteger(10)` — onnxruntime's CPU provider has no
  kernel for the quantised patch-embedding convolution. `model_quantized` and
  `model_uint8` are byte-identical to it and fail the same way. Use `bnb4`,
  whose 4-bit `MatMulNBits` path is supported and which is also 37 MB smaller.
- **Take `pooler_output`, not `last_hidden_state`.** The latter is (1, 196,
  768) — one vector per patch. The embedding is the pooled (1, 768), and 768
  is the dimension `embedding_store` must be created with.
- 13,933 distinct FBX at 74 ms/image is about **17 min single-threaded** for a
  full library pass, before import and render time.

### Tokenising a query

`tokenizer_config.json` says `GemmaTokenizer`, `do_lower_case: true`, and
`model_input_names: ['input_ids']` — matching the graph, which takes ids and
nothing else. It does **not** say whether SigLIP's convention appends `<eos>`,
prepends `<bos>`, or pads to a fixed width, and getting that wrong does not
raise: it returns a plausible vector that ranks badly.

What is used, and verified below:

1. lowercase, strip punctuation, collapse whitespace;
2. `sentencepiece` encode against `tokenizer.model`;
3. prepend `<bos>` (id 2), append `<eos>` (id 1);
4. pad to exactly 64 with `<pad>` (id 0), truncating past that.

All four combinations of `<bos>`/`<eos>` were measured against two renders
whose subjects are known. Every one ranked both captions onto the right
picture, and the margins sat between +0.2045 and +0.2108 — so the convention
is not load-bearing here, which is worth knowing before anyone spends a day
on it. The one above is used because it scored highest, by a margin inside
the noise.

### Verified ranking

Two Atlas renders, a rubbish bin and the 215-node mech, embedded with
`vision_model_bnb4`; captions through `text_model_int8`; cosine of
L2-normalised `pooler_output`:

| Query | vs bin | vs mech |
| --- | --- | --- |
| "a low poly rubbish bin" | **+0.1614** | +0.0656 |
| "a giant robot mech with weapons" | +0.0458 | **+0.1608** |

Content separates by roughly 2.5x. Absolute values are small because SigLIP
trains with a sigmoid loss rather than a softmax over a batch; only the
ranking is meaningful, so do not treat 0.16 as "16% similar".

**Style words separate far more weakly than content words:**

| Query | vs bin | vs mech |
| --- | --- | --- |
| "grungy and weathered" | +0.0610 | +0.0528 |
| "clean and futuristic" | +0.0802 | +0.0840 |
| "a character" | +0.0575 | +0.0878 |
| "a building" | +0.0508 | +0.0583 |

This is the measurement behind the design: a render carries shape, and style
lives in the texture. A model whose materials did not resolve renders grey,
and grey tells a style query nothing — which is why texture-derived tags are
not a nicety here but the half that answers "grungy", propagated to the models
that reference the texture. `inspect_model` already reports how many of a
model's materials resolved, so the confidence of a render-derived style tag is
knowable per asset.

### What is not measured

The runtime's disk footprint, if it were ever shipped beside the app, which
would be the size of `onnxruntime.dll` alone. The published
`onnxruntime-win-x64-1.32.0.zip` is 96,945,131 bytes, but that archive carries
headers, import libraries and test data, and only the DLL would ship.

## Running the tagging pass

Nothing can be ranked by appearance until something has looked at it. There
are two passes, over one store.

**Models** are rendered through Atlas's own renderer and the picture is
embedded:

```bash
python -P work/atlas_mcp/tag_assets.py --pack POLYGON_Town --limit 200
```

**Atlas has to be running** for that one — the renderer being used is its own,
deliberately, so the picture being embedded is the picture the app shows you.
The script checks by probing the bridge port, not by looking for
`atlas_bridge.json`, which outlives the process.

**Images** need no renderer, because the file already is the picture, so this
one runs with Atlas closed:

```bash
python -I work/atlas_mcp/tag_images.py --pack POLYGON_Town
```

Both are resumable, sliceable the same way, and write through the same worker,
so they cannot disagree about what is done.

### What it costs

For models the render is the whole job. Measured on this library:

| | |
| --- | --- |
| render, walking one archive in order | **972 ms** median |
| render, jumping between archives | 1,570 ms median |
| embed, batches of eight | **9 ms** per image |
| distinct models to do | **31,495** |
| the completed pass | **12.9 h** of work over 17.3 h |

That pass is **done**: 31,491 embedded, and the four that are not are an OBJ
with no geometry and three animation-only FBX files.

For images the decode is the job, and the model is a third of it:

| | |
| --- | --- |
| decode a 2048x2048 PNG | **95 ms** |
| prepare it for the model (composite, resize) | ~190 ms more |
| embed | 9 ms |
| distinct images to do | **32,088** |
| measured rate, four threads | **3 to 5 an second** |

`_pixels` composites and converts at full resolution before the resize throws
almost all of it away, which is why preparing costs twice the decode. It is
left alone deliberately: the 31,491 model vectors were prepared that way, and
a vector prepared differently cannot be ranked against them. What is
parallelised instead is the batch, which does not change a pixel.

2,898 images are excluded: a Unity project's `PackageCache` and
`Documentation~` folders are in the catalog because the scan walked the whole
project, and they are not assets. The first texture query run against the
store answered with three render-pipeline documentation figures and two
film-grain overlays, because a photograph of a scuffed floor beats a tiling
texture of one at looking like a scuffed floor.

So it is an overnight job, and three things follow:

- **It is resumable.** Nothing records what is left — whatever has no vector is
  the work. Ctrl-C and rerun loses at most the batch in flight, because the
  store publishes vectors, then the count, then the index, in that order.
- **It is sliceable.** `--folder`, `--pack` and `--ext` take a slice, so the
  packs you are building with now get tagged in minutes instead of queueing
  behind 30,000 files you do not need yet.
- **It stays out of the way.** The embedder gets two threads, the process runs
  below normal priority, and `--pace-ms` puts a gap between renders. The
  defaults do not saturate the machine on purpose.

Duplicates are collapsed before anything is rendered: 34,801 FBX rows are
18,948 distinct files by name and size, so the pass is 45% shorter than the
row count suggests.

`--dry-run` lists what it would render and stops.

### Then searching it

```bash
python -P work/atlas_mcp/atlas_embed.py --probe
```

checks both towers load. Over MCP, `find_similar` is the tool:

- `text="a grungy metal barrel"` ranks by appearance against words.
- `like_path=...` ranks by appearance against another asset.
- `kind=model` ranks only pictures drawn from models, `kind=image` only the
  texture, atlas and sprite files themselves. A material lives in the texture
  and a shape in the model, so asking for one keeps the other out of the way.
- `folder=` and `pack=` narrow it, which matters most for images: 28,490 of
  the 34,986 are one icon pack.

Read the order, never the magnitude. Text-to-image cosines land around 0.05 to
0.18 and image-to-image around 0.9 — the same "closest thing there is", an
order of magnitude apart, because text and image vectors occupy different
regions of the space. A threshold that looked sensible for one throws away
every answer for the other.

Only embedded assets can be returned, and the tool says how many it searched.
That number is the real limit on its answer.

### What a search costs

The server keeps one `atlas_embed.py --serve` child alive and asks it, rather
than starting one per question. The text tower is a 283 MB int8 file and
building a session over it takes about 1.6 s, which a process per query paid
every time:

| | |
| --- | --- |
| first question of a session | **7.7 s** (the model loads) |
| every question after it | **390 ms** |
| before, every question | 5 to 11 s |

The child notices rows that appeared since it last answered, so a search run
during a tagging pass stays current — two consecutive questions reported
35,779 and then 35,819 vectors while the image pass was running. It is
replaced if it dies, and nothing but the first question pays for the model.

## Tests

```bash
cd work/atlas_mcp && python -m unittest
```

255 of them, over catalogs and stores the tests build themselves — the protocol
handshake, the search semantics, the folder walk, the store's crash windows,
the tagging pass's candidate query and resume rule.

Not `-I` here, despite the rule elsewhere in this file: `-I` implies `-s`,
which hides the user site-packages where numpy, Pillow, onnxruntime and
sentencepiece live, and the tests that need them would quietly skip. The tests
that load the SigLIP files skip themselves when the files are absent, so a
checkout without the 420 MB of weights still runs the rest.

Two of these guard against duplication that goes quietly wrong, both being
restatements in a second language:

- the `attachPoints` table, read out of `lib/main.dart`;
- the **search grammar**, which the app and this server both implement. Neither
  owns it: `fixtures/search_queries.json` does, and both suites read that same
  file. A case added there fails on whichever side has not caught up.
