import 'dart:convert';
import 'dart:io';

import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('scan includes supported assets inside zip archives', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'asset_atlas_zip_scan_',
    );
    addTearDown(() async {
      closeCachedArchives();
      if (tempRoot.existsSync()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final zipPath = '${tempRoot.path}${Platform.pathSeparator}pack.zip';
    final archive = Archive()
      ..addFile(ArchiveFile('textures/albedo.png', 3, [1, 2, 3]))
      ..addFile(ArchiveFile('audio/theme.mp3', 3, [4, 5, 6]))
      ..addFile(
        ArchiveFile('models/tree.obj', 15, 'v 0 0 0\nv 1 0 0\n'.codeUnits),
      )
      ..addFile(ArchiveFile('docs/readme.txt', 5, 'hello'.codeUnits));

    final encoded = ZipEncoder().encode(archive);
    expect(encoded, isNotNull);
    await File(zipPath).writeAsBytes(encoded, flush: true);

    final scan = await scanAssetFolder(tempRoot.path, onStatus: (_) {});

    final zipAssets = scan.assets
        .where((asset) => asset.path.startsWith('zip:'))
        .toList();

    expect(zipAssets.length, 3);
    expect(zipAssets.where((asset) => asset.type == 'image').length, 1);
    expect(zipAssets.where((asset) => asset.type == 'audio').length, 1);
    expect(zipAssets.where((asset) => asset.type == 'model').length, 1);
    expect(
      zipAssets.every((asset) => asset.relativePath.contains('pack.zip!/')),
      isTrue,
    );
  });

  test('copy extracts selected zip assets to target folder', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'asset_atlas_zip_copy_',
    );
    addTearDown(() async {
      closeCachedArchives();
      if (tempRoot.existsSync()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final zipPath = '${tempRoot.path}${Platform.pathSeparator}pack.zip';
    final archive = Archive()
      ..addFile(ArchiveFile('textures/albedo.png', 4, [1, 2, 3, 4]))
      ..addFile(ArchiveFile('audio/theme.mp3', 5, [5, 6, 7, 8, 9]))
      ..addFile(ArchiveFile('../escape.png', 3, [9, 9, 9]));
    final encoded = ZipEncoder().encode(archive);
    expect(encoded, isNotNull);
    await File(zipPath).writeAsBytes(encoded, flush: true);

    final scan = await scanAssetFolder(tempRoot.path, onStatus: (_) {});
    final selected = scan.assets
        .where((asset) => asset.path.startsWith('zip:'))
        .toList();
    expect(selected, isNotEmpty);

    final target = await Directory.systemTemp.createTemp(
      'asset_atlas_zip_copy_target_',
    );
    addTearDown(() async {
      if (target.existsSync()) {
        await target.delete(recursive: true);
      }
    });

    final report = await copyAssetsToTarget(selected, target.path);
    expect(report.copiedCount, selected.length);
    expect(report.failedCount, 0);
    expect(
      File(
        '${target.path}${Platform.pathSeparator}textures${Platform.pathSeparator}albedo.png',
      ).existsSync(),
      isTrue,
    );
    expect(
      File(
        '${target.path}${Platform.pathSeparator}audio${Platform.pathSeparator}theme.mp3',
      ).existsSync(),
      isTrue,
    );
    expect(
      File('${target.path}${Platform.pathSeparator}escape.png').existsSync(),
      isTrue,
    );
    expect(
      File('${tempRoot.path}${Platform.pathSeparator}escape.png').existsSync(),
      isFalse,
    );
  });

  test(
    'zip fbx preview imports embedded texture, transforms, and UV sets',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'asset_atlas_zip_fbx_preview_',
      );
      addTearDown(() async {
        closeCachedArchives();
        if (tempRoot.existsSync()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final zipPath = '${tempRoot.path}${Platform.pathSeparator}pack.zip';
      final fbxBytes = await File(
        'test/fixtures/fbx/transformed_uv_embedded.fbx',
      ).readAsBytes();
      final archive = Archive()
        ..addFile(ArchiveFile('models/tree.fbx', fbxBytes.length, fbxBytes));
      final encoded = ZipEncoder().encode(archive);
      expect(encoded, isNotNull);
      await File(zipPath).writeAsBytes(encoded, flush: true);

      final scan = await scanAssetFolder(tempRoot.path, onStatus: (_) {});
      final zipFbx = scan.assets.firstWhere((asset) => asset.ext == 'fbx');

      final mesh = await loadMesh(zipFbx, allAssets: scan.assets);
      expect(mesh.vertices, hasLength(6));
      expect(mesh.faces, hasLength(2));
      expect(mesh.availableUvSets, ['DetailUV', 'UVMap']);
      expect(mesh.materials.single.hasEmbeddedTexture, isTrue);
      expect(mesh.materials.single.uvSet, 'DetailUV');
    },
  );

  test('zip fbx preview resolves an external texture inside the archive', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'asset_atlas_zip_fbx_external_texture_',
    );
    addTearDown(() async {
      closeCachedArchives();
      if (tempRoot.existsSync()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final source = await File(
      'test/fixtures/fbx/transformed_uv_embedded.fbx',
    ).readAsString();
    final externalFbx = source
        .replaceFirst(
          RegExp(r'\s*Content:\s*,\s*\r?\n\s*"[A-Za-z0-9+/=]+"'),
          '',
        )
        .replaceAll(
          'embedded_albedo.png',
          r'..\..\Google Drive\_SyntyStudios\SimpleAirport\_working\SimpleAirport_Mike.psd',
        );
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO3ZfQ0AAAAASUVORK5CYII=',
    );
    final archive = Archive()
      ..addFile(
        ArchiveFile(
          'models/tree.fbx',
          utf8.encode(externalFbx).length,
          utf8.encode(externalFbx),
        ),
      )
      ..addFile(
        ArchiveFile('SourceFiles/Textures/SimpleAirport.png', png.length, png),
      )
      ..addFile(
        ArchiveFile(
          'SourceFiles/Textures/Alts/PolygonAncientWorlds_Texture_01_A.png',
          png.length,
          png,
        ),
      );
    final zipPath = '${tempRoot.path}${Platform.pathSeparator}pack.zip';
    await File(zipPath).writeAsBytes(ZipEncoder().encode(archive), flush: true);

    final scan = await scanAssetFolder(tempRoot.path, onStatus: (_) {});
    final zipFbx = scan.assets.firstWhere((asset) => asset.ext == 'fbx');
    final zipTexture = scan.assets.firstWhere(
      (asset) => asset.name == 'SimpleAirport.png',
    );
    final mesh = await loadMesh(zipFbx, allAssets: scan.assets);

    expect(mesh.materials.single.hasEmbeddedTexture, isFalse);
    expect(mesh.materials.single.resolvedTextures, contains(zipTexture.path));
    expect(await readAssetBytes(zipTexture.path), orderedEquals(png));
    final renamedPackTexture = scan.assets.firstWhere(
      (asset) => asset.name == 'PolygonAncientWorlds_Texture_01_A.png',
    );
    expect(
      findDeterministicTextureRelink(
        zipFbx.path,
        r'U:\Dropbox\SyntyStudios\PolygonShops\_Working\_Textures\Alts\PolygonShops_Texture_01_A.png',
        scan.assets,
      ),
      renamedPackTexture.path,
    );
  });

  test('an archive past the old 128MB byte cap is indexed', () async {
    // Archives used to be read by loading the whole file, so anything over
    // 128MB was skipped and contributed no rows at all -- silently, which is
    // how 49 archives and 66,441 entries went missing from the real catalog.
    final tempRoot = await Directory.systemTemp.createTemp(
      'asset_atlas_zip_big_',
    );
    final fillerDir = await Directory.systemTemp.createTemp(
      'asset_atlas_zip_filler_',
    );
    addTearDown(() async {
      closeCachedArchives();
      for (final dir in [tempRoot, fillerDir]) {
        if (dir.existsSync()) await dir.delete(recursive: true);
      }
    });

    // Stored, not deflated, so the archive on disk really is over the cap.
    final fillerPath =
        '${fillerDir.path}${Platform.pathSeparator}filler.bin';
    final filler = File(fillerPath).openSync(mode: FileMode.write);
    final megabyte = Uint8List(1024 * 1024);
    for (var written = 0; written < 129; written += 1) {
      filler.writeFromSync(megabyte);
    }
    await filler.close();

    final smallPath = '${fillerDir.path}${Platform.pathSeparator}albedo.png';
    await File(smallPath).writeAsBytes(const [1, 2, 3], flush: true);

    final zipPath = '${tempRoot.path}${Platform.pathSeparator}huge.zip';
    final encoder = ZipFileEncoder();
    encoder.create(zipPath, level: ZipFileEncoder.store);
    await encoder.addFile(File(fillerPath), 'raw/filler.bin', 0);
    await encoder.addFile(File(smallPath), 'textures/albedo.png', 0);
    encoder.closeSync();

    expect(
      File(zipPath).lengthSync(),
      greaterThan(128 * 1024 * 1024),
      reason: 'the fixture has to cross the cap it is testing',
    );

    final scan = await scanAssetFolder(tempRoot.path, onStatus: (_) {});
    final zipAssets = scan.assets
        .where((asset) => asset.path.startsWith('zip:'))
        .toList();

    expect(zipAssets.length, 1);
    expect(zipAssets.single.name, 'albedo.png');

    // And the entry is readable, not merely listed.
    final bytes = await readZipVirtualAssetBytesByPath(
      buildZipVirtualPath(zipPath, 'textures/albedo.png'),
    );
    expect(bytes, const [1, 2, 3]);
    closeCachedArchives();
  });

  test('one open archive serves repeated entry reads', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'asset_atlas_zip_reread_',
    );
    addTearDown(() async {
      closeCachedArchives();
      if (tempRoot.existsSync()) await tempRoot.delete(recursive: true);
    });

    final zipPath = '${tempRoot.path}${Platform.pathSeparator}pack.zip';
    final archive = Archive()
      ..addFile(ArchiveFile('textures/albedo.png', 3, [1, 2, 3]))
      ..addFile(ArchiveFile('textures/normal.png', 4, [4, 5, 6, 7]));
    await File(zipPath).writeAsBytes(ZipEncoder().encode(archive), flush: true);

    final first = await readZipVirtualAssetBytesByPath(
      buildZipVirtualPath(zipPath, 'textures/albedo.png'),
    );
    final second = await readZipVirtualAssetBytesByPath(
      buildZipVirtualPath(zipPath, 'textures/normal.png'),
    );
    // Reading the same entry twice has to work as well: the bytes are not
    // retained on the entry, so the second read inflates again off the stream.
    final again = await readZipVirtualAssetBytesByPath(
      buildZipVirtualPath(zipPath, 'textures/albedo.png'),
    );

    expect(first, const [1, 2, 3]);
    expect(second, const [4, 5, 6, 7]);
    expect(again, const [1, 2, 3]);
  });

  test('closeCachedArchives lets go of the file', () async {
    // Browsing keeps archives open because reopening one costs 20-40ms of
    // directory parsing. On Windows that also locks the file, so a browser
    // that never let go would stop the user reorganising their own library.
    final tempRoot = await Directory.systemTemp.createTemp(
      'asset_atlas_zip_handle_',
    );
    addTearDown(() async {
      closeCachedArchives();
      if (tempRoot.existsSync()) await tempRoot.delete(recursive: true);
    });

    final zipPath = '${tempRoot.path}${Platform.pathSeparator}pack.zip';
    final movedPath = '${tempRoot.path}${Platform.pathSeparator}moved.zip';
    final archive = Archive()
      ..addFile(ArchiveFile('textures/albedo.png', 3, [1, 2, 3]));
    await File(zipPath).writeAsBytes(ZipEncoder().encode(archive), flush: true);

    await readZipVirtualAssetBytesByPath(
      buildZipVirtualPath(zipPath, 'textures/albedo.png'),
    );

    if (Platform.isWindows) {
      expect(
        () => File(zipPath).renameSync(movedPath),
        throwsA(isA<FileSystemException>()),
        reason: 'the read should still be holding the archive open',
      );
    }

    closeCachedArchives();
    File(zipPath).renameSync(movedPath);
    expect(File(movedPath).existsSync(), isTrue);
  });

  test('an archive rebuilt on disk is re-read, not served stale', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'asset_atlas_zip_stale_',
    );
    addTearDown(() async {
      closeCachedArchives();
      if (tempRoot.existsSync()) await tempRoot.delete(recursive: true);
    });

    final zipPath = '${tempRoot.path}${Platform.pathSeparator}pack.zip';
    final entryPath = buildZipVirtualPath(zipPath, 'textures/albedo.png');

    final before = Archive()
      ..addFile(ArchiveFile('textures/albedo.png', 3, [1, 2, 3]));
    await File(zipPath).writeAsBytes(ZipEncoder().encode(before), flush: true);
    expect(await readZipVirtualAssetBytesByPath(entryPath), const [1, 2, 3]);

    // Re-downloaded or re-exported in place. A cache keyed only on the path
    // would keep answering with the old contents, and keep a handle on bytes
    // that no longer exist.
    closeCachedArchives();
    final after = Archive()
      ..addFile(ArchiveFile('textures/albedo.png', 5, [9, 9, 9, 9, 9]));
    await File(zipPath).writeAsBytes(ZipEncoder().encode(after), flush: true);

    expect(await readZipVirtualAssetBytesByPath(entryPath), const [9, 9, 9, 9, 9]);
  });
}
