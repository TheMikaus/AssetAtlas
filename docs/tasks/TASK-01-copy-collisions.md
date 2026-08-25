# TASK-01 — Copy flow: collisions, skips, and error reporting

**Stage 1 · Size S · No dependencies**

## Problem

Copying selected assets can silently destroy files, and silently under-deliver.

`copyAssetsToTarget()` (`lib/main.dart` ~L3431) writes every non-ZIP asset to
`<target>/<asset.name>`, discarding the folder structure:

```dart
final destination = File('$target${Platform.pathSeparator}${asset.name}');
if (!File(asset.path).existsSync()) {
  continue;
}
await File(asset.path).copy(destination.path);
copied += 1;
```

Three defects in nine lines:

1. **Collisions overwrite.** `File.copy` does not fail when the destination exists. Game libraries
   are full of repeated basenames — `Props/Barrel/Albedo.png` and `Props/Crate/Albedo.png` both land
   on `Albedo.png`. The user gets one file and is told they got two.
2. **Skips are invisible.** A source that no longer exists is `continue`d past. The same applies to
   the ZIP branch above it when `bytes` come back null or empty. Nothing is reported.
3. **Failures are invisible.** `copySelected()` (~L3431 caller, `_CatalogScreenState`) has no
   `try/catch`. A permissions error or a full disk throws out of the `await`, becomes an unhandled
   async error, and the status bar keeps showing whatever it showed before.

## Required behaviour

- **No copy may overwrite an existing file.** On collision, disambiguate by appending ` (2)`, ` (3)`
  … before the extension, e.g. `Albedo.png` → `Albedo (2).png`. Keep trying until a free name is
  found. (Deliberately the Windows Explorer convention, so it reads as normal to the user.)
- **Every input asset produces exactly one outcome**: copied, renamed-and-copied, skipped
  (with a reason), or failed (with the error).
- **The status line reports the truth**, e.g.
  `12 copied · 2 renamed to avoid overwrite · 1 skipped (source missing) · 1 failed`.
- Failures do not abort the batch. Copy every asset you can, then report.
- ZIP-sourced assets keep their current behaviour of preserving the in-archive relative path via
  `safeZipEntryRelativePath()`, but gain the same collision and failure handling.

## Implementation notes

1. Introduce a result type next to `ScanResult` (top-level, public — the tests need it):

   ```dart
   enum CopyOutcome { copied, renamed, skippedMissingSource, failed }

   class CopyResultEntry {
     const CopyResultEntry({
       required this.asset,
       required this.outcome,
       this.destinationPath,
       this.detail,
     });
     final AssetItem asset;
     final CopyOutcome outcome;
     final String? destinationPath;
     final String? detail; // reason for skip, or error text for failure
   }

   class CopyReport {
     const CopyReport(this.entries);
     final List<CopyResultEntry> entries;
     int get copiedCount => ...;   // copied + renamed
     int get renamedCount => ...;
     int get skippedCount => ...;
     int get failedCount => ...;
     String get summaryLine => ...; // the string the status bar shows
   }
   ```

2. Change `copyAssetsToTarget` to return `Future<CopyReport>`. Wrap each asset's work in its own
   `try/catch` so one failure cannot end the batch.
3. Add a top-level helper — it is the piece worth unit-testing on its own:

   ```dart
   String resolveNonCollidingPath(String desiredPath) { ... }
   ```

   It must handle a name with no extension (`README` → `README (2)`), a dotfile (`.gitignore` →
   `.gitignore (2)`), and repeated collisions. Use the same helper for both the ZIP and non-ZIP
   branches.
4. In `_CatalogScreenState.copySelected()`, await the report and set `status` from
   `report.summaryLine`. Wrap the call in `try/catch` and surface any escaped error as a
   `ScanStatus('Copy failed', error.toString())`.
5. `copied += 1` currently counts overwrites — make sure the new counts come from the entries, not a
   running integer.

## Tests

Add to `test/copy_fixture_test.dart` (it already builds a temp target dir — follow its
`addTearDown` pattern):

- `resolveNonCollidingPath` unit cases: free name returned unchanged; one collision → ` (2)`; two
  collisions → ` (3)`; extensionless file; dotfile.
- **Collision integration test** (fails against today's code — write it first): create a temp source
  tree with `a/albedo.png` and `b/albedo.png` holding *different* bytes, scan it, copy both, then
  assert two files exist in the target and that their contents match the two distinct sources.
- **Missing-source test**: scan a fixture, delete one source file, copy, assert the entry's outcome
  is `skippedMissingSource` and that `report.copiedCount` excludes it.
- **ZIP entry test**: copy an asset from a ZIP (build one with `ZipEncoder` as
  `test/zip_introspection_test.dart` does), assert the archive-relative path is preserved and that a
  second copy into the same target does not overwrite the first.
- Keep the existing "selected fixture assets copy to target folder" test passing; update it to the
  new return type.

## Acceptance criteria

- [ ] No code path can overwrite an existing file in the target directory.
- [ ] Reported counts equal the number of files actually written.
- [ ] A single failing asset does not prevent the rest from copying.
- [ ] Status line names skips and failures, not just successes.
- [ ] `flutter analyze` clean, `flutter test` green, new tests included.

## Out of scope

- Preserving the source folder structure for non-ZIP assets (that is a UX decision — flat output is
  the current intent; only the collision behaviour is wrong).
- A copy progress bar or cancellation.
- Moving copy work off the UI isolate.
