import 'dart:convert';
import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bone names read out of the real files, so the case mixture is Synty's.
Map<String, List<String>> loadBoneNameFixture() {
  final file = File('test/fixtures/rig_bone_names.json');
  if (!file.existsSync()) {
    throw StateError(
      'rig_bone_names.json is missing at ${file.absolute.path}; the '
      'case-folding tests are meaningless without the real name lists.',
    );
  }
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final entry in json.entries)
      if (entry.value is List)
        entry.key: (entry.value as List).map((v) => v as String).toList(),
  };
}

/// A skeleton of named bones in a chain, one frame, identity transforms.
SkeletonAnimation skeletonOf(List<String> names) =>
    SkeletonAnimation.fromJson(<String, dynamic>{
      'bones': [
        for (var i = 0; i < names.length; i += 1)
          {
            'name': names[i],
            'parent': i == 0 ? -1 : i - 1,
            'path': names.take(i + 1).join('/'),
          },
      ],
      'stride': 12,
      'frameRate': 30.0,
      'frames': [
        [
          for (var i = 0; i < names.length; i += 1) ..._bone(0, i.toDouble(), 0),
        ],
      ],
    })!;

/// A bone's world transform: identity basis, then the position.
///
/// Frames carry full 3x4 matrices rather than bare positions, because skinning
/// needs the rotation too; the position is the last column.
List<double> _bone(double x, double y, double z) => [
  1, 0, 0, //
  0, 1, 0,
  0, 0, 1,
  x, y, z,
];

/// Two bones, three frames, the tip rising each frame.
Map<String, dynamic> _clip() => <String, dynamic>{
  'bones': [
    {'name': 'Root', 'parent': -1},
    {'name': 'Hips', 'parent': 0},
  ],
  'stride': 12,
  'frameRate': 30.0,
  'frames': [
    [..._bone(0, 0, 0), ..._bone(0, 1, 0)],
    [..._bone(0, 0, 0), ..._bone(0, 2, 0)],
    [..._bone(0, 0, 0), ..._bone(0, 3, 0)],
  ],
};

void main() {
  group('indexOfBone folds case, after every exact form has failed', () {
    test('a lower-case clip bone finds a capitalised character bone', () {
      // Synty's exporter writes Pelvis in the character and pelvis in the
      // clip, inside the same pack. Nine joints of the War Robot differ from
      // the Sidekick clips by case alone -- hips, legs, feet, arms, hands.
      final rig = skeletonOf(['Root', 'Pelvis', 'Thigh_L']);
      expect(rig.indexOfBone('pelvis'), 1);
      expect(rig.indexOfBone('THIGH_L'), 2);
    });

    test('an exact match still wins over a folded one', () {
      final rig = skeletonOf(['hand_l', 'Hand_L']);
      expect(rig.indexOfBone('Hand_L'), 1);
      expect(rig.indexOfBone('hand_l'), 0);
    });

    test('a name that folds onto two bones matches neither', () {
      // Never guess which of the two was meant. Not seen in this library;
      // handled because the cost of being wrong is a limb driven by the
      // wrong bone.
      final rig = skeletonOf(['Root', 'Hips', 'hips']);
      expect(rig.indexOfBone('HIPS'), -1);
      expect(rig.indexOfBone('Hips'), 1, reason: 'exact runs first');
      expect(rig.indexOfBone('hips'), 2);
    });

    test('a path differing only in case resolves', () {
      final rig = skeletonOf(['Root', 'Pelvis', 'Spine_01']);
      expect(rig.indexOfBone('nothing', path: 'root/pelvis'), 1);
    });

    test('an unknown bone is still -1', () {
      final rig = skeletonOf(['Root', 'Pelvis']);
      expect(rig.indexOfBone('clavicle_l'), -1);
    });

    group('the War Robot against a Sidekick clip', () {
      final fixture = loadBoneNameFixture();
      final character = skeletonOf(fixture['warRobotCharacter']!);
      final clip = skeletonOf(fixture['sidekickClip']!);

      test('the fixture is the real thing', () {
        expect(character.bones, hasLength(48));
        expect(clip.bones, hasLength(121));
      });

      test('the nine case-only joints resolve in the clip', () {
        // Every one of these fails before the fold: a walk clip moved the
        // spine and left the legs in the bind pose.
        for (final bone in [
          'Pelvis',
          'Thigh_L',
          'Thigh_R',
          'Foot_L',
          'Foot_R',
          'UpperArm_L',
          'UpperArm_R',
          'Hand_L',
          'Hand_R',
        ]) {
          expect(
            clip.indexOfBone(bone),
            greaterThanOrEqualTo(0),
            reason: '$bone is the character spelling; the clip writes it '
                'lower-case',
          );
        }
      });

      test('folding raises the shared-bone count, it does not lower it', () {
        expect(
          rigBoneOverlap(character, clip),
          greaterThanOrEqualTo(28),
          reason: '19 of 48 matched exactly; the nine case-only joints are '
              'the difference',
        );
      });
    });
  });

  group('rigMatch', () {
    final fixture = loadBoneNameFixture();

    test('the War Robot and a Sidekick clip are a match', () {
      final character = skeletonOf(fixture['warRobotCharacter']!);
      final clip = skeletonOf(fixture['sidekickClip']!);
      expect(rigMatch(character, clip), isTrue);
    });

    test('a Polygon character and a Sidekick clip are not', () {
      // Folded, these share about 27% of the character's bones -- Spine_01
      // against spine_01, Head against head -- which is well over the old
      // four-bone floor. The fraction is what keeps them apart.
      final character = skeletonOf(fixture['polygonCharacter']!);
      final clip = skeletonOf(fixture['sidekickClip']!);
      final matches = rigBoneMatches(character, clip);
      expect(matches.exact, 0, reason: 'not one name in common, exactly');
      expect(
        matches.folded / character.bones.length,
        lessThan(minimumRigMatchFraction),
      );
      expect(rigMatch(character, clip), isFalse);
    });

    test('a Polygon character and a Polygon clip are a match', () {
      final character = skeletonOf(fixture['polygonCharacter']!);
      final clip = skeletonOf(fixture['polygonClip']!);
      expect(rigMatch(character, clip), isTrue);
    });

    test('the old count rule still passes on its own', () {
      // Five shared names out of sixty is 8% -- far below the fraction -- and
      // paired before this change, so it must still pair. This is the "do not
      // lose what works" half of the rule.
      final shared = ['Hips', 'Spine_01', 'Head', 'Hand_L', 'Hand_R'];
      final character = skeletonOf([
        ...shared,
        for (var i = 0; i < 55; i += 1) 'CharacterOnly_$i',
      ]);
      final clip = skeletonOf([
        ...shared,
        for (var i = 0; i < 40; i += 1) 'ClipOnly_$i',
      ]);
      final matches = rigBoneMatches(character, clip);
      expect(matches.exact, 5);
      expect(matches.folded / character.bones.length, lessThan(0.2));
      expect(rigMatch(character, clip), isTrue);
    });

    test('three shared names out of sixty is not a match', () {
      // Kenney's rig shares exactly three names with the Polygon rig, which
      // is why the floor is four and not three.
      final shared = ['Hips', 'Spine_01', 'Head'];
      final character = skeletonOf([
        ...shared,
        for (var i = 0; i < 57; i += 1) 'CharacterOnly_$i',
      ]);
      final clip = skeletonOf([
        ...shared,
        for (var i = 0; i < 40; i += 1) 'ClipOnly_$i',
      ]);
      expect(rigMatch(character, clip), isFalse);
    });

    test('a character with no bones matches nothing', () {
      // fromJson refuses an empty bone list, so this cannot arrive from a
      // file; the guard is here because a fraction of zero bones is not a
      // number.
      const boneless = SkeletonAnimation(
        bones: [],
        positions: [],
        frameRate: 30,
      );
      final clip = skeletonOf(fixture['sidekickClip']!);
      expect(rigMatch(boneless, clip), isFalse);
    });

    test('case alone is enough to match a whole rig', () {
      final names = ['Root', 'Pelvis', 'Spine_01', 'Thigh_L', 'Thigh_R'];
      final character = skeletonOf(names);
      final clip = skeletonOf(names.map((n) => n.toLowerCase()).toList());
      final matches = rigBoneMatches(character, clip);
      expect(
        matches.exact,
        0,
        reason: 'every name and every path differs in case',
      );
      expect(matches.folded, 5);
      expect(rigMatch(character, clip), isTrue);
    });
  });

  group('SkeletonAnimation.fromJson', () {
    test('reads the hierarchy and the frames', () {
      final skeleton = SkeletonAnimation.fromJson(_clip())!;
      expect(skeleton.bones.map((b) => b.name), ['Root', 'Hips']);
      expect(skeleton.bones[0].parent, -1);
      expect(skeleton.bones[1].parent, 0);
      expect(skeleton.frameCount, 3);
      expect(skeleton.frameRate, 30);
    });

    test('packs each frame as bones * 12 floats', () {
      final skeleton = SkeletonAnimation.fromJson(_clip())!;
      expect(skeleton.positions.first, hasLength(24));
    });

    test('the position is the matrix translation', () {
      final skeleton = SkeletonAnimation.fromJson(_clip())!;
      expect(skeleton.bonePosition(2, 1).y, 3);
      expect(skeleton.bonePosition(0, 0).y, 0);
    });

    test('drops a frame whose length does not match the bone count', () {
      final json = _clip();
      (json['frames'] as List<List<double>>).add(<double>[0, 0, 0]);
      final skeleton = SkeletonAnimation.fromJson(json)!;
      expect(
        skeleton.frameCount,
        3,
        reason: 'a short frame cannot be indexed safely',
      );
    });

    test('no skeleton object means no skeleton', () {
      expect(SkeletonAnimation.fromJson(null), isNull);
    });

    test('bones with no frames is not a skeleton either', () {
      final json = _clip();
      json['frames'] = <dynamic>[];
      expect(SkeletonAnimation.fromJson(json), isNull);
    });

    test('frames with no bones is not a skeleton either', () {
      final json = _clip();
      json['bones'] = <dynamic>[];
      expect(SkeletonAnimation.fromJson(json), isNull);
    });
  });

  group('indexOfBone', () {
    test('finds a bone by name, which is how a clip meets a character', () {
      final skeleton = SkeletonAnimation.fromJson(_clip())!;
      expect(skeleton.indexOfBone('Hips'), 1);
      expect(skeleton.indexOfBone('NotInThisRig'), -1);
    });
  });

  group('frameAt', () {
    test('maps seconds onto frames at the clip rate', () {
      final skeleton = SkeletonAnimation.fromJson(_clip())!;
      expect(skeleton.frameAt(0), 0);
      expect(skeleton.frameAt(1 / 30), 1);
      expect(skeleton.frameAt(2 / 30), 2);
    });

    test('clamps past the end rather than throwing', () {
      final skeleton = SkeletonAnimation.fromJson(_clip())!;
      expect(skeleton.frameAt(100), 2);
      expect(skeleton.frameAt(-5), 0);
    });
  });

  group('bounds', () {
    test('covers every frame, not just the first', () {
      final skeleton = SkeletonAnimation.fromJson(_clip())!;
      final bounds = skeleton.bounds;
      expect(
        bounds.maxY,
        3,
        reason: 'sizing on one frame makes the figure breathe as it plays',
      );
      expect(bounds.minY, 0);
    });
  });

  group('the clip preview', () {
    testWidgets('plays the rig when the file carries one', (tester) async {
      final mesh = MeshModel(
        name: 'A_Idle.fbx',
        vertices: const [],
        faces: const [],
        kind: FbxContentKind.animation,
        animationStacks: 1,
        boneCount: 2,
        durationSeconds: 0.1,
        animationNames: const ['A_Idle'],
        skeleton: SkeletonAnimation.fromJson(_clip()),
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: AnimationClipPreview(mesh: mesh))),
      );
      expect(find.byType(SkeletonPlayer), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
    });

    testWidgets('falls back to the counts when there is no rig', (
      tester,
    ) async {
      final mesh = MeshModel(
        name: 'A_Idle.fbx',
        vertices: const [],
        faces: const [],
        kind: FbxContentKind.animation,
        animationStacks: 1,
        boneCount: 52,
        durationSeconds: 1.5,
        animationNames: const ['A_Idle'],
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: AnimationClipPreview(mesh: mesh))),
      );
      expect(find.byType(SkeletonPlayer), findsNothing);
      expect(find.text('Animation clip'), findsOneWidget);
    });
  });
}
