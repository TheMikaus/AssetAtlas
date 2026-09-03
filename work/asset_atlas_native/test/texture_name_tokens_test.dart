import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

AssetItem _zipAsset(String zipPath, String entryPath) {
  final virtual = buildZipVirtualPath(zipPath, entryPath);
  final name = entryPath.split('/').last;
  return AssetItem(
    id: 'test:$virtual',
    name: name,
    path: virtual,
    relativePath: entryPath,
    sourceRoot: r'C:\Packs',
    sourceName: 'Packs',
    ext: name.split('.').last.toLowerCase(),
    type: 'image',
    size: 1,
    modified: DateTime.fromMillisecondsSinceEpoch(0),
    tags: const [],
  );
}

void main() {
  group('stripTextureNameNoise', () {
    test('drops an exporter prefix', () {
      expect(stripTextureNameNoise('T_PolygonApocalypse_01'), 'polygonapocalypse_01');
      expect(stripTextureNameNoise('TX_Wall'), 'wall');
      expect(stripTextureNameNoise('Tex_Wall'), 'wall');
    });

    test('drops the duplicate-copy suffix a download folder adds', () {
      expect(
        stripTextureNameNoise('PolygonApocalypse_Texture_01_A 1'),
        'polygonapocalypse_texture_01_a',
      );
      expect(stripTextureNameNoise('Wall (2)'), 'wall');
      expect(stripTextureNameNoise('Wall_copy'), 'wall');
    });

    test('leaves a name that is already clean alone', () {
      expect(stripTextureNameNoise('PolygonFarm_Texture_01_A'), 'polygonfarm_texture_01_a');
    });

    test('does not eat a leading word that merely starts with t', () {
      expect(stripTextureNameNoise('Tree_Bark'), 'tree_bark');
    });
  });

  group('textureNameTokens', () {
    test('keeps the words that identify a pack', () {
      expect(
        textureNameTokens('T_PolygonApocalypse_01'),
        containsAll(['polygonapocalypse', '01']),
      );
    });

    test('drops the word texture, which identifies nothing', () {
      expect(textureNameTokens('PolygonFarm_Texture_01_A'), isNot(contains('texture')));
    });

    test('drops single characters: a variant letter is not identity', () {
      expect(textureNameTokens('PolygonFarm_Texture_01_A'), isNot(contains('a')));
    });
  });

  group('relinking inside one pack on shared words', () {
    const pack = r'C:\Packs\ANIMATION_Base_Locomotion_SourceFiles_v3.zip';
    final model = buildZipVirtualPath(pack, 'SourceFiles/Demo_Models/SM_Obstacle_09.fbx');
    const requested =
        r'..\..\..\PolygonApocalypse\Textures\PolygonApocalypse_Texture_01_A 1.png';

    test('finds the pack atlas under its exporter name', () {
      final atlas = _zipAsset(pack, 'SourceFiles/Demo_Textures/T_PolygonApocalypse_01.png');
      final dummy = _zipAsset(pack, 'SourceFiles/Demo_Textures/T_Polygon_Dummy_01.png');

      expect(
        findDeterministicTextureRelink(model, requested, [dummy, atlas]),
        atlas.path,
      );
    });

    test('a shared number alone is not a match', () {
      final dummy = _zipAsset(pack, 'SourceFiles/Demo_Textures/T_Polygon_Dummy_01.png');
      expect(findDeterministicTextureRelink(model, requested, [dummy]), isNull);
    });

    test('an exact name still beats a merely-similar one', () {
      final exact = _zipAsset(
        pack,
        'SourceFiles/Textures/PolygonApocalypse_Texture_01_A 1.png',
      );
      final similar = _zipAsset(
        pack,
        'SourceFiles/Demo_Textures/T_PolygonApocalypse_01.png',
      );
      expect(
        findDeterministicTextureRelink(model, requested, [similar, exact]),
        exact.path,
      );
    });

    test('the answer does not depend on scan order', () {
      final atlas = _zipAsset(pack, 'SourceFiles/Demo_Textures/T_PolygonApocalypse_01.png');
      final dummy = _zipAsset(pack, 'SourceFiles/Demo_Textures/T_Polygon_Dummy_01.png');
      final forward = findDeterministicTextureRelink(model, requested, [atlas, dummy]);
      final reversed = findDeterministicTextureRelink(model, requested, [dummy, atlas]);
      expect(forward, reversed);
    });

    test('an unrelated pack in the same archive is not adopted', () {
      final unrelated = _zipAsset(pack, 'SourceFiles/Demo_Textures/T_MedievalKingdom_01.png');
      expect(findDeterministicTextureRelink(model, requested, [unrelated]), isNull);
    });
  });

  group('the real corpus, when it is present', () {
    const root = r'K:\Misc Downloads To Keep\Assets for Creation\Synty';
    final available = Directory(root).existsSync();

    test('SM_Obstacle_09 finds the atlas its own pack ships', () {
      const pack = '$root\\ANIMATION_Base_Locomotion_SourceFiles_v3.zip';
      final model = buildZipVirtualPath(pack, 'SourceFiles/Demo_Models/SM_Obstacle_09.fbx');
      final atlas = _zipAsset(pack, 'SourceFiles/Demo_Textures/T_PolygonApocalypse_01.png');
      final dummy = _zipAsset(pack, 'SourceFiles/Demo_Textures/T_Polygon_Dummy_01.png');

      expect(
        findDeterministicTextureRelink(
          model,
          r'..\..\..\PolygonApocalypse\Textures\PolygonApocalypse_Texture_01_A 1.png',
          [dummy, atlas],
        ),
        atlas.path,
      );
    }, skip: available ? false : 'Synty corpus not mounted');
  });

  group('a texture may only relink within its own channel', () {
    const pack = r'C:\Packs\ANIMATION_Base_Locomotion_SourceFiles_v3.zip';
    final model = buildZipVirtualPath(pack, 'SourceFiles/Demo_Models/SM_Obstacle_10.fbx');
    final atlas = _zipAsset(pack, 'SourceFiles/Demo_Textures/T_PolygonApocalypse_01.png');

    test('an emissive reference does not bind to the base atlas', () {
      // These share every distinctive word they have, so word overlap alone
      // matched -- and an emissive map added over its own base colour washes
      // the model out to grey, which is exactly what showed up on screen.
      expect(
        findDeterministicTextureRelink(
          model,
          r'..\..\..\PolygonApocalypse\Textures\Misc\PolygonApocalypse_Emissive_01.png',
          [atlas],
        ),
        isNull,
      );
    });

    test('a normal map reference does not bind to the base atlas', () {
      expect(
        findDeterministicTextureRelink(
          model,
          r'..\..\..\PolygonApocalypse\Textures\Misc\PolygonApocalypse_Normal.png',
          [atlas],
        ),
        isNull,
      );
    });

    test('the base colour still binds', () {
      expect(
        findDeterministicTextureRelink(
          model,
          r'..\..\..\PolygonApocalypse\Textures\PolygonApocalypse_Texture_01_A 1.png',
          [atlas],
        ),
        atlas.path,
      );
    });

    test('an emissive reference binds to an emissive candidate', () {
      final emissive = _zipAsset(
        pack,
        'SourceFiles/Demo_Textures/T_PolygonApocalypse_Emissive_01.png',
      );
      expect(
        findDeterministicTextureRelink(
          model,
          r'..\..\..\PolygonApocalypse\Textures\Misc\PolygonApocalypse_Emissive_01.png',
          [atlas, emissive],
        ),
        emissive.path,
      );
    });

    test('textureChannelWord names the channel a file declares', () {
      expect(textureChannelWord('PolygonApocalypse_Emissive_01'), 'emissive');
      expect(textureChannelWord('PolygonApocalypse_Normal'), 'normal');
      expect(textureChannelWord('PolygonApocalypse_Texture_01_A'), '');
    });
  });
}
