import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

// Marker sets as the importer's probe actually reports them.
const _polygon = ['Hips', 'UpperLeg_R', 'Clavicle_L', 'Spine_01'];
const _sidekick = [
  'pelvis',
  'thigh_l',
  'clavicle_l',
  'spine_01',
  'hipAttachFront',
  'hipAttach_l',
  'ik_hand_gun',
  'ik_hand_root',
];
const _unreal = [
  'pelvis',
  'thigh_l',
  'clavicle_l',
  'spine_01',
  'ik_hand_gun',
  'ik_hand_root',
];

void main() {
  group('rigFamilyFromMarkers', () {
    test('Synty capitalised names are the Polygon rig', () {
      expect(rigFamilyFromMarkers(_polygon), RigFamily.polygon);
    });

    test('the mannequin plus attachment bones is Sidekick', () {
      expect(rigFamilyFromMarkers(_sidekick), RigFamily.sidekick);
    });

    test('the mannequin without them is plain Unreal', () {
      expect(rigFamilyFromMarkers(_unreal), RigFamily.unreal);
    });

    test('Sidekick is checked before Unreal, since it has both', () {
      // Every mannequin bone appears in a Sidekick rig, so testing for
      // `pelvis` first would classify every Sidekick file as Unreal.
      expect(rigFamilyFromMarkers(_sidekick), isNot(RigFamily.unreal));
    });

    test('a prop with no bones has no rig', () {
      expect(rigFamilyFromMarkers(const []), RigFamily.none);
    });

    test('an unrecognised skeleton is not forced into a family', () {
      expect(rigFamilyFromMarkers(const ['Bone_01']), RigFamily.none);
    });

    test('the SK_ prefix does not decide it', () {
      // SK_Chr_MilitaryMale_01 carries the Polygon markers despite the name.
      expect(rigFamilyFromMarkers(_polygon), RigFamily.polygon);
    });
  });

  group('rigFamiliesCompatible', () {
    test('a family drives itself', () {
      expect(
        rigFamiliesCompatible(RigFamily.polygon, RigFamily.polygon),
        isTrue,
      );
    });

    test('families never drive each other', () {
      expect(
        rigFamiliesCompatible(RigFamily.polygon, RigFamily.sidekick),
        isFalse,
      );
      expect(
        rigFamiliesCompatible(RigFamily.sidekick, RigFamily.unreal),
        isFalse,
        reason: 'Sidekick adds bones, so its clips assume they are there',
      );
    });

    test('a rigless prop is compatible with nothing, including itself', () {
      expect(rigFamiliesCompatible(RigFamily.none, RigFamily.none), isFalse);
    });
  });

  group('labels', () {
    test('each family has one for the filter menu', () {
      expect(RigFamily.polygon.label, 'Polygon');
      expect(RigFamily.sidekick.label, 'Sidekick');
      expect(RigFamily.unreal.label, 'Unreal');
      expect(RigFamily.none.label, 'No rig');
    });
  });
}
