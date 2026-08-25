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

Software rendering only — `MeshPainter` is a `CustomPainter` doing its own projection and triangle fill. `RenderMode` is textured/solid/wireframe; `LightingMode` is corner/top/unlit. Texturing is triangle-affine (documented distortion at extreme angles) and material channels (opacity/roughness/metalness/emissive/specular) are deliberately approximate color modifiers, not a PBR model. Don't "fix" this toward engine parity without an explicit ask — see `docs/TECH_SPEC_RENDERING_FBX.md` non-goals.

Texture resolution order: absolute path → relative to model dir → deterministic relink against scanned candidates (filename and Synty-style variant matching, constrained to the same ZIP/pack) → fallback lookup → checker fallback.

### Catalog and persistence

`AssetAtlasDatabase` is a singleton over `sqflite_common_ffi`, DB file in the app support dir, schema `version: 1` with tables `catalog_assets`, `catalog_sources`, `projects`, `project_assets`. There is no migration path yet — adding a column means bumping the version and writing `onUpgrade`, not editing `onCreate`.

Assets inside `.zip` archives are indexed as virtual paths shaped `zip:<container>::<entry>`. Any code that touches a path must handle this: `isZipVirtualPath()` gates reads through `readZipVirtualAssetBytesByPath()` and an LRU-ish archive cache. ZIP entries are searchable and FBX-previewable, but copy flow skips them and texture validation marks them as missing-texture. Introspection is capped by `maxZipIntrospectionBytes` / `maxZipEntriesToInspect`.

Type classification is driven by the top-level `const` sets in `lib/main.dart` (`imageExts`, `textureExts`, `audioExts`, `modelExts`, `archiveExts`) and `ignoredFolderNames` (`.git`, `.vs`, `Intermediate`, `Saved`, …). These are the authoritative rule set — changing them changes fixture test expectations in `test/fixtures/expected_results.json`.

### Known structural constraints

`lib/main.dart` is a deliberate monolith: UI widgets, scanning, ZIP handling, mesh import, renderer, and the database layer all live there. Scanning and mesh parsing run on the UI thread (moving them to isolates is a standing roadmap item). Prefer adding to the existing structure over speculative refactors unless the task is the refactor.

## Testing

Tests are fixture-driven, under `test/`:

- `scan_fixture_test.dart` — scan counts/classification against `test/fixtures/corpus` and `expected_results.json`
- `copy_fixture_test.dart` — copy flow into temp dirs
- `zip_introspection_test.dart` — ZIP virtual-path indexing
- `fbx_texture_pipeline_test.dart` — importer-JSON → mesh → texture decode, using synthetic JSON (no native helper needed)
- `native_fbx_importer_test.dart` — real `ufbx` helper against `test/fixtures/fbx/transformed_uv_embedded.fbx` (ASCII FBX with embedded PNG, transformed instances, two named UV sets); skips without a Windows build

Tests import app code as `package:asset_atlas_native/main.dart`, so anything they exercise must be a top-level (non-private) declaration in `main.dart`.

## Diagnostics

FBX pipeline logging is on via `const enableFbxLogs = true` and writes to `work/asset_atlas_native/logs/asset_atlas_fbx.log` — importer launch/exit, JSON field counts, texture relink decisions, mesh/vertex-color summary. Read this log first when a model previews blank or untextured.
