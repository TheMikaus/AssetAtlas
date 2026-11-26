# Architecture

Status: Partially verified. This file documents **implemented** architecture,
not aspirations. Only the sections marked Verified have been read out of
source in this workspace; the rest is still pending inspection.

> The detailed Atlas architecture — the two-process FBX pipeline, the
> rasteriser, the rig families, the catalog schema, the Windows crash
> gotchas — is currently in `CLAUDE.old.md`, which is **not** on the
> automatically loaded path. Migrating it here is unstarted and unapproved.

## Selected engine and framework
- **Engine: not applicable.** Per user directive (2026-11-14), no engine rule
  applies to this repository. It is a Flutter Windows desktop application
  whose *subject* is game assets; it is not itself a game project. The generic
  behaviour contract in `CLAUDE.md` applies, and `.claude/rules/` is for other
  projects in this set.
- Framework: Flutter (Windows desktop), Dart. All app code in a single
  `work/asset_atlas_native/lib/main.dart`.
- Playdate framework: not applicable.

## Components and responsibilities

### Verified — embedding store (`work/atlas_mcp/embedding_store.py`)
- Owns one float32 vector per asset for visual similarity search, in two
  files beside the catalog in the app support directory:
  - `embeddings.f32` — 64-byte header (`magic`, `version`, `dims`, `count`,
    `model_id`, reserved) followed by `count × dims` float32, fixed stride.
  - `embeddings_index.sqlite` — `embedding_index(asset_id PRIMARY KEY, row,
    source, computed_ms)`.
- `source` distinguishes a vector derived from a **render** of the model's
  geometry from one derived from a **texture** the model references.
- Verified — the values written are `render` (48,148 rows) and `image`
  (90,599 rows) as of 2026-11-25. Atlas reads that split for the tagging
  strip (`readTaggedCounts`) and writes nothing here; see DECISIONS.md
  TAG-002.
- Deliberately **not** in `catalog_assets`; see DECISIONS.md EMB-001. The
  catalog schema stays at v7 and Atlas keeps sole ownership of it.
- Crash safety is an ordering property, enforced inside the module because it
  spans both files: vectors are written past the committed count, then the
  header count is raised, then the index is committed. A crash leaves
  unpublished bytes (ignored) or unindexed rows (wasted, harmless), never an
  index row naming a vector that does not exist.
- A reader clamps to `min(header.count, (filesize - 64) / stride)`, so a
  truncated file or a count ahead of the bytes cannot hand out a vector made
  of whatever followed.
- `model_id` in the header invalidates the whole store on a model change:
  opening with a different expectation reports zero usable rows.
- An open mapping holds the file open on Windows, as an open zip handle does
  elsewhere in this project, so `close()` releases it — and reports which
  call to fix when a caller's `memoryview` is still alive.

### Pending source inspection
- The Flutter app (`work/asset_atlas_native/lib/main.dart`): UI, scanning,
  ZIP handling, mesh import, rasteriser, database layer.
- The MCP server (`work/atlas_mcp/atlas_mcp.py`): 14 tools, 6 prompts, and
  the loopback bridge to the running app.
- `asset_atlas_mesh_importer.exe` (`windows/runner/mesh_importer.cpp`).

## Proposed — not implemented

Kept separate from the above on purpose. Nothing below exists in source.

- `asset_atlas_tagger.exe` — a third native executable alongside the mesh
  importer, which text-encodes a query, maps `embeddings.f32`, and returns
  top-N asset ids. Needed because a pure-stdlib search costs 1,234 ms; see
  DECISIONS.md EMB-002. **Blocked** on approval for onnxruntime and SigLIP 2
  weights in the installer.
- An in-Atlas tagging queue (`startAssetTagging`), mirroring the existing
  `startFolderScan` / `buildFbxClassifyChunks` structure, so a newly added
  folder is embedded on a worker isolate with throttling and cancel.

## Data and control flow
- Pending source inspection, except the embedding store writes described above
  and the list pipeline below.
- Verified — how a row reaches the list (`lib/main.dart`): `assets` (the whole
  catalog) → `sortedAssets`, memoised per (catalog revision, sort mode) and
  per `_listEpoch` only in `type` mode → `_assetsMatching`, one pass per
  predicate with every filter and the query, memoised on a key naming every
  input → `collapseAssetVersions`, one row per model per pack → the rows the
  `AssetList` or `AssetGrid` builds. Two passes run per rebuild: the list and
  the count's denominator, each with its own cache.
- Verified — the catalog-wide indexes (`rigIndexFor`, `twinIndexFor`,
  `_textureIndexOf`, `_unityBuildIndex`, `findNearbyTextures`) are each built
  once per catalog on first use, keyed on
  `identityHashCode(allAssets) ^ allAssets.length`, and are built on the UI
  thread by whichever interaction asks first. Nothing that runs per asset may
  construct a `RegExp` or search a path with one — see DECISIONS.md PERF-001,
  and `test/select_and_switch_cost_test.dart` for what each stage costs.
- Verified — how a model reaches the viewer (`lib/main.dart`): `loadMeshModel`
  → `importFbxWithUfbx` → `runMeshImporterOffThread`, which runs
  `asset_atlas_mesh_importer.exe` and drains its stdout **on a worker
  isolate**, then `jsonDecode` and `meshModelFromImporterJson` on the UI
  isolate (the mesh holds `ui.Image` textures, which cannot cross an isolate
  boundary). The drain is off the UI isolate because a Windows pipe holds
  about 64 KB and a 705 KB model prints 5.3 MB: draining it on the UI isolate
  needed more than 60 turns of the event loop, which is minutes when the
  window is busy. See DECISIONS.md PERF-002. Probes (`--probe`, tens of
  bytes) still drain on the caller's isolate.
- Verified — the UI isolate also rasterises **animated** frames inline
  (`RasterModelView._render` takes the `rasterizeScene` branch whenever a
  `sceneOverride` is given) and skins the character once per clip frame in
  `build`. Every other frame goes to `RenderWorker.shared`. Thumbnails
  (`ModelThumbnailCache`, two at a time, queue capped at 48) flatten and
  rasterise on the UI isolate as well.
- Verified — the texture filter validates models lazily: the filter pass
  queues every model with no verdict, the queue imports three at a time, and
  the verdicts are folded into the list once per 1,500 ms burst
  (`ListRefreshCoalescer`) rather than once per file. See DECISIONS.md
  PERF-004.
- Verified — `UiStallWatchdog` (started beside the bridge, stopped in
  `dispose`) logs any gap over 750 ms between its own 250 ms ticks, with a
  tally of the stages that ran. It is the only thing in the app that can say
  what froze the window; see DECISIONS.md OBS-001.

## Interfaces and dependencies
- Verified: `embedding_store.py` uses the standard library only (`array`,
  `mmap`, `os`, `sqlite3`, `struct`), consistent with the rest of
  `work/atlas_mcp/`.
- Proposed and unapproved: onnxruntime and SigLIP 2 (Apache-2.0) weights,
  for the tagger executable only.

## Build, test, and asset pipelines
- Verified: `python test_embedding_store.py` from `work/atlas_mcp/` — 32
  tests. `python test_atlas_mcp.py` — 122 tests.
- Pending: the Flutter gate (`flutter analyze`, `flutter test`) is documented
  in `CLAUDE.old.md`; its standing in the new contract is unresolved, since
  both write generated output.

## Source references and verification
- `work/atlas_mcp/embedding_store.py` — read and implemented 2026-11-14.
- `work/atlas_mcp/test_embedding_store.py` — 32 tests passing 2026-11-14.
- Catalog inventory counts verified 2026-11-14 against the live catalog,
  read-only.

## Known discrepancies
- `CLAUDE.old.md` holds the Atlas-specific knowledge this file does not, and
  is not loaded automatically. Risk: the gotchas that prevent real damage
  (`Tooltip` inside `ToggleButtons` crashing `flutter_windows.dll`,
  `bump_version.ps1` owning both version literals, `closeCachedArchives()` in
  teardown) do not reach a session by default.
- Closed 2026-11-25: the catalog had been scanned under rules v2 while the app
  was at v3, leaving 49 archives and 66,441 entries absent. The rescan has
  since been run -- the two INTERFACE HUD sprite packs named as missing hold
  2,127 and 1,183 rows (the 3,310 PNG recorded), and 484 archives are
  indexed in a 480,826-row catalog.
