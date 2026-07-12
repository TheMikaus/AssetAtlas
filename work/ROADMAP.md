# Asset Atlas Workspace Roadmap

This file defines a practical execution order from current baseline to a stable native desktop release candidate.

## Phase 0: Alignment (Now)

- Confirm native Flutter track as source-of-truth for feature semantics.
- Keep extension support, ignore rules, and type classification deterministic.

## Phase 1: Shared Core Contracts

- Define a shared schema for catalog entries:
  - id, name, absolute path, relative path, source root, type, extension, tags, ignored, modified time, size
- Define one authoritative extension map and ignore-folder rule set.
- Add a sample fixture corpus used for native regression checks.

Deliverable: native scan/index flow produces stable counts and classifications for the fixture corpus.

## Phase 2: Persistent Storage

- Replace ad-hoc local state with SQLite-backed persistence in the native track.
- Persist projects, source roots, ignored flags, manual tags, and scan metadata.
- Add migration from old local state where present.

Deliverable: catalog state survives restart with deterministic reload.

## Phase 3: Indexing Reliability

- Move heavy scanning/model parsing off the UI thread.
- Add incremental scan + re-scan behavior.
- Surface robust progress and cancellation states.

Deliverable: large scans remain responsive and resumable.

## Phase 4: Preview Reliability

- Harden FBX/GLTF/GLB import and external texture resolution.
- Add clear fallback messages for unsupported or partially resolved assets.
- Add audio playback preview in native track.

Deliverable: stable preview behavior for common game asset sets.

## Phase 5: Quality Gate

- Add smoke tests on fixture corpus (scan counts, ignored folders, copy selected).
- Add a basic CI pass for native lint/check/test.
- Maintain a single known-caveats section in the native README.

Deliverable: predictable baseline for every merge.

## Immediate Next 5 Tasks

1. Wire project CRUD and project membership UI to persisted SQLite tables.
2. Add copy-flow smoke tests using fixture corpus and temp output directories.
3. Move scan + model parsing to isolates for large-folder responsiveness.
4. Expand fixture coverage for texture relink and project snapshot restore flows.
5. Add CI checks for native track (`flutter test`, `flutter analyze`, and release build smoke).

## Recently Completed

- Source-of-truth role notes documented in native README.
- Fixture corpus and expected-results baseline created for native track tests.
- SQLite persistence scaffold added for catalog and source roots.
- Audio preview added in native track.
- Fixture-based scan smoke test added and passing.
- Fixture-based copy smoke test added and passing.
- Project snapshot save/load wired to SQLite-backed project tables.
