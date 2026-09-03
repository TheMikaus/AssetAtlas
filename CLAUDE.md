# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Shape

This git repository is rooted at `woul/` (the parent `2026-07-08/` folder is not a repo). The only active code is the Flutter Windows desktop app **AssetAtlas** at `work/asset_atlas_native/`. Run all Flutter/Dart commands from that directory.

- `work/asset_atlas_native/` — the app (all Dart code lives in a single `lib/main.dart`, ~4.7k lines)
- `work/ROADMAP.md`, `work/AI_HANDOFF_LATEST.md` — plan and session handoff; the handoff is the intended first read each session and is expected to be updated at the end of a work session (git status/log snapshot, next steps, files touched, validation run)
- `docs/TECH_SPEC_*.md` — architecture, rendering/FBX, build/release specs
- `USER_MANUAL.md` — end-user behavior reference; useful for confirming intended UX before changing it
- `work/asset-atlas/`, `work/asset-atlas-desktop/` — dead web/Electron prototypes, removed from git history; ignore them
- `outputs/` — staged build artifacts

## Commands

From `work/asset_atlas_native/`:

```bash
flutter pub get
flutter run -d windows
flutter analyze
flutter test
```

Run a single test file or a single test by name:

```bash
flutter test test/scan_fixture_test.dart
```

```bash
flutter test --plain-name "FBX importer JSON pipeline decodes UVs and texture image"
```

`flutter analyze` + `flutter test` is the standing validation gate before any commit or handoff update.

Packaging, installer, and version bump (PowerShell, from `work/asset_atlas_native/`):

```bash
pwsh -File .\scripts\package_windows.ps1
```

```bash
pwsh -File .\scripts\create_windows_installer.ps1
```

```bash
pwsh -File .\scripts\bump_version.ps1
```

`bump_version.ps1` rewrites **both** `pubspec.yaml` `version:` and the `const appVersion` literal in `lib/main.dart`, and throws if either pattern is missing — do not edit those by hand or reformat those lines. Repo convention is to bump the version whenever code changes. `create_windows_installer.ps1` needs Inno Setup 6 (`ISCC.exe`); output lands in `dist/installers/`.

## Architecture

### Two-process FBX pipeline

FBX is never parsed in Dart. `windows/runner/mesh_importer.cpp` builds a **second executable**, `asset_atlas_mesh_importer.exe`, from the vendored `ufbx` (`windows/runner/third_party/ufbx/`). It is a separate `add_executable` target in `windows/runner/CMakeLists.txt` and is installed next to the app binary by `windows/CMakeLists.txt`. Dart shells out to it and consumes JSON on stdout:

- `asset_atlas_mesh_importer <model.fbx>` — parse from disk
- `asset_atlas_mesh_importer --stdin <label>` — parse bytes piped on stdin (this is how FBX entries inside ZIP archives are previewed without extracting)

`meshImporterPath()` in `lib/main.dart` looks for the helper as a sibling of the running executable first, then falls back to `build/windows/x64/runner/Release/asset_atlas_mesh_importer.exe` — that fallback exists because `flutter test` runs under the SDK's `flutter_tester.exe`. Consequence: **`test/native_fbx_importer_test.dart` self-skips unless a Windows Release build exists.** Build Windows before trusting a green native test run.

Changes to the JSON contract must be made on both sides at once: the emitter in `mesh_importer.cpp` and `meshModelFromImporterJson()` in `lib/main.dart`. Fields include `vertices`, `faces` (indices + material index + inline UVs), `uvSets` (named, per-face), `materials`, `textureFiles`, `sceneTextures`, `vertexColors`.

### Rendering

Software rendering only. **Filled modes go through `rasterizeMesh`**, a depth-buffered rasteriser producing an RGBA buffer that `RasterModelView` shows; `MeshPainter` (canvas, per-face depth sort) is now used only for wireframe. Per-face sorting could not resolve interpenetrating or coplanar faces, which showed up as notches and slivers on low-poly models — `test/raster_depth_test.dart` pins the difference. The rasteriser is pure, so it runs on the UI isolate at half resolution while the camera moves and on a worker isolate (`rasterizeSceneInIsolate`) for the sharp frame once it settles. That needs the mesh flattened into typed arrays first: `RasterScene.fromMesh` does it, and `RasterModelView` caches one scene per mesh rather than rebuilding it per frame. Faces beyond `maxRenderedFaces` are capped by depth priority and the overlay says so; backface culling is user-toggleable and its sign convention is pinned by `test/renderer_geometry_test.dart`. FBX imports go through `MeshLoadCache`, not `loadMesh` directly, so the preview and the diagnostics panel share one importer run. `RenderMode` is textured/solid/wireframe; `LightingMode` is corner/top/unlit. Texturing is perspective-correct across a triangle. Three channels are now sampled per pixel — base colour, normal map (tangent frame from position/UV derivatives), and emissive map (added, so an emissive surface does not go dark where the light misses it) — plus a Blinn-Phong specular lobe driven by `specularFactor` and `roughness`; the camera and light are both fixed, so the half vector is constant per face. Specular is skipped in `LightingMode.unlit`. Each channel — base texture, normal map, emissive, specular — has its own switch on `RasterRequest` and its own toggle in the preview toolbar (`ShadingChannelPanel`), shown only when the model carries that channel; the switches are part of `RasterModelView`'s frame cache key. The remaining channels (metalness, the flat emissive colour) are still approximate colour modifiers in `faceDiffuse`, not a PBR model. Don't push further toward engine parity without an explicit ask — see `docs/TECH_SPEC_RENDERING_FBX.md` non-goals. `test/raster_shading_test.dart` pins the emissive and specular behaviour; a specular test needs a face whose normal sits on the half vector, because a tight lobe misses everything else.

**Palette faces.** Synty-style models pin all three UV corners of a face to a
single texel; roughly half the faces of a typical model do this. Such a UV
triangle has no invertible transform, so the per-triangle texture path cannot
draw it — it used to bail out and leave the untextured base colour showing,
which made half of every model render flat white. `isDegenerateUvTriangle`
detects them and the painter fills them with the sampled texel instead
(`MeshMaterial.sampleTexture`, which needs the CPU-side `texturePixels`
readback). Runs of these are batched into one `drawVertices` call, which also
removes the antialiasing seams that per-face `drawPath` left between triangles.
If a model renders as flat untextured colour, check this path first.

Texture resolution order: absolute path → relative to model dir → deterministic relink within the model's own container → deterministic relink *across* containers → fallback lookup → checker fallback. The cross-container pass is deliberately strict (`canRelinkAcrossContainers`): the basename must match exactly and the reference must name the other pack, which `texturePackHints` extracts while ignoring generic folder names (textures, materials, sourcefiles, …). Without both, a name like `Wall_01.png` would bind to whichever pack was scanned first.

Within one container the scoring also falls back to shared *words*: `stripTextureNameNoise` removes an exporter prefix (`T_`, `TX_`), a duplicate-copy suffix (` 1`, ` (2)`, `_copy` — never a bare trailing `_01`, which is part of the name), and `textureNameTokens` drops single characters and the word "texture". A shared distinctive word scores; a shared number alone deliberately does not, or every `_01` in a pack would match. This is what connects `PolygonApocalypse_Texture_01_A 1.png` to the `T_PolygonApocalypse_01.png` its own archive ships.

A material that named textures and resolved none is reported as such (`MeshMaterial.texturesMissing`, `materialSummaryLine`) rather than as "flat colour" — the two look identical on screen and mean opposite things. When nothing resolves at all, `TexturePickerButton` lets the user apply any scanned nearby texture by hand; `applyChosenTexture` puts it on every material and is deliberately *not* cached, since it is the user's choice rather than anything the file said.

**OBJ.** `parseObjMesh` keeps `vt` (flipping V — OBJ counts up, the sampler counts down), the `v/vt/vn` corner references, `usemtl` (which splits faces between materials) and `mtllib`. It used to keep none of that, so an OBJ could never be textured whatever else resolved. A corner with no texture coordinate makes the whole triangle untextured rather than half-textured. OBJ is in `_previewableModelExts`, so it reaches the texture discovery panel too.

### Catalog and persistence

`AssetAtlasDatabase` is a singleton over `sqflite_common_ffi`, DB file in the app support dir (or `initialize(databasePath:)` in tests), schema `version: 5` with tables `catalog_assets`, `catalog_sources`, `projects`, `project_assets`. `onUpgrade` exists and is tested — add a migration step there and mirror any DDL in `onCreate`, since `test/database_test.dart` asserts the two paths converge. Asset ids come from `buildAssetId()` (source root + relative path, content-independent); never build one inline.

Assets inside `.zip` archives are indexed as virtual paths shaped `zip:<container>::<entry>`. Any code that touches a path must handle this: `isZipVirtualPath()` gates reads through `readZipVirtualAssetBytesByPath()` and an LRU-ish archive cache. ZIP entries are searchable, previewable (images, audio, OBJ and FBX), and copyable — the copy flow writes them out under their archive-relative path. Introspection is capped by `maxZipIntrospectionBytes` / `maxZipEntriesToInspect`.

Type classification is driven by the top-level `const` sets in `lib/main.dart` (`imageExts`, `textureExts`, `audioExts`, `modelExts`, `archiveExts`) and `ignoredFolderNames` (`.git`, `.vs`, `Intermediate`, `Saved`, …). These are the authoritative rule set — changing them changes fixture test expectations in `test/fixtures/expected_results.json`.

### Known structural constraints

`lib/main.dart` is a deliberate monolith: UI widgets, scanning, ZIP handling, mesh import, renderer, and the database layer all live there. Prefer adding to the existing structure over speculative refactors unless the task is the refactor.

Two things now run on worker isolates, and both follow the same rule: **the
entry point and the launcher must be top-level**. A closure built inside a
`State` method captures `this`, drags the widget tree into the isolate message,
and fails with "object is unsendable" — see `runFbxClassifyChunk` and
`scanWorkerEntry`. Folder scanning goes through `startFolderScan`, which
returns a `ScanHandle` carrying progress and `cancel()`; FBX classification
goes through `buildFbxClassifyChunks` + `runFbxClassifyChunk`. Model previews
and thumbnails still import on the UI isolate, cached by `MeshLoadCache`.

## Testing

Tests are fixture-driven, under `test/`:

- `scan_fixture_test.dart` — scan counts/classification against `test/fixtures/corpus` and `expected_results.json`
- `copy_fixture_test.dart` — copy flow into temp dirs
- `zip_introspection_test.dart` — ZIP virtual-path indexing
- `fbx_texture_pipeline_test.dart` — importer-JSON → mesh → texture decode, using synthetic JSON (no native helper needed)
- `native_fbx_importer_test.dart` — real `ufbx` helper against `test/fixtures/fbx/transformed_uv_embedded.fbx` (ASCII FBX with embedded PNG, transformed instances, two named UV sets); skips without a Windows build

Tests import app code as `package:asset_atlas_native/main.dart`, so anything they exercise must be a top-level (non-private) declaration in `main.dart`.

## Windows platform gotchas

**Never put a `Tooltip` directly inside `ToggleButtons`.** It corrupts the
Windows accessibility tree (`Failed to update ui::AXTree` on stderr at startup)
and the app then hard-crashes inside `flutter_windows.dll` — exception
`0xC000041D` — the next time the window is resized or maximised. Bisected and
confirmed against this exact combination; `ToggleButtons` alone and
`DropdownButton` alone are both fine, and `IconButton(tooltip: ...)` is safe and
is what the toolbar uses instead.

More generally: AX errors on stderr are not cosmetic here. A clean run prints
none, so treat any `accessibility_bridge.cc` line as a crash waiting for a
resize, and bisect the widget tree until it is silent.

## Diagnostics

FBX pipeline logging is on via `const enableFbxLogs = true` and writes to `work/asset_atlas_native/logs/asset_atlas_fbx.log` — importer launch/exit, JSON field counts, texture relink decisions, mesh/vertex-color summary. Read this log first when a model previews blank or untextured.
