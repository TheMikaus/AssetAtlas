import 'dart:io';

import 'package:archive/archive.dart';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildAssetId', () {
    test('is stable for the same location', () {
      expect(
        buildAssetId(sourceRoot: r'C:\Packs\A', relativePath: 'Models/a.fbx'),
        buildAssetId(sourceRoot: r'C:\Packs\A', relativePath: 'Models/a.fbx'),
      );
    });

    test('ignores separator and case differences', () {
      expect(
        buildAssetId(sourceRoot: r'C:\Packs\A', relativePath: r'Models\a.fbx'),
        buildAssetId(sourceRoot: 'C:/packs/a', relativePath: 'models/A.FBX'),
      );
    });

    test('distinguishes different locations', () {
      final first = buildAssetId(
        sourceRoot: r'C:\Packs\A',
        relativePath: 'Models/a.fbx',
      );
      expect(
        first,
        isNot(
          buildAssetId(
            sourceRoot: r'C:\Packs\A',
            relativePath: 'Models/b.fbx',
          ),
        ),
      );
      expect(
        first,
        isNot(
          buildAssetId(
            sourceRoot: r'C:\Packs\B',
            relativePath: 'Models/a.fbx',
          ),
        ),
      );
    });

    test('zip entries are distinct from loose files', () {
      expect(
        buildAssetId(
          sourceRoot: r'C:\Packs\A',
          relativePath: 'pack.zip!/Textures/wall.png',
        ),
        isNot(
          buildAssetId(
            sourceRoot: r'C:\Packs\A',
            relativePath: 'Textures/wall.png',
          ),
        ),
      );
    });
  });

  group('assetIdRelativePathFromStored', () {
    test('strips the source name display prefix', () {
      expect(
        assetIdRelativePathFromStored(
          relativePath: 'CityPack/Models/a.fbx',
          sourceName: 'CityPack',
        ),
        'Models/a.fbx',
      );
    });

    test('leaves a path that does not carry the prefix alone', () {
      expect(
        assetIdRelativePathFromStored(
          relativePath: 'Models/a.fbx',
          sourceName: 'CityPack',
        ),
        'Models/a.fbx',
      );
    });
  });

  test('ids survive editing a file and re-scanning', () async {
    final root = await Directory.systemTemp.createTemp('asset_atlas_identity_');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });

    final separator = Platform.pathSeparator;
    final target = File('${root.path}${separator}albedo.png');
    await target.writeAsString('original');

    final before = await scanAssetFolder(root.path, onStatus: (_) {});
    expect(before.assets, hasLength(1));
    final originalId = before.assets.single.id;

    // Change size and modified time, exactly what an edit in a DCC tool does.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await target.writeAsString('edited, and noticeably longer than before');

    final after = await scanAssetFolder(root.path, onStatus: (_) {});
    expect(after.assets, hasLength(1));
    expect(
      after.assets.single.id,
      originalId,
      reason: 'identity must not depend on file contents',
    );
    expect(after.assets.single.size, isNot(before.assets.single.size));
  });

  test('zip entry ids survive the archive being rewritten', () async {
    final root = await Directory.systemTemp.createTemp('asset_atlas_zip_id_');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });

    final separator = Platform.pathSeparator;
    final zipPath = '${root.path}${separator}pack.zip';

    Future<void> writeArchive(List<int> payload) async {
      final archive = Archive()
        ..addFile(ArchiveFile('Textures/wall.png', payload.length, payload));
      await File(zipPath).writeAsBytes(ZipEncoder().encode(archive), flush: true);
    }

    await writeArchive([1, 2, 3]);
    final before = await scanAssetFolder(root.path, onStatus: (_) {});
    final beforeId = before.assets.single.id;

    await Future<void>.delayed(const Duration(milliseconds: 20));
    await writeArchive([1, 2, 3, 4, 5, 6, 7, 8]);
    final after = await scanAssetFolder(root.path, onStatus: (_) {});

    expect(after.assets.single.id, beforeId);
  });
}
