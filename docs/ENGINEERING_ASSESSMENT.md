# Engineering Assessment — AssetAtlas (native track)

Assessed against `work/asset_atlas_native` at version 1.1.0+4, commit `e31504d`.
Baseline verified before writing: `flutter analyze` → *No issues found*; `flutter test` → *9 passing, ~2s*.

> **Status:** sections 1 and 2 have since been worked through — see the status column in
> [`docs/tasks/README.md`](tasks/README.md). Everything below is kept as written, because it
> is the record of *why* each change was made. Still open: 2.5 (scanning on the UI isolate),
> 2.6 (filter allocation and the side effect in `filteredAssets`), all of section 3, and the
> `drawVertices` batching split out as TASK-10.

The app works, and the hard part — a real FBX pipeline with texture relinking — is done and is
genuinely the valuable asset here. What follows is where it will hurt as the catalog grows past a
toy corpus, ordered by how much damage each item does.

---

## 1. Correctness defects

### 1.1 Copy silently destroys files (highest severity)

`copyAssetsToTarget()` writes every non-ZIP asset to `<target>/<asset.name>`, flattening the source
tree. Game asset libraries are full of repeated basenames (`Albedo.png`, `SM_Wall_01.fbx`). Two
selected assets with the same name means the second `File.copy()` overwrites the first — `File.copy`
does not fail on an existing destination — and the returned `copied` count still increments twice,
so the UI reports "2 files copied" when one file exists. Assets whose source has since been deleted
are skipped with no mention, and there is no `try/catch` anywhere in `copySelected()`, so a
permissions error becomes an unhandled async exception with an unchanged status bar.

For a tool whose entire purpose is "pick assets, copy them somewhere", this is the bug to fix
first. → **TASK-01**

### 1.2 The renderer silently hides geometry

`MeshPainter.paint()` computes `step = max(1, (faces.length / 14000).ceil())` and then draws every
`step`-th face. A 112k-triangle model is drawn with 1/8 of its triangles and no indication
whatsoever in the UI. In an *inspection* tool this is worse than being slow: the user cannot tell
whether the holes are in the asset or in the viewer, which undermines the one question the app
exists to answer. → **TASK-06**

### 1.3 Non-ASCII texture paths get corrupted

`runMeshImporter()` handles its two paths inconsistently. The `--stdin` branch collects raw bytes
and does `utf8.decode(...)`. The on-disk branch uses `Process.run(helper, [sourcePath])`, whose
default `stdoutEncoding` is `systemEncoding` — the ANSI codepage on Windows, not UTF-8. The C++ side
emits UTF-8 (ufbx strings are UTF-8). Any material name or texture path containing a non-ASCII
character therefore arrives mojibaked, and the texture then fails to resolve for reasons no log line
explains. → **TASK-03**

### 1.4 "Deterministic" relink is not deterministic

`findDeterministicTextureRelink()` sorts candidates with
`sourceCandidates.sort((a, b) => score(b).compareTo(score(a)))`. Dart's `List.sort` is explicitly
not stable, and nothing breaks ties, so two candidates with an equal score can swap places between
runs, between machines, or after an unrelated scan reorders the catalog. The README and tech spec
both advertise this path as deterministic. The same line also recomputes `score()` — several regex
allocations per call — inside the comparator, i.e. O(n log n) scorings instead of O(n).
→ **TASK-04**

### 1.5 Asset identity is tied to file contents

`AssetItem.id` is `'<path>:<size>:<modifiedMs>'`. Touch a texture in Photoshop, re-scan, and every
derived record keyed by that id is orphaned: the asset drops out of saved projects
(`loadProjectAssetIds` filters to ids that still exist, so the loss is silent) and its `ignored`
flag resets. Editing assets is the normal state of a content pipeline, so the persistence layer
currently forgets things precisely when the user is working hardest. → **TASK-08**

### 1.6 Version bumps break the test suite

`test/widget_test.dart` asserts `find.text('Asset Atlas Native · v1.1.0')` while the app renders
`'Asset Atlas Native · v$appVersion'`. The documented repo policy is to run `bump_version.ps1` on
every code change, so the standing workflow is "bump version, watch tests fail, hand-edit the test".
That trains people to treat a red suite as normal. → **TASK-02**

### 1.7 Importer JSON escaping is incomplete

`print_json_string()` in `mesh_importer.cpp` escapes `\`, `"`, newline, carriage return and tab, and
passes every other byte through — including control characters below 0x20. An FBX with such a byte
in a material name produces invalid JSON, `jsonDecode` throws, and the user sees a generic failure.
Cheap to fix with a `\u00XX` fallback, and folded into TASK-03.

---

## 2. Performance defects

Ordered by what the user actually feels.

### 2.1 The FBX importer is re-run on every rebuild

`ModelTextureDiagnostics` is a `StatelessWidget` whose `build()` constructs
`FutureBuilder(future: loadModelTextureReferenceEntries(asset, allAssets))`. The future is recreated
on every build, and `loadModelTextureReferenceEntries` calls `importFbxWithUfbx` — which **spawns
the native process and parses the whole mesh**. Every keystroke in the search box, every checkbox
toggle, every pixel of splitter drag, every status update re-imports the selected FBX.
`ModelPreview` imports the same file separately, so selecting one model parses it at least twice.
The same anti-pattern appears in `_PreviewPanelState._previewFor` for ZIP images
(`FutureBuilder(future: readZipVirtualAssetBytesByPath(...))` built inline), which re-reads and
re-inflates the archive on each rebuild. → **TASK-05**

### 2.2 The "missing textures" filter is quadratic in process spawns

Selecting the model-texture filter enqueues every model in the catalog into
`_validateModelTexture`, which for FBX runs a **full import** (process spawn + whole-mesh JSON +
texture decode) and then decides the answer by checking whether the human-readable label string
contains `'(found)'`. On a 2,000-FBX library that is 2,000 subprocess launches and 2,000 mesh parses
on the UI isolate, to compute a boolean. Diagnostic strings should never be the data channel; the
resolver already knows the answer. → covered by TASK-05

### 2.3 Every ignore toggle rewrites the entire catalog table

`AssetAtlasDatabase.saveCatalog()` deletes all rows from `catalog_assets` and `catalog_sources` and
re-inserts every asset one `insert` at a time. `setIgnored()` calls it (fire-and-forget) on each
checkbox click. Toggling one flag in a 100k-asset catalog issues 100k individual inserts. There is
also no `Batch`, no index, and no `onUpgrade` path on the schema. → **TASK-07**

### 2.4 The painter does avoidable work every frame

Per frame — and a pan gesture is one frame per pointer move — `paint()` copies the whole face list
(`mesh.faces.toList()`), sorts it with a comparator that recomputes `_faceDepth` on both sides of
every comparison (O(F log F) depth computations instead of O(F)), performs no backface culling, and
for textured meshes issues `save`/`clipPath`/`transform`/`drawImage`/`restore` **per triangle**.
`drawVertices` with an `ImageShader` collapses that last part into a single call. → **TASK-06**

### 2.5 Scanning and ZIP inflation run on the UI isolate

`scanAssetFolder` is awaited directly from `setState`-driven UI code, yielding cooperatively with
`Future.delayed(Duration.zero)` every 250 files. Inside it, each ZIP is read fully into memory
(`readAsBytes`, up to 128 MB) and decoded inline. `_zipArchiveCache` then keeps up to 8 decoded
archives resident. There is no cancel. This is the known roadmap item, and it is real, but it is a
bigger change than the items above and should not be the first thing attempted.

### 2.6 Filtering allocates per asset per keystroke

`filteredAssets` is a getter called from `build()`; it lowercases name, path and tags for every
asset on every rebuild, sorts the result, and has **a side effect** — it calls
`_scheduleModelTextureValidation([asset])` from inside the `where` closure, i.e. kicks off async
work that will `setState` from within a build. There is no debounce on the search field. Several
other paths are accidentally O(n²): `assets.removeWhere((a) => !assets.any(...))` in
`scanFolder`/`removeSource`, `_assetById`'s linear scan, and the project-load filter
`loadedAssetIds.where((id) => assets.any(...))`.

---

## 3. Structural and process issues

- **`lib/main.dart` is 4,755 lines** holding UI, scanning, ZIP handling, path resolution, mesh
  import, the software renderer, and the database layer. Everything is top-level and public because
  the tests import `package:asset_atlas_native/main.dart`. Nothing is injectable, so nothing except
  pure functions can be tested in isolation. Splitting this is the right medium-term move, but do it
  *after* the correctness fixes, in slices that each keep the suite green.
- **The importer protocol is text JSON, and vertices are not shared.** The C++ side pushes three
  fresh vertices per triangle, so a 20k-triangle mesh emits 60k vertex records as `%.9g` text, which
  Dart then `jsonDecode`s on the UI isolate. Indexing vertices and/or moving to a binary frame is the
  single biggest lever on large-model load time — a senior-scoped change.
- **Git history carries 182 MB.** `work/asset-atlas-desktop/node_modules` was committed in the
  initial import, including a 172 MB `electron.exe`. The files were deleted in `0b46d35`, but a fresh
  clone still pays for them. `outputs/` (29 MB of built binaries) is also tracked and grows per
  release.
- **No CI**, despite a GitHub remote and a roadmap item asking for it. Nothing enforces
  analyze/test on a push. → **TASK-09**
- **Docs have drifted from the code.** The README and `AI_HANDOFF_LATEST.md` state that copy skips
  ZIP entries and that ZIP preview is disabled; `copyAssetsToTarget` and `_previewFor` both handle
  ZIP entries today. The handoff also cites `0b46d35` as latest when `main` is two commits further
  on.
- **Test coverage is thin** — the whole suite runs in ~2 seconds. There is nothing covering the
  database layer, project save/load/rename/delete, filter behaviour, relink scoring, or copy
  collisions. Every task below therefore ships with its own tests.
- **Release logging is always on.** `enableFbxLogs` is a `const true`, and `fbxLog` does a
  synchronous append per line on the calling (UI) thread, to a file that is only truncated at startup
  and never rotated.

---

## 4. What I would do next, in order

**Stage 1 — stop the bleeding (small, independent, all junior-sized).**
TASK-01 copy safety · TASK-02 version/test coupling · TASK-03 importer encoding · TASK-04
deterministic relink · TASK-09 CI. Landing CI early means every later task is guarded. None of these
touch shared structure, so they can be done in any order or in parallel.

**Stage 2 — make it feel fast (junior-sized, but sequence them).**
TASK-05 (cache the importer; stop re-parsing on rebuild) is the biggest perceived win and should go
first. Then TASK-06 (renderer frame cost + an honest face cap) and TASK-07 (incremental
persistence).

**Stage 3 — fix identity, with care.**
TASK-08 changes the asset id and needs a schema migration. It is the one task here worth pairing on.
Do it after Stages 1 and 2 so the test suite is thicker when it lands.

**Stage 4 — structural, senior-scoped, not in this task set.**
Move scanning and mesh import into isolates with cancellation; split `main.dart` into `data/`,
`services/`, `render/`, `ui/` slices behind the existing public API; index the importer's vertices
and consider a binary frame; rewrite git history to drop `node_modules` and untrack `outputs/`; gate
`enableFbxLogs` on a debug flag and rotate the log.

The task specs in [`docs/tasks/`](tasks/README.md) cover Stages 1–3.
