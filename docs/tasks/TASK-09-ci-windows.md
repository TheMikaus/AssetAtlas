# TASK-09 — CI: analyze + test on every push

**Stage 1 · Size S · No dependencies · Do this early — it guards every other task**

## Problem

The repo has a GitHub remote (`https://github.com/TheMikaus/AssetAtlas.git`) and a roadmap item
asking for CI, but no `.github/` directory. Nothing enforces the validation gate that the README and
every task spec assume. Right now `flutter analyze` reports *No issues found* and `flutter test`
passes — that clean baseline is worth locking in before the next nine changes land on top of it.

## Required behaviour

- Every push and every pull request runs, from `work/asset_atlas_native`:
  - `flutter pub get`
  - `flutter analyze` (must be clean — the job fails on any issue)
  - `flutter test`
- The native FBX test must not silently skip in CI. `test/native_fbx_importer_test.dart` calls
  `markTestSkipped` when `build/windows/x64/runner/Release/asset_atlas_mesh_importer.exe` is absent,
  and a skipped test reports green. CI must build Windows first so that test actually runs.
- The build is reproducible: the Flutter version is pinned, not "whatever is latest today".

## Implementation notes

Create `.github/workflows/ci.yml` at the **repository root** (that is `woul/`, not the Flutter project
directory).

Shape:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  windows:
    runs-on: windows-latest
    defaults:
      run:
        working-directory: work/asset_atlas_native
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '<pin the version you develop against>'
          channel: stable
          cache: true
      - run: flutter pub get
      - run: flutter analyze
      - run: flutter build windows --release   # produces the native importer helper
      - run: flutter test
```

Points to get right:

- **`working-directory`** must be set, or every step runs at the repo root where there is no
  `pubspec.yaml`.
- **Order matters**: `flutter build windows` before `flutter test`, otherwise the native importer test
  skips itself and CI is green while covering nothing.
- **Pin `flutter-version`.** Get the value from `flutter --version` on your machine; the project
  requires Dart SDK `^3.12.2` per `pubspec.yaml`. Record the pinned version in the workflow with a
  comment saying where it came from.
- **Windows runners are the slow, expensive tier.** Do not add a matrix. One `windows-latest` job is
  correct here — the app is Windows-first and the C++ helper only builds there.
- `actions/checkout@v4` and `subosito/flutter-action@v2` are third-party for the latter; pin it to a
  full commit SHA if the org has a policy about that, otherwise the major tag is acceptable for a
  single-maintainer repo.
- Do **not** add a step that commits a version bump — bumping stays a local, deliberate act per repo
  policy.

Also add a status badge to the top of the root `README.md`:

```markdown
![CI](https://github.com/TheMikaus/AssetAtlas/actions/workflows/ci.yml/badge.svg)
```

## Verification

- Push the branch and confirm the job runs and passes.
- Confirm the native test **ran** rather than skipped: check the test output in the job log for the
  `native importer preserves instances, embedded texture, and UV sets` line without a skip marker.
- Prove the gate bites: temporarily push a commit with a deliberate analyzer warning (e.g. an unused
  local) and confirm CI goes red, then revert it. Note in the PR that you did this.

## Acceptance criteria

- [ ] CI runs on push and PR, and fails on an analyzer issue or a failing test.
- [ ] The native FBX importer test executes in CI (not skipped).
- [ ] Flutter version pinned with a comment explaining the pin.
- [ ] Badge in the root README.

## Out of scope

- Publishing build artifacts or installers from CI.
- Running the packaging or Inno Setup scripts in CI.
- Code coverage reporting.
- Caching the C++ build between runs (revisit if job time becomes a problem).
