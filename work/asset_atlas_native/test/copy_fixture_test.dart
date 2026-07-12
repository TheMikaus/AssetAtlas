import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('selected fixture assets copy to target folder', () async {
    final fixtureRoot = Directory('test/fixtures/corpus').absolute.path;
    final scan = await scanAssetFolder(fixtureRoot, onStatus: (_) {});

    final selected = scan.assets
        .where(
          (asset) => asset.name == 'albedo.png' || asset.name == 'tree.obj',
        )
        .toList();
    expect(selected.length, 2);

    final tempDir = await Directory.systemTemp.createTemp(
      'asset_atlas_copy_test_',
    );
    addTearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    final copied = await copyAssetsToTarget(selected, tempDir.path);
    expect(copied, 2);
    expect(
      File('${tempDir.path}${Platform.pathSeparator}albedo.png').existsSync(),
      isTrue,
    );
    expect(
      File('${tempDir.path}${Platform.pathSeparator}tree.obj').existsSync(),
      isTrue,
    );
  });
}
