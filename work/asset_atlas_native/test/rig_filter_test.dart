import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

AssetItem _asset({String? rig}) => AssetItem(
  id: 'test:$rig',
  name: 'A_Idle.fbx',
  path: r'C:\Packs\A_Idle.fbx',
  relativePath: 'A_Idle.fbx',
  sourceRoot: r'C:\Packs',
  sourceName: 'Packs',
  ext: 'fbx',
  type: 'model',
  size: 1,
  modified: DateTime.fromMillisecondsSinceEpoch(0),
  tags: const [],
  rigFamily: rig,
);

void main() {
  group('rigFamilyByName', () {
    test('reads a stored name back', () {
      expect(rigFamilyByName('polygon'), RigFamily.polygon);
      expect(rigFamilyByName('sidekick'), RigFamily.sidekick);
    });

    test('an unknown or missing name is no rig', () {
      expect(rigFamilyByName(null), RigFamily.none);
      expect(rigFamilyByName('mannequin_v2'), RigFamily.none);
    });
  });

  group('assetPassesRigFilter', () {
    bool passes({String? rig, required String filter, String? character}) =>
        assetPassesRigFilter(
          asset: _asset(rig: rig),
          rigFilter: filter,
          characterRig: character,
        );

    test('all lets everything through', () {
      expect(passes(rig: 'polygon', filter: 'all'), isTrue);
      expect(passes(rig: null, filter: 'all'), isTrue);
    });

    test('a named family keeps only that family', () {
      expect(passes(rig: 'polygon', filter: 'polygon'), isTrue);
      expect(passes(rig: 'sidekick', filter: 'polygon'), isFalse);
    });

    test('compatible keeps what the chosen character can use', () {
      expect(
        passes(rig: 'polygon', filter: 'compatible', character: 'polygon'),
        isTrue,
      );
      expect(
        passes(rig: 'sidekick', filter: 'compatible', character: 'polygon'),
        isFalse,
      );
    });

    test('compatible with no character chosen hides nothing', () {
      expect(passes(rig: 'sidekick', filter: 'compatible'), isTrue);
    });

    test('an unclassified file is never hidden', () {
      // Nothing has probed it, so excluding it would assert something the
      // catalog does not know.
      expect(passes(rig: null, filter: 'polygon'), isTrue);
      expect(
        passes(rig: null, filter: 'compatible', character: 'polygon'),
        isTrue,
      );
    });

    test('a rigless prop is excluded from a family filter', () {
      expect(passes(rig: 'none', filter: 'polygon'), isFalse);
      expect(
        passes(rig: 'none', filter: 'compatible', character: 'polygon'),
        isFalse,
        reason: 'a prop has no bones for a clip to move',
      );
    });

    test('the no-rig filter finds props', () {
      expect(passes(rig: 'none', filter: 'none'), isTrue);
      expect(passes(rig: 'polygon', filter: 'none'), isFalse);
    });
  });

  group('FbxClassification', () {
    test('round-trips a kind and a rig', () {
      const c = FbxClassification(kind: 'animation', rig: 'sidekick');
      final back = FbxClassification.decode(c.encode());
      expect(back.kind, 'animation');
      expect(back.rig, 'sidekick');
    });

    test('an older value with no rig still decodes', () {
      // Catalogs written before the rig column existed hold a bare kind.
      final back = FbxClassification.decode('mesh');
      expect(back.kind, 'mesh');
      expect(back.rig, isNull);
    });

    test('a kind with no rig encodes without the separator', () {
      expect(const FbxClassification(kind: 'mesh', rig: null).encode(), 'mesh');
    });
  });
}
