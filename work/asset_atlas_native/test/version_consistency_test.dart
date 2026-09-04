import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pubspec version matches the appVersion constant', () async {
    final pubspec = await File('pubspec.yaml').readAsString();

    // Same shape scripts/bump_version.ps1 matches, so the script and this
    // guard agree on what a valid version line looks like.
    final match = RegExp(
      r'^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);

    expect(
      match,
      isNotNull,
      reason:
          'No "version: major.minor.patch+build" line found in pubspec.yaml. '
          'scripts/bump_version.ps1 would also fail against this file.',
    );

    final pubspecVersion =
        '${match!.group(1)}.${match.group(2)}.${match.group(3)}';
    expect(
      appVersion,
      pubspecVersion,
      reason:
          'lib/main.dart appVersion ($appVersion) and pubspec.yaml '
          '($pubspecVersion) disagree. Run scripts/bump_version.ps1 rather '
          'than editing either by hand.',
    );
  });
}
