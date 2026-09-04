import 'dart:typed_data';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// Column-major 3x4: three basis columns then the translation.
Float32List _matrix({
  double sx = 1,
  double sy = 1,
  double sz = 1,
  double tx = 0,
  double ty = 0,
  double tz = 0,
}) => Float32List.fromList([sx, 0, 0, 0, sy, 0, 0, 0, sz, tx, ty, tz]);

/// One bone, one vertex bound to it with full weight.
MeshModel _oneBoneCharacter({Float32List? bindInverse}) => MeshModel(
  name: 'stick',
  vertices: const [Vec3(0, 0, 0), Vec3(1, 2, 3)],
  faces: [
    MeshFace([0, 1, 0], 0, const []),
  ],
  skin: SkinBinding(
    boneNames: const ['Hips'],
    bindInverse: bindInverse ?? _matrix(),
    // Two vertices, each fully weighted to bone 0.
    influences: Float32List.fromList([
      0, 1, 0, 0, 0, 0, 0, 0, //
      0, 1, 0, 0, 0, 0, 0, 0,
    ]),
    vertexSkin: Int32List.fromList([0, 1]),
  ),
);

SkeletonAnimation _clip(List<Float32List> frames, {String bone = 'Hips'}) =>
    SkeletonAnimation.fromJson({
      'bones': [
        {'name': bone, 'parent': -1},
      ],
      'stride': 12,
      'frameRate': 30.0,
      'frames': [for (final frame in frames) frame.toList()],
    })!;

void main() {
  group('matrix maths', () {
    test('identity leaves a point alone', () {
      final point = transformByMatrix(_matrix(), 0, const Vec3(1, 2, 3));
      expect(point.x, 1);
      expect(point.y, 2);
      expect(point.z, 3);
    });

    test('the fourth column translates', () {
      final point = transformByMatrix(
        _matrix(ty: 5),
        0,
        const Vec3(1, 2, 3),
      );
      expect(point.y, 7);
    });

    test('multiplying composes in the right order', () {
      // Scale by 2, then translate by 10: the translation must not be scaled.
      final out = Float32List(12);
      multiplyMatrices(_matrix(tx: 10), 0, _matrix(sx: 2), 0, out, 0);
      final point = transformByMatrix(out, 0, const Vec3(3, 0, 0));
      expect(point.x, 16);
    });

    test('multiplying by identity gives back the original', () {
      final out = Float32List(12);
      final original = _matrix(sx: 2, sy: 3, tx: 4, ty: 5);
      multiplyMatrices(_matrix(), 0, original, 0, out, 0);
      expect(out, original);
    });
  });

  group('poseSkinnedVertices', () {
    test('a bone that moves carries its vertices', () {
      final posed = poseSkinnedVertices(
        character: _oneBoneCharacter(),
        clip: _clip([_matrix(ty: 10)]),
        frame: 0,
      );
      expect(posed[0].y, 10);
      expect(posed[1].y, 12);
    });

    test('the bind inverse is applied before the clip', () {
      // Bind inverse lifts the mesh by 1; the clip then lifts by 10.
      final posed = poseSkinnedVertices(
        character: _oneBoneCharacter(bindInverse: _matrix(ty: 1)),
        clip: _clip([_matrix(ty: 10)]),
        frame: 0,
      );
      expect(posed[0].y, 11);
    });

    test('a clip with the bone at rest reproduces the bind pose', () {
      final character = _oneBoneCharacter();
      final posed = poseSkinnedVertices(
        character: character,
        clip: _clip([_matrix()]),
        frame: 0,
      );
      expect(posed[0].y, character.vertices[0].y);
      expect(posed[1].y, character.vertices[1].y);
    });

    test('a bone the clip does not have leaves the vertex where it was', () {
      final character = _oneBoneCharacter();
      final posed = poseSkinnedVertices(
        character: character,
        clip: _clip([_matrix(ty: 10)], bone: 'SomeOtherRig'),
        frame: 0,
      );
      expect(
        posed[1].y,
        character.vertices[1].y,
        reason: 'collapsing to the origin would tear the mesh apart',
      );
    });

    test('an unskinned mesh comes back untouched', () {
      final character = MeshModel(
        name: 'prop',
        vertices: const [Vec3(1, 2, 3)],
        faces: const [],
      );
      final posed = poseSkinnedVertices(
        character: character,
        clip: _clip([_matrix(ty: 10)]),
        frame: 0,
      );
      expect(posed, character.vertices);
    });

    test('a frame outside the clip is refused, not clamped silently', () {
      final character = _oneBoneCharacter();
      expect(
        poseSkinnedVertices(
          character: character,
          clip: _clip([_matrix(ty: 10)]),
          frame: 7,
        ),
        character.vertices,
      );
    });

    test('weights blend between two bones', () {
      final character = MeshModel(
        name: 'blend',
        vertices: const [Vec3(0, 0, 0)],
        faces: const [],
        skin: SkinBinding(
          boneNames: const ['A', 'B'],
          bindInverse: Float32List.fromList([
            ..._matrix(), //
            ..._matrix(),
          ]),
          influences: Float32List.fromList([0, 0.5, 1, 0.5, 0, 0, 0, 0]),
          vertexSkin: Int32List.fromList([0]),
        ),
      );
      final clip = SkeletonAnimation.fromJson({
        'bones': [
          {'name': 'A', 'parent': -1},
          {'name': 'B', 'parent': -1},
        ],
        'stride': 12,
        'frameRate': 30.0,
        'frames': [
          [..._matrix(ty: 0), ..._matrix(ty: 10)],
        ],
      })!;

      final posed = poseSkinnedVertices(
        character: character,
        clip: clip,
        frame: 0,
      );
      expect(posed.single.y, 5, reason: 'half of each bone');
    });
  });

  group('SkinBinding.fromJson', () {
    test('rejects a bone whose matrix is not 3x4', () {
      expect(
        SkinBinding.fromJson({
          'bones': [
            {
              'name': 'Hips',
              'bindInverse': [1, 0, 0],
            },
          ],
          'vertices': [0, 1, 0, 0, 0, 0, 0, 0],
          'vertexSkin': [0],
        }),
        isNull,
      );
    });

    test('no skin object means no skin', () {
      expect(SkinBinding.fromJson(null), isNull);
    });

    test('bones with no vertices is not a binding', () {
      expect(
        SkinBinding.fromJson({
          'bones': [
            {'name': 'Hips', 'bindInverse': List.filled(12, 0)},
          ],
          'vertices': <dynamic>[],
          'vertexSkin': <dynamic>[],
        }),
        isNull,
      );
    });
  });
  group('poseSkinnedPositions', () {
    test('writes the same answer as the list form', () {
      final character = _oneBoneCharacter();
      final clip = _clip([_matrix(ty: 10)]);
      final expected = poseSkinnedVertices(
        character: character,
        clip: clip,
        frame: 0,
      );
      final out = Float32List(character.vertices.length * 3);
      poseSkinnedPositions(
        character: character,
        clip: clip,
        frame: 0,
        out: out,
      );
      for (var i = 0; i < expected.length; i += 1) {
        expect(out[i * 3], closeTo(expected[i].x, 1e-5));
        expect(out[i * 3 + 1], closeTo(expected[i].y, 1e-5));
        expect(out[i * 3 + 2], closeTo(expected[i].z, 1e-5));
      }
    });

    test('a reused buffer is fully overwritten, not blended', () {
      final character = _oneBoneCharacter();
      final out = Float32List(character.vertices.length * 3);
      poseSkinnedPositions(
        character: character,
        clip: _clip([_matrix(ty: 10)]),
        frame: 0,
        out: out,
      );
      poseSkinnedPositions(
        character: character,
        clip: _clip([_matrix(ty: 0)]),
        frame: 0,
        out: out,
      );
      expect(out[1], character.vertices[0].y);
    });

    test('an unskinned mesh fills the buffer with the bind pose', () {
      final character = MeshModel(
        name: 'prop',
        vertices: const [Vec3(1, 2, 3)],
        faces: const [],
      );
      final out = Float32List(3);
      poseSkinnedPositions(
        character: character,
        clip: _clip([_matrix(ty: 10)]),
        frame: 0,
        out: out,
      );
      expect(out, Float32List.fromList([1, 2, 3]));
    });
  });

  group('bone paths', () {
    test('a path beats a name when names repeat', () {
      final clip = SkeletonAnimation.fromJson({
        'bones': [
          {'name': 'Finger_03', 'parent': -1, 'path': 'Hand_R/Finger_03'},
          {'name': 'Finger_03', 'parent': -1, 'path': 'Hand_L/Finger_03'},
        ],
        'stride': 12,
        'frameRate': 30.0,
        'frames': [
          [..._matrix(ty: 1), ..._matrix(ty: 2)],
        ],
      })!;
      expect(clip.indexOfBone('Finger_03', path: 'Hand_L/Finger_03'), 1);
      expect(clip.indexOfBone('Finger_03', path: 'Hand_R/Finger_03'), 0);
    });

    test('an unknown path falls back to the name', () {
      final clip = SkeletonAnimation.fromJson({
        'bones': [
          {'name': 'Hips', 'parent': -1, 'path': 'Root/Hips'},
        ],
        'stride': 12,
        'frameRate': 30.0,
        'frames': [_matrix().toList()],
      })!;
      expect(clip.indexOfBone('Hips', path: 'Somewhere/Else'), 0);
    });
  });
}
