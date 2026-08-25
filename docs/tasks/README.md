# Task Specs

Self-contained work items for `work/asset_atlas_native`. Each spec states the defect, the exact
place in the code, the required behaviour, the tests to add, and what is out of scope. Findings
behind them are in [../ENGINEERING_ASSESSMENT.md](../ENGINEERING_ASSESSMENT.md).

All line numbers are as of version **1.1.0+4** (commit `e31504d`) and will drift — the function
names are the reliable anchor. All code lives in `work/asset_atlas_native/lib/main.dart` unless a
spec says otherwise.

## Order of work

| # | Task | Stage | Size | Depends on |
|---|------|-------|------|------------|
| [TASK-01](TASK-01-copy-collisions.md) | Copy flow: collisions, skips, and error reporting | 1 | S | — |
| [TASK-02](TASK-02-version-test-coupling.md) | Stop version bumps from breaking the tests | 1 | XS | — |
| [TASK-03](TASK-03-importer-stdout-encoding.md) | UTF-8 across the importer boundary | 1 | S | — |
| [TASK-04](TASK-04-deterministic-texture-relink.md) | Make texture relink actually deterministic | 1 | M | — |
| [TASK-09](TASK-09-ci-windows.md) | CI: analyze + test on every push | 1 | S | — |
| [TASK-05](TASK-05-texture-diagnostics-cache.md) | Stop re-importing FBX on every rebuild | 2 | M | — |
| [TASK-06](TASK-06-renderer-frame-cost.md) | Renderer frame cost and an honest face cap | 2 | M | — |
| [TASK-07](TASK-07-incremental-catalog-persistence.md) | Incremental catalog persistence | 2 | M | — |
| [TASK-08](TASK-08-stable-asset-identity.md) | Stable asset identity + schema migration | 3 | L | 07 |

Sizes: XS ≈ under an hour · S ≈ half a day · M ≈ 1–2 days · L ≈ 3–5 days, pair with a senior.

## How to work a task

1. Branch from `main`: `git checkout -b task-01-copy-collisions`.
2. **Write the failing test first.** Every spec names the tests it expects; several of them fail
   against today's code, which is the point — that is how you know you reproduced the defect.
3. Implement the change. Keep it inside the scope listed; if you find something else broken, note it
   in the PR description rather than fixing it in the same branch.
4. Run the gate from `work/asset_atlas_native`:

   ```bash
   flutter analyze
   ```

   ```bash
   flutter test
   ```

   Both must be clean. `flutter analyze` must report *No issues found* — that is the current state,
   so any new warning is yours.
5. Some tests need the native helper. Build it once before running the suite:

   ```bash
   flutter build windows --release
   ```

   Without it, `test/native_fbx_importer_test.dart` **skips itself and still reports green** — do not
   read that as coverage.
6. Bump the version per repo policy, from `work/asset_atlas_native`:

   ```bash
   pwsh -File .\scripts\bump_version.ps1
   ```

7. Update `work/AI_HANDOFF_LATEST.md` with what you touched and what you ran, then open the PR.

## Conventions in this codebase

- Everything the tests exercise must be a **top-level, non-private declaration** in `main.dart` —
  tests import `package:asset_atlas_native/main.dart` and cannot see `_private` names.
- Paths inside ZIP archives are virtual: `zip:<container>::<entry>`. Any code touching a path must
  go through `isZipVirtualPath()` / `parseZipVirtualPath()` / `readAssetBytes()` rather than
  `File(path)` directly.
- FBX is never parsed in Dart. It goes through the `asset_atlas_mesh_importer.exe` helper built from
  `windows/runner/mesh_importer.cpp`. Changing the JSON contract means changing both sides in the
  same commit.
- Prefer adding to the existing structure over refactoring `main.dart` while doing these tasks. The
  decomposition is planned separately and will be much easier once these land.
