# TASK-02 — Stop version bumps from breaking the tests

**Stage 1 · Size XS · No dependencies**

## Problem

`test/widget_test.dart` hardcodes the version string:

```dart
expect(find.text('Asset Atlas Native · v1.1.0'), findsOneWidget);
```

The app renders it from a constant (`_HeaderTitle`, ~L1084):

```dart
Text('Asset Atlas Native · v$appVersion', ...)
```

Repo policy is to run `scripts/bump_version.ps1` on every code change. That script rewrites both
`pubspec.yaml` and `const appVersion` in `lib/main.dart` — so the first thing every version bump does
is break `flutter test`. The habit that forms is "tests are red after a bump, that's normal", which
is exactly the habit that hides a real failure later.

There is also no check that the two version sources stay in sync. If `bump_version.ps1` ever updates
one and not the other (its regexes throw if a pattern is missing, but a hand-edit would not), nothing
catches the drift.

## Required behaviour

1. The widget test asserts the version *shape*, not a literal — it must survive a bump untouched.
2. A test fails if `pubspec.yaml`'s `version:` and `main.dart`'s `appVersion` disagree.

## Implementation notes

1. In `test/widget_test.dart`, replace the literal with the constant the app itself uses:

   ```dart
   expect(find.text('Asset Atlas Native · v$appVersion'), findsOneWidget);
   ```

   `appVersion` is already exported from `package:asset_atlas_native/main.dart`.

2. Add `test/version_consistency_test.dart`. Read `pubspec.yaml` from the test's working directory
   (tests run with the package root as cwd — the existing fixture tests rely on this), parse the
   `version:` line, and compare its `major.minor.patch` part against `appVersion`:

   ```dart
   test('pubspec version matches appVersion constant', () async {
     final pubspec = await File('pubspec.yaml').readAsString();
     final match = RegExp(r'^version:\s*(\d+\.\d+\.\d+)\+\d+\s*$', multiLine: true)
         .firstMatch(pubspec);
     expect(match, isNotNull, reason: 'version: line not found in pubspec.yaml');
     expect(appVersion, match!.group(1));
   });
   ```

   Use the *same* regex shape that `scripts/bump_version.ps1` uses, so the test and the script agree
   on what a valid version line looks like.

3. Verify the loop end to end: run `pwsh -File .\scripts\bump_version.ps1 -DryRun`, then a real bump,
   then `flutter test`. The suite must be green without touching a test file. Leave the bump in your
   branch — it is the version for your change.

## Tests

Covered by the change itself: the amended `widget_test.dart` and the new
`version_consistency_test.dart`.

## Acceptance criteria

- [ ] `pwsh -File .\scripts\bump_version.ps1` followed by `flutter test` is green with no test edits.
- [ ] Hand-editing `appVersion` out of sync with `pubspec.yaml` fails the suite (check this by trying
      it locally and reverting).
- [ ] `flutter analyze` clean.

## Out of scope

- Changing the versioning policy or the script's behaviour.
- Displaying the build number in the UI.
