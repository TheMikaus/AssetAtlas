import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('scan includes supported assets inside zip archives', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'asset_atlas_zip_scan_',
    );
    addTearDown(() async {
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

    final copied = await copyAssetsToTarget(selected, target.path);
    expect(copied, selected.length);
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
}
