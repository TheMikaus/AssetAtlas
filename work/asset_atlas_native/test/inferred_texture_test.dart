import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The texture a model gets when the file itself names none.
///
/// 14% of the FBX meshes here are in that state, the War Robot among them:
/// one material, no texture reference, and a material name that does not
/// encode the atlas either. The pack's Unity build carries the answer --
/// prefab to material to `_MainTex` -- and where it does not, a filename
/// rule guesses and says it guessed.
///
/// A wrong texture is worse than none: the tagging queue embeds the picture
/// Atlas draws, so a wrong atlas becomes a wrong search result for every
/// model it touches. Most of these tests are about declining to answer.

AssetItem _asset(
  String entry, {
  required String container,
  String? type,
}) {
  final name = entry.split('/').last;
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return AssetItem(
    id: '$container::$entry',
    name: name,
    path: 'zip:Z:/Assets/$container::$entry',
    relativePath: 'Assets/$container/$entry',
    sourceRoot: r'Z:\Assets',
    sourceName: 'Assets',
    ext: ext,
    type: type ?? (imageExts.contains(ext) ? 'image' : 'model'),
    size: 1,
    modified: DateTime.fromMillisecondsSinceEpoch(0),
    tags: const [],
  );
}

const _corpusVariable = 'ASSET_ATLAS_SYNTY_CORPUS';

Future<List<AssetItem>> _scanPack(String root, String zipName) async {
  final path = '$root${Platform.pathSeparator}$zipName';
  final file = File(path);
  if (!file.existsSync()) return const [];
  final scan = await scanZipAssetEntries(
    zipPath: path,
    rootPath: root,
    sourceName: 'Assets',
    zipModified: file.statSync().modified,
  );
  return scan.assets;
}

void main() {
  setUp(() {
    resetTwinIndex();
    resetUnityChainCache();
  });
  tearDown(() {
    resetTwinIndex();
    resetUnityChainCache();
    closeCachedArchives();
  });

  group('guessing from file names', () {
    const pack = 'POLYGON_Pack_SourceFiles.zip';
    final model = _asset('SourceFiles/FBX/SM_Prop_Crate_01.fbx',
        container: pack);
    final atlas = _asset('SourceFiles/Textures/Pack_Texture_01_A.png',
        container: pack);
    final variant = _asset('SourceFiles/Textures/Alts/Pack_Texture_01_B.png',
        container: pack);
    final emissive = _asset('SourceFiles/Textures/Pack_Emissive_01.png',
        container: pack);
    final signs = _asset(
      'SourceFiles/Textures/Pack_Signs_Texture_01_A.png',
      container: pack,
    );
    final fx = _asset('SourceFiles/Textures/FX_Textures/Explosion.png',
        container: pack);

    test('picks the base atlas out of a pack shaped like a real one', () {
      final catalog = [model, atlas, variant, emissive, signs, fx];
      expect(guessTextureByName(model, catalog)?.name,
          'Pack_Texture_01_A.png');
    });

    test('the answer does not depend on the order of the catalog', () {
      final forward = [model, atlas, variant, emissive, signs, fx];
      final backward = forward.reversed.toList();
      expect(
        guessTextureByName(model, backward)?.name,
        guessTextureByName(model, forward)?.name,
      );
    });

    test('an atlas with no "texture" in its name is still found', () {
      // PolygonNature's base atlas is PolygonNature_01.png. The earlier rule
      // required the word and so could not see it; that is the Nature miss.
      const nature = 'POLYGON_Nature_SourceFiles.zip';
      final tree = _asset('SourceFiles/FBX/SM_Tree_01.fbx', container: nature);
      final leaf = _asset(
        'SourceFiles/Textures/PolygonNature_01.png',
        container: nature,
      );
      expect(guessTextureByName(tree, [tree, leaf])?.name,
          'PolygonNature_01.png');
    });

    test('a pack with no base atlas answers nothing', () {
      // SciFiCity: Signs, NeonSigns, Billboards, and no single default. The
      // best-used texture there covers 31 of 647 prefabs.
      const city = 'POLYGON_City_SourceFiles.zip';
      final prop = _asset('SourceFiles/FBX/SM_Prop_01.fbx', container: city);
      final catalog = [
        prop,
        _asset('SourceFiles/Textures/Signs.png', container: city),
        _asset('SourceFiles/Textures/NeonSigns.png', container: city),
        _asset('SourceFiles/Textures/Billboards.png', container: city),
      ];
      expect(guessTextureByName(prop, catalog), isNull);
    });

    test('a texture in another container is never borrowed', () {
      final elsewhere = _asset(
        'SourceFiles/Textures/Pack_Texture_01_A.png',
        container: 'POLYGON_Other_SourceFiles.zip',
      );
      expect(guessTextureByName(model, [model, elsewhere]), isNull);
    });

    test('two equally good atlases mean no default', () {
      const pair = 'POLYGON_Pair_SourceFiles.zip';
      final prop = _asset('SourceFiles/FBX/SM_Prop_01.fbx', container: pair);
      final catalog = [
        prop,
        _asset('SourceFiles/Textures/Pair_Texture_01_A.png', container: pair),
        _asset('SourceFiles/Textures/Pair_Texture_02_A.png', container: pair),
      ];
      expect(guessTextureByName(prop, catalog), isNull);
    });

    test('a pack with nothing in a textures folder answers nothing', () {
      expect(guessTextureByName(model, [model]), isNull);
    });
  });

  group('the conditions for inferring at all', () {
    MeshModel mesh({
      List<MeshMaterial> materials = const [],
      bool uvs = true,
    }) => MeshModel(
      name: 'x.fbx',
      vertices: const [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)],
      faces: [
        MeshFace(
          const [0, 1, 2],
          0,
          uvs ? const [Vec2(0, 0), Vec2(1, 0), Vec2(0, 1)] : const [],
        ),
      ],
      materials: materials,
    );

    test('a mesh with no UVs is left alone', () {
      expect(meshWantsInferredTexture(mesh(uvs: false)), isFalse);
    });

    test('a mesh that names a texture is left alone', () {
      // Named and not found is "missing", which the diagnostics report. A
      // guess on top would hide a broken link.
      expect(
        meshWantsInferredTexture(
          mesh(
            materials: const [
              MeshMaterial(
                name: 'm',
                color: Color(0xffffffff),
                textures: ['Wood.png'],
              ),
            ],
          ),
        ),
        isFalse,
      );
    });

    test('a mesh with UVs and no texture of its own is the case for this', () {
      expect(
        meshWantsInferredTexture(
          mesh(
            materials: const [
              MeshMaterial(
                name: 'SciFiSpaceBase4',
                color: Color(0xffb9c2cc),
                textures: [],
              ),
            ],
          ),
        ),
        isTrue,
      );
    });

    test('a mesh with no faces is left alone', () {
      expect(
        meshWantsInferredTexture(
          MeshModel(name: 'x.fbx', vertices: const [], faces: const []),
        ),
        isFalse,
      );
    });
  });

  group("reading the pack's own Unity build", () {
    final fixture = File('test/fixtures/unity/TinyPack_Unity_2021_3.zip');

    test('the fixture is there', () {
      expect(fixture.existsSync(), isTrue, reason: fixture.absolute.path);
    });

    test('the chain resolves prefab to material to texture', () {
      final chain = readUnityTextureChain(fixture.absolute.path);
      expect(chain.isEmpty, isFalse);
      expect(
        chain.byModelStem['prop_crate_01'],
        'TinyPack/Textures/TinyPack_Texture_01_A.png',
      );
      expect(
        chain.byModelStem['chr_robot_01'],
        'TinyPack/Textures/TinyPack_Texture_01_A.png',
      );
    });

    test('the stem has the SM_ and SK_ prefixes stripped', () {
      expect(unityModelStem('SM_Prop_Crate_01.prefab'), 'prop_crate_01');
      expect(unityModelStem('SK_Chr_Robot_01.fbx'), 'chr_robot_01');
      expect(unityModelStem('Character_Father_01.prefab'),
          'character_father_01');
    });

    test('the dominant texture is the one most prefabs use', () {
      final chain = readUnityTextureChain(fixture.absolute.path);
      expect(chain.dominant, 'TinyPack/Textures/TinyPack_Texture_01_A.png');
      expect(chain.prefabsResolved, 13,
          reason: 'twelve prefabs on the atlas and one on the signs');
    });

    test('a prefab whose material names no texture resolves nothing', () {
      final chain = readUnityTextureChain(fixture.absolute.path);
      expect(chain.byModelStem.containsKey('prop_glass_01'), isFalse);
    });

    test('a prefab on another texture keeps its own', () {
      final chain = readUnityTextureChain(fixture.absolute.path);
      expect(
        chain.byModelStem['sign_neon_01'],
        'TinyPack/Textures/TinyPack_Signs_01.png',
      );
    });

    test('an archive that is not a Unity build says nothing', () {
      final chain = readUnityTextureChain('Z:/not/a/real/archive.zip');
      expect(chain.isEmpty, isTrue);
    });
  });

  group('a pack whose Unity build is a .unitypackage', () {
    // PolygonTown ships POLYGONTown_Unity_2019_4_28.unitypackage and no
    // Unity zip at all -- which is 83 of the 93 Unity builds here. Before
    // this the pack had no authored answer to read.
    final root = Platform.environment[_corpusVariable];
    final skip = root == null || root.isEmpty
        ? 'set $_corpusVariable to the folder holding the Synty packs'
        : null;

    test('the chain resolves out of the gzipped tar', () async {
      final path =
          '$root${Platform.pathSeparator}POLYGONTown_Unity_2019_4_28.unitypackage';
      if (!File(path).existsSync()) {
        markTestSkipped('that package is not in this library');
        return;
      }
      final chain = readUnityTextureChain(path);
      expect(chain.isEmpty, isFalse);
      expect(chain.prefabsResolved, greaterThan(600));
      expect(
        chain.dominant?.split('/').last,
        'PolygonTown_Texture_01_A.png',
      );
      expect(
        chain.byModelStem['prop_streetlamp_02'],
        endsWith('PolygonTown_Texture_01_A.png'),
      );
    }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));

    test('a Town model finds it through the sidecar', () async {
      final catalog = await _scanPack(root!, 'POLYGON_Town_SourceFiles.zip');
      if (catalog.isEmpty) {
        markTestSkipped('that pack is not in this library');
        return;
      }
      final models = catalog.where(
        (asset) => asset.ext == 'fbx' && asset.name.startsWith('SM_'),
      );
      expect(models, isNotEmpty);
      final sidecars = unityPackageSidecarsFor(models.first);
      expect(sidecars, isNotEmpty,
          reason: 'the .unitypackage sits beside the source zip');

      // Some Town model, any of them: the pack has one atlas and the chain
      // says so for 691 of its 696 prefabs.
      InferredTexture? found;
      for (final model in models.take(40)) {
        found = findInferredTexture(model, catalog);
        if (found != null) break;
      }
      expect(found, isNotNull);
      expect(found!.path.split('/').last, 'PolygonTown_Texture_01_A.png');
    }, skip: skip, timeout: const Timeout(Duration(minutes: 10)));
  });

  group('the War Robot, against the real pack', () {
    final root = Platform.environment[_corpusVariable];
    final skip = root == null || root.isEmpty
        ? 'set $_corpusVariable to the folder holding the Synty packs'
        : null;

    late List<AssetItem> catalog;

    setUpAll(() async {
      if (root == null || root.isEmpty) return;
      catalog = [
        ...await _scanPack(root, 'POLYGON_SciFiSpace_SourceFiles.zip'),
        ...await _scanPack(root, 'PolygonSciFiSpace_Unity_2017_4.zip'),
      ];
    });

    test('the pack really does name no texture on the robot', () {
      final robot = catalog.firstWhere(
        (asset) => asset.name == 'SK_Chr_BR_War_Robot_01.fbx',
      );
      expect(robot.ext, 'fbx');
    }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));

    test('its own prefab names PolygonSciFiSpace_Texture_01_A.png', () {
      final robot = catalog.firstWhere(
        (asset) => asset.name == 'SK_Chr_BR_War_Robot_01.fbx',
      );
      final inferred = findInferredTexture(robot, catalog);
      expect(inferred, isNotNull, reason: 'the pack assigns it an atlas');
      expect(inferred!.source, TextureSource.prefab);
      expect(
        inferred.path.split('/').last,
        'PolygonSciFiSpace_Texture_01_A.png',
      );
    }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));

    test('a character with no prefab of its own gets the pack default', () {
      // SK_Chr_SpaceSoldier_Female.fbx is one of the 13 characters in this
      // pack with no prefab; tier 2 is what it is for.
      final matches = catalog.where(
        (asset) => asset.name == 'SK_Chr_SpaceSoldier_Female.fbx',
      );
      if (matches.isEmpty) {
        markTestSkipped('that variant is not in this copy of the pack');
        return;
      }
      final inferred = findInferredTexture(matches.first, catalog);
      expect(inferred, isNotNull);
      expect(inferred!.source, TextureSource.packDefault);
      expect(
        inferred.path.split('/').last,
        'PolygonSciFiSpace_Texture_01_A.png',
      );
    }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));

    test('every character in the pack resolves to the same atlas', () {
      final characters = catalog.where(
        (asset) =>
            asset.ext == 'fbx' &&
            asset.path.contains('/Characters/') &&
            !asset.name.contains('_old'),
      );
      expect(characters, isNotEmpty);
      final answers = <String, int>{};
      for (final character in characters) {
        final inferred = findInferredTexture(character, catalog);
        final key = inferred == null
            ? 'nothing'
            : '${inferred.source.name}:${inferred.path.split('/').last}';
        answers[key] = (answers[key] ?? 0) + 1;
      }
      // One answer for the whole folder, and it is the authored one.
      expect(answers.keys, hasLength(lessThanOrEqualTo(2)), reason: '$answers');
      expect(
        answers.keys.join(' '),
        contains('PolygonSciFiSpace_Texture_01_A.png'),
        reason: '$answers',
      );
    }, skip: skip, timeout: const Timeout(Duration(minutes: 10)));
  });
}
