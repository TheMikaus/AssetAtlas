import 'dart:convert';
import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fixture corpus scan matches expected baseline', () async {
    final fixtureRoot = Directory('test/fixtures/corpus').absolute.path;
    final expectedPath = File('test/fixtures/expected_results.json');

    expect(Directory(fixtureRoot).existsSync(), isTrue);
    expect(expectedPath.existsSync(), isTrue);

    final expected =
        jsonDecode(await expectedPath.readAsString()) as Map<String, dynamic>;

    final statuses = <ScanStatus>[];
    final result = await scanAssetFolder(fixtureRoot, onStatus: statuses.add);

    expect(result.assets.length, expected['assets']);
    expect(result.skippedUnsupported, expected['skippedUnsupported']);
    expect(result.skippedBinaryObj, expected['skippedBinaryObj']);

    final counts = expected['countsByType'] as Map<String, dynamic>;
    expect(
      result.assets.where((asset) => asset.type == 'image').length,
      counts['image'],
    );
    expect(
      result.assets.where((asset) => asset.type == 'audio').length,
      counts['audio'],
    );
    expect(
      result.assets.where((asset) => asset.type == 'model').length,
      counts['model'],
    );

    final lowerPaths = result.assets
        .map((asset) => asset.path.toLowerCase().replaceAll('\\', '/'))
        .toList();
    expect(lowerPaths.any((path) => path.contains('/.git/')), isFalse);
    expect(lowerPaths.any((path) => path.contains('/saved/')), isFalse);

    expect(statuses, isNotNull);
  });
}
