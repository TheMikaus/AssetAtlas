import 'package:flutter_test/flutter_test.dart';
import 'package:asset_atlas_native/main.dart';

/// The index that relinking now uses has to pick the same texture the walk it
/// replaced picked.
///
/// That is the whole risk of the change. A faster lookup that resolves one
/// tie differently would bake a mis-textured render into every embedding in
/// the library, and nothing downstream would notice. So `byScan: true` keeps
/// the original walk reachable and these tests hold the two to the same
/// answer -- not the same partition, the same chosen path.
void main() {
  var serial = 0;
  AssetItem assetAt(String path, {required String sourceRoot}) {
    serial += 1;
    final name = path.split(RegExp(r'[\\/:]')).last;
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    return AssetItem(
      id: 'asset-$serial',
      name: name,
      path: path,
      relativePath: name,
      sourceRoot: sourceRoot,
      sourceName: 'test',
      ext: ext,
      type: const {'png', 'jpg', 'tga', 'psd', 'bmp'}.contains(ext)
          ? 'image'
          : 'model',
      size: 1024,
      modified: DateTime(2026, 1, 1),
      tags: const [],
    );
  }

  /// Asks both ways and insists they agree.
  ///
  /// The index caches on the catalog and on the container, so the order the
  /// questions are asked in is part of what is being tested: each call here
  /// runs the scan first and the index second, against caches warmed by
  /// whatever was asked before it.
  void expectSameAnswer(
    String modelPath,
    String texturePath,
    List<AssetItem> catalog, {
    String? because,
  }) {
    final byScan = findDeterministicTextureRelink(
      modelPath,
      texturePath,
      catalog,
      byScan: true,
    );
    final byIndex = findDeterministicTextureRelink(
      modelPath,
      texturePath,
      catalog,
    );
    expect(
      byIndex,
      byScan,
      reason: because ?? '$modelPath asking for $texturePath',
    );
  }

  group('the same texture wins', () {
    test('for a plain model beside its textures', () {
      final catalog = [
        assetAt('Z:/Assets/PackA/Models/SM_Barrel.fbx',
            sourceRoot: 'Z:/Assets/PackA'),
        assetAt('Z:/Assets/PackA/Textures/T_Barrel_BC.png',
            sourceRoot: 'Z:/Assets/PackA'),
        assetAt('Z:/Assets/PackA/Textures/T_Barrel_N.png',
            sourceRoot: 'Z:/Assets/PackA'),
        assetAt('Z:/Assets/PackB/Textures/T_Barrel_BC.png',
            sourceRoot: 'Z:/Assets/PackB'),
      ];
      for (final reference in const [
        'T_Barrel_BC.tga',
        'T_Barrel_N.tga',
        'T_Barrel.tga',
        'T_Missing.tga',
      ]) {
        expectSameAnswer(
          'Z:/Assets/PackA/Models/SM_Barrel.fbx',
          reference,
          catalog,
        );
      }
    });

    test('when source roots nest, so two containers are beside the model', () {
      // The deep root and the root above it both prefix the model path. The
      // walk counted the textures under both, and the index has to merge the
      // two buckets rather than pick one.
      final catalog = [
        assetAt('Z:/Assets/PackA/Models/SM_Crate.fbx',
            sourceRoot: 'Z:/Assets/PackA'),
        assetAt('Z:/Assets/Shared/T_Crate_BC.png', sourceRoot: 'Z:/Assets'),
        assetAt('Z:/Assets/PackA/Textures/T_Crate_BC.png',
            sourceRoot: 'Z:/Assets/PackA'),
        assetAt('Z:/Assets/PackA/Textures/T_Crate_01_A.png',
            sourceRoot: 'Z:/Assets/PackA'),
      ];
      for (final reference in const [
        'T_Crate_BC.tga',
        'T_Crate_01.psd',
        'T_Crate.png',
      ]) {
        expectSameAnswer(
          'Z:/Assets/PackA/Models/SM_Crate.fbx',
          reference,
          catalog,
        );
      }
    });

    test('for a model inside an archive', () {
      final catalog = [
        assetAt('zip:Z:/Zips/PackC.zip::Models/SM_Sign.fbx',
            sourceRoot: 'Z:/Zips'),
        assetAt('zip:Z:/Zips/PackC.zip::Textures/T_Sign_BC.png',
            sourceRoot: 'Z:/Zips'),
        assetAt('zip:Z:/Zips/PackD.zip::Textures/T_Sign_BC.png',
            sourceRoot: 'Z:/Zips'),
        assetAt('Z:/Assets/Loose/T_Sign_BC.png', sourceRoot: 'Z:/Assets'),
      ];
      for (final reference in const ['T_Sign_BC.tga', 'T_Nothing.tga']) {
        expectSameAnswer(
          'zip:Z:/Zips/PackC.zip::Models/SM_Sign.fbx',
          reference,
          catalog,
        );
      }
    });

    test('when the archive path is spelled differently', () {
      // Containers are compared on the normalized path, so a model reached
      // through backslashes is in the same archive as a texture reached
      // through forward slashes.
      final catalog = [
        assetAt(r'zip:Z:\Zips\PackE.zip::Models/SM_Keg.fbx',
            sourceRoot: 'Z:/Zips'),
        assetAt('zip:Z:/Zips/PackE.zip::Textures/T_Keg_BC.png',
            sourceRoot: 'Z:/Zips'),
      ];
      expectSameAnswer(
        r'zip:Z:\Zips\PackE.zip::Models/SM_Keg.fbx',
        'T_Keg_BC.tga',
        catalog,
      );
    });

    test('for a malformed archive path, which is in no container', () {
      final catalog = [
        assetAt('Z:/Assets/PackF/Models/SM_Hut.fbx',
            sourceRoot: 'Z:/Assets/PackF'),
        assetAt('zip:::T_Hut_BC.png', sourceRoot: 'Z:/Assets/PackF'),
        assetAt('zip:Z:/Zips/::', sourceRoot: 'Z:/Assets/PackF'),
        assetAt('Z:/Assets/PackF/Textures/T_Hut_BC.png',
            sourceRoot: 'Z:/Assets/PackF'),
      ];
      expectSameAnswer(
        'Z:/Assets/PackF/Models/SM_Hut.fbx',
        'T_Hut_BC.tga',
        catalog,
      );
      expectSameAnswer('zip:::T_Hut_BC.png', 'T_Hut_BC.tga', catalog);
    });

    test('when only another pack has the name, so it crosses containers', () {
      final catalog = [
        assetAt('Z:/Assets/PackG/Models/SM_Door.fbx',
            sourceRoot: 'Z:/Assets/PackG'),
        assetAt('Z:/Assets/PackG/Textures/T_Wall_BC.png',
            sourceRoot: 'Z:/Assets/PackG'),
        assetAt('Z:/Assets/PackH/Textures/T_Door_BC.png',
            sourceRoot: 'Z:/Assets/PackH'),
        assetAt('Z:/Assets/PackI/Textures/T_Door_BC.png',
            sourceRoot: 'Z:/Assets/PackI'),
      ];
      for (final reference in const [
        'T_Door_BC.tga',
        'PackH/Textures/T_Door_BC.tga',
        'PackI/Textures/T_Door_BC.tga',
      ]) {
        expectSameAnswer(
          'Z:/Assets/PackG/Models/SM_Door.fbx',
          reference,
          catalog,
        );
      }
    });

    test('for a model with no textures anywhere near it', () {
      final catalog = [
        assetAt('Z:/Assets/PackJ/Models/SM_Alone.fbx',
            sourceRoot: 'Z:/Assets/PackJ'),
        assetAt('Z:/Assets/PackK/Textures/T_Other_BC.png',
            sourceRoot: 'Z:/Assets/PackK'),
      ];
      expectSameAnswer(
        'Z:/Assets/PackJ/Models/SM_Alone.fbx',
        'T_Whatever.tga',
        catalog,
      );
    });

    test('for a model under no known source root at all', () {
      final catalog = [
        assetAt('Z:/Assets/PackL/Textures/T_Thing_BC.png',
            sourceRoot: 'Z:/Assets/PackL'),
      ];
      expectSameAnswer('Q:/Elsewhere/SM_Thing.fbx', 'T_Thing_BC.tga', catalog);
    });
  });

  group('the caches do not go stale', () {
    // The index is cached on the catalog and the resolved container list on
    // the container, which is the one thing the old cache did not do. Asking
    // about a second container must not answer out of the first.
    final catalog = [
      assetAt('Z:/Assets/PackM/Models/SM_One.fbx',
          sourceRoot: 'Z:/Assets/PackM'),
      assetAt('Z:/Assets/PackM/Textures/T_Shared_BC.png',
          sourceRoot: 'Z:/Assets/PackM'),
      assetAt('Z:/Assets/PackN/Models/SM_Two.fbx',
          sourceRoot: 'Z:/Assets/PackN'),
      assetAt('Z:/Assets/PackN/Textures/T_Shared_BC.png',
          sourceRoot: 'Z:/Assets/PackN'),
      assetAt('zip:Z:/Zips/PackO.zip::Models/SM_Three.fbx',
          sourceRoot: 'Z:/Zips'),
      assetAt('zip:Z:/Zips/PackO.zip::Textures/T_Shared_BC.png',
          sourceRoot: 'Z:/Zips'),
    ];
    const models = [
      'Z:/Assets/PackM/Models/SM_One.fbx',
      'Z:/Assets/PackN/Models/SM_Two.fbx',
      'zip:Z:/Zips/PackO.zip::Models/SM_Three.fbx',
    ];

    test('switching containers back and forth', () {
      for (final model in [...models, ...models.reversed, ...models]) {
        expectSameAnswer(model, 'T_Shared_BC.tga', catalog);
      }
    });

    test('each model gets the texture from its own container', () {
      // Not only "the same as the scan" -- the answers have to differ from
      // each other, or a cache that ignored the model would pass the test
      // above by accident.
      final answers = [
        for (final model in models)
          findDeterministicTextureRelink(model, 'T_Shared_BC.tga', catalog),
      ];
      expect(answers.whereType<String>().length, models.length);
      expect(answers.toSet().length, models.length, reason: '$answers');
    });

    test('a changed catalog is not answered from the old one', () {
      final model = 'Z:/Assets/PackM/Models/SM_One.fbx';
      expectSameAnswer(model, 'T_Shared_BC.tga', catalog);

      final withoutPackM = [
        for (final asset in catalog)
          if (!asset.path.contains('/PackM/Textures/')) asset,
      ];
      expectSameAnswer(
        model,
        'T_Shared_BC.tga',
        withoutPackM,
        because: 'the texture it used to find is gone',
      );
      expect(
        findDeterministicTextureRelink(
          model,
          'T_Shared_BC.tga',
          withoutPackM,
        ),
        isNot(contains('/PackM/')),
      );
    });
  });

  group('the partition itself', () {
    final catalog = [
      assetAt('Z:/Assets/PackP/Models/SM_Thing.fbx',
          sourceRoot: 'Z:/Assets/PackP'),
      assetAt('Z:/Assets/PackP/Textures/T_A.png',
          sourceRoot: 'Z:/Assets/PackP'),
      assetAt('Z:/Assets/Shared/T_B.png', sourceRoot: 'Z:/Assets'),
      assetAt('Z:/Assets/PackP/Textures/T_C.png',
          sourceRoot: 'Z:/Assets/PackP'),
      assetAt('Z:/Assets/PackQ/Textures/T_A.png',
          sourceRoot: 'Z:/Assets/PackQ'),
      assetAt('zip:Z:/Zips/PackR.zip::T_A.png', sourceRoot: 'Z:/Zips'),
      assetAt('Z:/Assets/PackP/Readme.txt', sourceRoot: 'Z:/Assets/PackP'),
    ];
    const model = 'Z:/Assets/PackP/Models/SM_Thing.fbx';

    test('holds the same assets as the walk, in the same order', () {
      // Order is not supposed to matter -- the scorer breaks ties on the
      // normalized path for exactly that reason -- but two textures whose
      // paths normalize alike would make it matter, so it is kept anyway.
      expect(
        relinkSameContainerByScan(model, catalog).map((asset) => asset.path),
        [
          'Z:/Assets/PackP/Textures/T_A.png',
          'Z:/Assets/Shared/T_B.png',
          'Z:/Assets/PackP/Textures/T_C.png',
        ],
      );
    });

    test('leaves the other containers to the name lookup', () {
      expect(
        relinkOtherContainersByScan(model, 't_a', catalog)
            .map((asset) => asset.path),
        [
          'Z:/Assets/PackQ/Textures/T_A.png',
          'zip:Z:/Zips/PackR.zip::T_A.png',
        ],
      );
    });

    test('and ignores anything that is not a texture', () {
      expect(
        relinkSameContainerByScan(model, catalog)
            .where((asset) => asset.ext == 'txt'),
        isEmpty,
      );
    });
  });
}
