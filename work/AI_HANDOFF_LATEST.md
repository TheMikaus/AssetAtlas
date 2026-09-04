# AI Handoff (Latest)

Last updated: 2026-08-25 (engineering assessment worked through: TASK-01..09)
Previous snapshot: `work/AI_HANDOFF_2026-07-13.md`

## Current State

- Repo focus is the Flutter native desktop track at `work/asset_atlas_native/`.
- Version 1.2.0+6. Schema is at **v3** (see the migration note below).
- Branch `fix/stage-1-correctness`, based on `main` at `f671d6f`.
- `flutter analyze` clean; `flutter test` 59 passing with the Windows release built
  first, so the native FBX tests actually run rather than self-skipping.
- CI now runs analyze + build + test on `windows-latest` for pushes to `main` and
  for pull requests.

## What Changed This Session

Findings are written up in [`docs/ENGINEERING_ASSESSMENT.md`](../docs/ENGINEERING_ASSESSMENT.md);
each change has a spec in [`docs/tasks/`](../docs/tasks/README.md) with its commit.

- **TASK-01** `fc1c478` — copy no longer overwrites same-named files or misreports
  what it did. `copyAssetsToTarget` returns a `CopyReport`; collisions get an
  Explorer-style ` (2)` suffix; skips and failures are surfaced.
- **TASK-02** `fc1c478` — version bumps no longer break the suite; a new test
  guards pubspec/appVersion drift.
- **TASK-03** `fc1c478` — both importer paths decode UTF-8 (the on-disk one used
  `systemEncoding`); the C++ side escapes control bytes.
- **TASK-04** `075174b` — texture relink is genuinely deterministic: score once,
  tie-break on the normalized path.
- **TASK-09** `c48b86f` — CI workflow.
- **TASK-05** `f1b7170` — `MeshLoadCache` shares one FBX import between the preview
  and the diagnostics panel; the panel holds its future in state instead of
  re-importing on every rebuild.
- **TASK-06** `bc17424` — depth computed once per face, backface culling (toggle,
  default on), and the face cap is now depth-priority *and* visible in the overlay.
- **TASK-07** `4d6107c` — incremental persistence; schema v2 indexes with a real
  `onUpgrade`.
- **TASK-08** `e135319` — asset ids no longer embed size/mtime; schema v3 migration
  rebuilds them and remaps project membership.

## Read This Before Running The App

Schema **v3 rewrites asset ids in the user's database on first launch**. It is
transactional and tested against a populated v1 database, but back up
`asset_atlas_native.db` in the app support directory before the first run on a
database you care about.

## Next Steps (Priority Order)

1. **TASK-10** — batch the textured render path into `drawVertices`. Spec written;
   it needs before/after screenshots of real asset packs, not the fixture.
2. Move scanning and mesh import onto isolates with cancellation (assessment 2.5).
   This is the largest remaining responsiveness item.
3. Fix `filteredAssets`: it allocates per asset per keystroke, has no debounce, and
   schedules async validation from inside `build()` (assessment 2.6).
4. Split `lib/main.dart` (now ~5.3k lines) into data/services/render/ui slices,
   keeping the suite green at each step.
5. Repo hygiene: history still carries ~182 MB from a committed `node_modules`
   (a 172 MB `electron.exe`), and `outputs/` is tracked and grows per release.

## Handoff Update Checklist

- Capture `git status --short` and latest `git log --oneline -n 8`.
- Update "Current State", "What Changed", and "Next Steps".
- List files touched this session and the validation commands run.
- Keep this file as the first read target for the next AI.
