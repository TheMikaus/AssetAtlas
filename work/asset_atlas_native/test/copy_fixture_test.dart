import 'dart:io';

import 'package:archive/archive.dart';
import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Directory> _tempDir(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  });
  return dir;
}

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

    final tempDir = await _tempDir('asset_atlas_copy_test_');

    final report = await copyAssetsToTarget(selected, tempDir.path);
    expect(report.copiedCount, 2);
    expect(report.renamedCount, 0);
    expect(report.skippedCount, 0);
    expect(report.failedCount, 0);
    expect(
      File('${tempDir.path}${Platform.pathSeparator}albedo.png').existsSync(),
      isTrue,
    );
    expect(
      File('${tempDir.path}${Platform.pathSeparator}tree.obj').existsSync(),
      isTrue,
    );
  });

  group('resolveNonCollidingPath', () {
    test('returns the desired path when nothing is in the way', () async {
      final dir = await _tempDir('asset_atlas_collide_free_');
      final desired = '${dir.path}${Platform.pathSeparator}albedo.png';
      expect(resolveNonCollidingPath(desired), desired);
    });

    test('appends an incrementing suffix before the extension', () async {
      final dir = await _tempDir('asset_atlas_collide_seq_');
      final desired = '${dir.path}${Platform.pathSeparator}albedo.png';
      await File(desired).writeAsString('first');
      expect(
        resolveNonCollidingPath(desired),
        '${dir.path}${Platform.pathSeparator}albedo (2).png',
      );

      await File(
        '${dir.path}${Platform.pathSeparator}albedo (2).png',
      ).writeAsString('second');
      expect(
        resolveNonCollidingPath(desired),
        '${dir.path}${Platform.pathSeparator}albedo (3).png',
      );
    });

    test('handles names without an extension', () async {
      final dir = await _tempDir('asset_atlas_collide_noext_');
      final desired = '${dir.path}${Platform.pathSeparator}README';
      await File(desired).writeAsString('first');
      expect(
        resolveNonCollidingPath(desired),
        '${dir.path}${Platform.pathSeparator}README (2)',
      );
    });

    test('treats a leading dot as part of the name, not an extension', () async {
      final dir = await _tempDir('asset_atlas_collide_dotfile_');
      final desired = '${dir.path}${Platform.pathSeparator}.gitignore';
      await File(desired).writeAsString('first');
      expect(
        resolveNonCollidingPath(desired),
        '${dir.path}${Platform.pathSeparator}.gitignore (2)',
      );
    });
  });

  test('same-named assets from different folders both survive the copy', () async {
    final sourceRoot = await _tempDir('asset_atlas_copy_collision_src_');
    final separator = Platform.pathSeparator;
    final dirA = Directory('${sourceRoot.path}${separator}a')
      ..createSync(recursive: true);
    final dirB = Directory('${sourceRoot.path}${separator}b')
      ..createSync(recursive: true);
    await File('${dirA.path}${separator}albedo.png').writeAsString('AAA');
    await File('${dirB.path}${separator}albedo.png').writeAsString('BBB');

    final scan = await scanAssetFolder(sourceRoot.path, onStatus: (_) {});
    final selected = scan.assets
        .where((asset) => asset.name == 'albedo.png')
        .toList();
    expect(selected.length, 2);

    final targetDir = await _tempDir('asset_atlas_copy_collision_dst_');
    final report = await copyAssetsToTarget(selected, targetDir.path);

    expect(report.copiedCount, 2);
    expect(report.renamedCount, 1);
    expect(report.failedCount, 0);

    final written = targetDir
        .listSync()
        .whereType<File>()
        .map((file) => file.readAsStringSync())
        .toList()
      ..sort();
    expect(written, ['AAA', 'BBB']);
  });

  test('a missing source is reported as skipped, not counted as copied', () async {
    final sourceRoot = await _tempDir('asset_atlas_copy_missing_src_');
    final separator = Platform.pathSeparator;
    await File('${sourceRoot.path}${separator}present.png').writeAsString('ok');
    final doomed = File('${sourceRoot.path}${separator}vanishing.png');
    await doomed.writeAsString('gone soon');

    final scan = await scanAssetFolder(sourceRoot.path, onStatus: (_) {});
    expect(scan.assets.length, 2);
    await doomed.delete();

    final targetDir = await _tempDir('asset_atlas_copy_missing_dst_');
    final report = await copyAssetsToTarget(scan.assets, targetDir.path);

    expect(report.copiedCount, 1);
    expect(report.skippedCount, 1);
    final skipped = report.entries.firstWhere(
      (entry) => entry.outcome == CopyOutcome.skippedMissingSource,
    );
    expect(skipped.asset.name, 'vanishing.png');
    expect(report.summaryLine, contains('skipped'));
  });

  test('zip entries keep their archive-relative path and never overwrite', () async {
    final sourceRoot = await _tempDir('asset_atlas_copy_zip_src_');
    final separator = Platform.pathSeparator;
    final archive = Archive()
      ..addFile(
        ArchiveFile('textures/albedo.png', 3, [1, 2, 3]),
      );
    final encoded = ZipEncoder().encode(archive);
    await File(
      '${sourceRoot.path}${separator}pack.zip',
    ).writeAsBytes(encoded, flush: true);

    final scan = await scanAssetFolder(sourceRoot.path, onStatus: (_) {});
    final zipAssets = scan.assets
        .where((asset) => isZipVirtualPath(asset.path))
        .toList();
    expect(zipAssets.length, 1);

    final targetDir = await _tempDir('asset_atlas_copy_zip_dst_');
    final first = await copyAssetsToTarget(zipAssets, targetDir.path);
    expect(first.copiedCount, 1);
    expect(
      File(
        '${targetDir.path}${separator}textures${separator}albedo.png',
      ).existsSync(),
      isTrue,
    );

    final second = await copyAssetsToTarget(zipAssets, targetDir.path);
    expect(second.copiedCount, 1);
    expect(second.renamedCount, 1);
    expect(
      File(
        '${targetDir.path}${separator}textures${separator}albedo (2).png',
      ).existsSync(),
      isTrue,
    );
  });
}
