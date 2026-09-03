import 'dart:io';
import 'dart:math' as math;

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

const _root = r'C:\Packs\CityPack';
final _separator = Platform.pathSeparator;

AssetItem _asset(String relativePath, {String sourceRoot = _root}) {
  final path = '$sourceRoot$_separator${relativePath.replaceAll('/', _separator)}';
  final name = relativePath.split('/').last;
  return AssetItem(
    id: 'test:$path',
    name: name,
    path: path,
    relativePath: relativePath,
    sourceRoot: sourceRoot,
    sourceName: 'CityPack',
    ext: name.contains('.') ? name.split('.').last.toLowerCase() : '',
    type: 'image',
    size: 1,
    modified: DateTime.fromMillisecondsSinceEpoch(0),
    tags: const [],
  );
}

AssetItem _zipAsset(String zipPath, String entryPath) {
  final virtual = buildZipVirtualPath(zipPath, entryPath);
  final name = entryPath.split('/').last;
  return AssetItem(
    id: 'test:$virtual',
    name: name,
    path: virtual,
    relativePath: entryPath,
    sourceRoot: _root,
    sourceName: 'CityPack',
    ext: name.split('.').last.toLowerCase(),
    type: 'image',
    size: 1,
    modified: DateTime.fromMillisecondsSinceEpoch(0),
    tags: const [],
  );
}

String get _modelPath => '$_root${_separator}Models${_separator}SM_Wall_01.fbx';

void main() {
  group('findDeterministicTextureRelink', () {
    test('resolves ties the same way regardless of candidate order', () {
      // Two candidates that score identically for the requested texture.
      final left = _asset('Textures/Texture_01_A.png');
      final right = _asset('Textures/Texture_01_B.png');

      final forward = findDeterministicTextureRelink(
        _modelPath,
        r'D:\AuthorMachine\Source\Texture_01.psd',
        [left, right],
      );
      final reversed = findDeterministicTextureRelink(
        _modelPath,
        r'D:\AuthorMachine\Source\Texture_01.psd',
        [right, left],
      );

      expect(forward, isNotNull);
      expect(forward, reversed);
      // Tie-break is the lexicographically smaller normalized path, so the
      // answer does not depend on scan order.
      expect(forward, left.path);
    });

    test('is stable across many shuffles of a larger candidate list', () {
      final candidates = [
        for (var index = 0; index < 20; index += 1)
          _asset('Textures/Texture_01_${String.fromCharCode(65 + index)}.png'),
      ];
      final random = math.Random(1234);

      final answers = <String?>{};
      for (var attempt = 0; attempt < 12; attempt += 1) {
        final shuffled = [...candidates]..shuffle(random);
        answers.add(
          findDeterministicTextureRelink(
            _modelPath,
            r'D:\AuthorMachine\Source\Texture_01.psd',
            shuffled,
          ),
        );
      }
      expect(answers, hasLength(1));
    });

    test('returns null when nothing scores above the threshold', () {
      final candidates = [_asset('Textures/CompletelyUnrelated.png')];
      expect(
        findDeterministicTextureRelink(
          _modelPath,
          r'D:\AuthorMachine\Source\Texture_01.psd',
          candidates,
        ),
        isNull,
      );
    });

    test('prefers an exact basename match', () {
      final exact = _asset('Textures/Wall_01.png');
      final variant = _asset('Textures/Wall_01_A.png');
      expect(
        findDeterministicTextureRelink(_modelPath, 'Wall_01.psd', [
          variant,
          exact,
        ]),
        exact.path,
      );
    });

    test('strips an author-variant suffix', () {
      final base = _asset('Textures/Wall_01.png');
      expect(
        findDeterministicTextureRelink(_modelPath, 'Wall_01_Mike.psd', [base]),
        base.path,
      );
    });

    test('matches a Synty-style exported variant', () {
      final variant = _asset('Textures/Texture_01_A.png');
      expect(
        findDeterministicTextureRelink(_modelPath, 'Texture_01.psd', [variant]),
        variant.path,
      );
    });

    test('tolerates singular/plural drift', () {
      final plural = _asset('Textures/windows.png');
      expect(
        findDeterministicTextureRelink(_modelPath, 'window.png', [plural]),
        plural.path,
      );
    });

    test('never crosses from one zip pack into another', () {
      const packA = r'C:\Packs\pack_a.zip';
      const packB = r'C:\Packs\pack_b.zip';
      final modelInA = buildZipVirtualPath(packA, 'Models/SM_Wall_01.fbx');
      final textureInB = _zipAsset(packB, 'Textures/Wall_01.png');

      expect(
        findDeterministicTextureRelink(modelInA, 'Wall_01.psd', [textureInB]),
        isNull,
      );

      final textureInA = _zipAsset(packA, 'Textures/Wall_01.png');
      expect(
        findDeterministicTextureRelink(modelInA, 'Wall_01.psd', [
          textureInB,
          textureInA,
        ]),
        textureInA.path,
      );
    });
  });

  group('crossing between archives', () {
    test('a bare name never crosses: too many packs share one', () {
      const packA = r'C:\Packs\pack_a.zip';
      const packB = r'C:\Packs\pack_b.zip';
      final modelInA = buildZipVirtualPath(packA, 'Models/SM_Wall_01.fbx');
      final textureInB = _zipAsset(packB, 'Textures/Wall_01.png');

      expect(
        findDeterministicTextureRelink(modelInA, 'Wall_01.psd', [textureInB]),
        isNull,
        reason: 'nothing in the reference says which pack it means',
      );
    });

    test('a reference naming another pack finds it', () {
      const packA = r'C:\Packs\ANIMATION_Base.zip';
      const packB = r'C:\Packs\PolygonApocalypse_SourceFiles.zip';
      final modelInA = buildZipVirtualPath(packA, 'Demo_Models/SM_Obstacle.fbx');
      final atlasInB = _zipAsset(
        packB,
        'PolygonApocalypse/Textures/PolygonApocalypse_Texture_01_A.png',
      );

      expect(
        findDeterministicTextureRelink(
          modelInA,
          r'..\..\..\PolygonApocalypse\Textures\PolygonApocalypse_Texture_01_A.png',
          [atlasInB],
        ),
        atlasInB.path,
      );
    });

    test('the file name still has to match exactly', () {
      const packA = r'C:\Packs\ANIMATION_Base.zip';
      const packB = r'C:\Packs\PolygonApocalypse_SourceFiles.zip';
      final modelInA = buildZipVirtualPath(packA, 'Demo_Models/SM_Obstacle.fbx');
      final other = _zipAsset(
        packB,
        'PolygonApocalypse/Textures/PolygonApocalypse_Texture_02_B.png',
      );

      expect(
        findDeterministicTextureRelink(
          modelInA,
          r'..\..\..\PolygonApocalypse\Textures\PolygonApocalypse_Texture_01_A.png',
          [other],
        ),
        isNull,
      );
    });

    test('a texture beside the model still wins', () {
      const packA = r'C:\Packs\ANIMATION_Base.zip';
      const packB = r'C:\Packs\PolygonApocalypse_SourceFiles.zip';
      final modelInA = buildZipVirtualPath(packA, 'Demo_Models/SM_Obstacle.fbx');
      final localAtlas = _zipAsset(
        packA,
        'Textures/PolygonApocalypse_Texture_01_A.png',
      );
      final remoteAtlas = _zipAsset(
        packB,
        'PolygonApocalypse/Textures/PolygonApocalypse_Texture_01_A.png',
      );

      expect(
        findDeterministicTextureRelink(
          modelInA,
          r'..\..\..\PolygonApocalypse\Textures\PolygonApocalypse_Texture_01_A.png',
          [remoteAtlas, localAtlas],
        ),
        localAtlas.path,
        reason: 'the archive the model lives in is checked first',
      );
    });

    test('generic folder names are not pack identity', () {
      expect(texturePackHints(r'..\..\Textures\Misctlas.png'), isEmpty);
      expect(
        texturePackHints(r'..\PolygonApocalypse\Texturestlas.png'),
        contains('polygonapocalypse'),
      );
    });
  });

  group('findFallbackTexture', () {
    test('resolves ties the same way regardless of candidate order', () {
      final left = _asset('Textures/Wall_Detail_A.png');
      final right = _asset('Textures/Wall_Detail_B.png');

      final forward = findFallbackTexture(_modelPath, 'Wall_Detail.psd', [
        left,
        right,
      ]);
      final reversed = findFallbackTexture(_modelPath, 'Wall_Detail.psd', [
        right,
        left,
      ]);

      expect(forward, isNotNull);
      expect(forward, reversed);
      expect(forward, left.path);
    });
  });
}
