import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
