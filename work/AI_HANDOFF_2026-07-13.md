# AI Handoff Note (2026-07-13)

## Current State

- Repo focus is Flutter native desktop track at `work/asset_atlas_native/`.
- Working tree is clean (no staged or unstaged file changes at handoff time).
- Latest commit on `main` is `0b46d35`.

## Next Steps (Priority Order)

1. Wire project CRUD and project membership UI fully to persisted SQLite tables.
2. Add/expand copy-flow smoke tests using fixture corpus and temp output dirs.
3. Move scan + model parsing to isolates to keep UI responsive on large folders.
4. Expand fixture coverage for texture relink and project snapshot restore flows.
5. Add CI checks for native track (`flutter test`, `flutter analyze`, release build smoke).

## Recently Changed (Most Relevant)

### From roadmap and docs status

- Source-of-truth role notes documented in native README.
- Fixture corpus and expected-results baseline created for native tests.
- SQLite persistence scaffold added for catalog and source roots.
- Audio preview added in native track.
- Fixture-based scan smoke tests added and passing.
- Fixture-based copy smoke tests added and passing.
- Project snapshot save/load wired to SQLite-backed project tables.

### From recent commits (`git log --oneline -n 8`)

- `0b46d35` chore: remove web/electron prototypes and refocus docs to native.
- `c6577ca` docs: add root readme and technical specs.
- `dd3b0e3` initial AssetAtlas repository import.

## Suggested First Action For Next AI

- Start in `work/asset_atlas_native/README.md`, then inspect current SQLite/project CRUD paths and add/verify tests before changing UI wiring.