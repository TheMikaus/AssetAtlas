// Which skeleton a file is on, and which character can stand in for a clip's
// rig -- both decided from what is inside the files, never from their names.
//
// The rule these pin: no folder name and no filename prefix may decide a rig
// question. Synty's own conventions contradict each other (`SK_` is Unreal's
// skeletal-mesh prefix and sits on Polygon-rigged characters; `SM_Chr_*` files
// turn out to be skinned), so anything read off a path is a guess. The
// reference lookup in particular used to require `/character` in the path,
// which is a habit of two packs rather than a fact about files.
import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

AssetItem _asset(
  String path, {
  String ext = 'fbx',
  String type = 'model',
  String? modelKind,
  String? rigFamily,
}) => AssetItem(
  id: path,
  name: path.split(RegExp(r'[/\\]')).last,
  path: path,
  relativePath: path,
  sourceRoot: r'C:\Packs',
  sourceName: 'Packs',
  ext: ext,
  type: type,
  size: 1,
  modified: DateTime.fromMillisecondsSinceEpoch(0),
  tags: const [],
  modelKind: modelKind,
  rigFamily: rigFamily,
);

SkeletonAnimation _rig(List<String> bones) => SkeletonAnimation.fromJson({
  'bones': [
    for (var i = 0; i < bones.length; i += 1)
      {
        'name': bones[i],
        'parent': i == 0 ? -1 : i - 1,
        'path': bones.take(i + 1).join('/'),
      },
  ],
  'stride': 12,
  'frameRate': 30.0,
  'frames': [
    [for (var i = 0; i < bones.length * 12; i += 1) i % 12 < 9 ? 1.0 : 0.0],
  ],
})!;

void main() {
  group('naming a rig from its own bones', () {
    test('Synty capitalisation is Polygon', () {
      expect(
        rigFamilyOfSkeleton(_rig(['Root', 'Hips', 'Spine_01', 'UpperLeg_R'])),
        RigFamily.polygon,
      );
    });

    test('mannequin lowercase is Unreal', () {
      expect(
        rigFamilyOfSkeleton(_rig(['root', 'pelvis', 'spine_01', 'thigh_l'])),
        RigFamily.unreal,
      );
    });

    test('the mannequin plus attachment bones is Sidekick, not Unreal', () {
      // Sidekick carries every mannequin bone as well, so testing for the
      // mannequin first would swallow it.
      expect(
        rigFamilyOfSkeleton(
          _rig(['root', 'pelvis', 'spine_01', 'thigh_l', 'hipAttachFront']),
        ),
        RigFamily.sidekick,
      );
    });

    test('a rig of unrecognised bones is no family, not a wrong guess', () {
      expect(
        rigFamilyOfSkeleton(_rig(['Bone', 'Bone_A', 'Bone_B'])),
        RigFamily.none,
      );
    });

    test('case decides between two families that both have a spine_01', () {
      expect(
        rigFamilyOfSkeleton(_rig(['Root', 'Spine_01', 'Hips'])),
        RigFamily.polygon,
      );
      expect(
        rigFamilyOfSkeleton(_rig(['root', 'spine_01', 'pelvis'])),
        RigFamily.unreal,
      );
    });
  });

  group('finding a clip a reference character', () {
    const clip = r'C:\Packs\Anim\Clips\A_Idle_Standing.fbx';

    test('a character is found in a folder not called character', () {
      final found = findClipReferenceCharacters(clip, [
        _asset(clip, modelKind: 'animation', rigFamily: 'polygon'),
        _asset(
          r'C:\Packs\Anim\Rigs\BaseMale.fbx',
          modelKind: 'mesh',
          rigFamily: 'polygon',
        ),
      ]);
      expect(found.map((a) => a.name), ['BaseMale.fbx']);
    });

    test('a clip is never offered as its own reference', () {
      final found = findClipReferenceCharacters(clip, [
        _asset(clip, modelKind: 'animation'),
        _asset(
          r'C:\Packs\Anim\Clips\A_Walk_Fwd.fbx',
          modelKind: 'animation',
          rigFamily: 'polygon',
        ),
      ]);
      expect(
        found,
        isEmpty,
        reason: 'a clip has no mesh and no bind pose to correct against',
      );
    });

    test('a rig from another family is not offered', () {
      final found = findClipReferenceCharacters(
        clip,
        [
          _asset(clip, modelKind: 'animation'),
          _asset(
            r'C:\Packs\Anim\A\Polygon.fbx',
            modelKind: 'mesh',
            rigFamily: 'polygon',
          ),
          _asset(
            r'C:\Packs\Anim\A\Sidekick.fbx',
            modelKind: 'mesh',
            rigFamily: 'sidekick',
          ),
        ],
        clipRig: RigFamily.polygon,
      );
      expect(found.map((a) => a.name), ['Polygon.fbx']);
    });

    test('a file nothing has probed yet is still offered', () {
      final found = findClipReferenceCharacters(
        clip,
        [
          _asset(clip, modelKind: 'animation'),
          _asset(r'C:\Packs\Anim\A\Unknown.fbx'),
        ],
        clipRig: RigFamily.polygon,
      );
      expect(
        found.map((a) => a.name),
        ['Unknown.fbx'],
        reason: 'hiding it would assert something the catalog does not know',
      );
    });

    test('a known rig shuts out the guesses and the props', () {
      final found = findClipReferenceCharacters(clip, [
        _asset(clip, modelKind: 'animation'),
        _asset(
          r'C:\Packs\Anim\A\Crate.fbx',
          modelKind: 'mesh',
          rigFamily: 'none',
        ),
        _asset(r'C:\Packs\Anim\A\Unknown.fbx'),
        _asset(
          r'C:\Packs\Anim\A\Rigged.fbx',
          modelKind: 'mesh',
          rigFamily: 'polygon',
        ),
      ]);
      expect(found.map((a) => a.name), ['Rigged.fbx']);
    });

    test('with nothing classified, the unprobed files are all there is', () {
      final found = findClipReferenceCharacters(clip, [
        _asset(clip),
        _asset(r'C:\Packs\Anim\A\Maybe.fbx'),
      ]);
      expect(
        found.map((a) => a.name),
        ['Maybe.fbx'],
        reason: 'a cold catalog must still be able to find a reference',
      );
    });

    test('a prop is never a reference, even when it is the only file', () {
      final found = findClipReferenceCharacters(clip, [
        _asset(clip, modelKind: 'animation'),
        _asset(
          r'C:\Packs\Anim\A\Crate.fbx',
          modelKind: 'mesh',
          rigFamily: 'none',
        ),
      ]);
      expect(found, isEmpty, reason: 'a crate has no rig to correct against');
    });

    test('a character in another pack is not reachable', () {
      final found = findClipReferenceCharacters(clip, [
        _asset(clip, modelKind: 'animation'),
        _asset(
          r'C:\Packs\Other\Character\BaseMale.fbx',
          modelKind: 'mesh',
          rigFamily: 'polygon',
        ),
      ]);
      expect(
        found,
        isEmpty,
        reason: 'a reference must be the rig this clip was authored on',
      );
    });

    test('candidates are capped, so one pack cannot cost a hundred imports', () {
      final found = findClipReferenceCharacters(clip, [
        _asset(clip, modelKind: 'animation'),
        for (var i = 0; i < maxReferenceCandidates + 10; i += 1)
          _asset(
            '${r'C:\Packs\Anim\A\Rig_'}$i.fbx',
            modelKind: 'mesh',
            rigFamily: 'polygon',
          ),
      ]);
      expect(found, hasLength(maxReferenceCandidates));
    });
  });
}
