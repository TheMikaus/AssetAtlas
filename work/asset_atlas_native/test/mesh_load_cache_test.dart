import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

AssetItem _fbxAsset(String path) {
  final name = path.split(Platform.pathSeparator).last;
  return AssetItem(
    id: 'test:$path',
    name: name,
    path: path,
    relativePath: name,
    sourceRoot: File(path).parent.path,
    sourceName: 'fixtures',
    ext: 'fbx',
    type: 'model',
    size: 1,
    modified: DateTime.fromMillisecondsSinceEpoch(0),
    tags: const [],
  );
}

void main() {
  setUp(() {
    MeshLoadCache.clear();
    MeshLoadCache.importCount = 0;
  });

  test('repeated loads of the same asset share one import', () async {
    final helper = File(
      'build/windows/x64/runner/Release/asset_atlas_mesh_importer.exe',
    );
    if (!helper.existsSync()) {
      markTestSkipped('Build the Windows app before running native FBX tests.');
      return;
    }

    final asset = _fbxAsset(
      File('test/fixtures/fbx/transformed_uv_embedded.fbx').absolute.path,
    );

    final first = MeshLoadCache.load(asset);
    final second = MeshLoadCache.load(asset);

    // Same Future instance: a second widget asking during the same frame joins
    // the in-flight import rather than spawning another helper process.
    expect(identical(first, second), isTrue);
    expect(MeshLoadCache.importCount, 1);

    await first;
    MeshLoadCache.load(asset);
    expect(
      MeshLoadCache.importCount,
      1,
      reason: 'a resolved entry must still be served from cache',
    );
  });

  test('clear forces the next load to re-import', () async {
    final helper = File(
      'build/windows/x64/runner/Release/asset_atlas_mesh_importer.exe',
    );
    if (!helper.existsSync()) {
      markTestSkipped('Build the Windows app before running native FBX tests.');
      return;
    }

    final asset = _fbxAsset(
      File('test/fixtures/fbx/transformed_uv_embedded.fbx').absolute.path,
    );

    await MeshLoadCache.load(asset);
    expect(MeshLoadCache.importCount, 1);

    MeshLoadCache.clear();
    await MeshLoadCache.load(asset);
    expect(MeshLoadCache.importCount, 2);
  });

  test('a failed import is not cached, so the next attempt retries', () async {
    final missing = _fbxAsset(
      '${Directory.systemTemp.path}${Platform.pathSeparator}does_not_exist.fbx',
    );

    await expectLater(MeshLoadCache.load(missing), throwsA(anything));
    expect(MeshLoadCache.importCount, 1);

    await expectLater(MeshLoadCache.load(missing), throwsA(anything));
    expect(
      MeshLoadCache.importCount,
      2,
      reason: 'failures must be evicted so a fixed file can be retried',
    );
  });

  test('different fallback checker sizes are cached separately', () async {
    final helper = File(
      'build/windows/x64/runner/Release/asset_atlas_mesh_importer.exe',
    );
    if (!helper.existsSync()) {
      markTestSkipped('Build the Windows app before running native FBX tests.');
      return;
    }

    final asset = _fbxAsset(
      File('test/fixtures/fbx/transformed_uv_embedded.fbx').absolute.path,
    );

    await MeshLoadCache.load(asset, fallbackCheckerSquareSize: 16);
    await MeshLoadCache.load(asset, fallbackCheckerSquareSize: 32);
    expect(MeshLoadCache.importCount, 2);

    await MeshLoadCache.load(asset, fallbackCheckerSquareSize: 16);
    expect(MeshLoadCache.importCount, 2);
  });
}
