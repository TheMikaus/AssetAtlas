import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// A quad with texture coordinates, written the way an exporter writes them.
const _texturedQuad = '''
# a comment
mtllib barn.mtl
v 0 0 0
v 1 0 0
v 1 1 0
v 0 1 0
vt 0 0
vt 1 0
vt 1 1
vt 0 1
usemtl Barn_Walls
f 1/1 2/2 3/3 4/4
''';

void main() {
  group('parseObjMesh', () {
    test('keeps the texture coordinates', () {
      final mesh = parseObjMesh(_texturedQuad, 'quad');
      expect(mesh.faces, hasLength(2), reason: 'a quad fans into 2 triangles');
      for (final face in mesh.faces) {
        expect(face.uvs, hasLength(3));
      }
    });

    test('flips V, because OBJ counts up and the sampler counts down', () {
      final mesh = parseObjMesh(_texturedQuad, 'quad');
      // vt 0 0 is the bottom-left corner in OBJ, the top-left when sampling.
      expect(mesh.faces.first.uvs.first.x, 0);
      expect(mesh.faces.first.uvs.first.y, 1);
    });

    test('records the material library so the resolver can chase it', () {
      final mesh = parseObjMesh(_texturedQuad, 'quad');
      expect(mesh.textureFiles, ['barn.mtl']);
    });

    test('usemtl names the material', () {
      final mesh = parseObjMesh(_texturedQuad, 'quad');
      expect(mesh.materials, hasLength(1));
      expect(mesh.materials.single.name, 'Barn_Walls');
      expect(mesh.faces.every((face) => face.materialIndex == 0), isTrue);
    });

    test('several usemtl blocks split the faces between materials', () {
      final mesh = parseObjMesh('''
v 0 0 0
v 1 0 0
v 1 1 0
v 0 1 0
usemtl Walls
f 1 2 3
usemtl Roof
f 1 3 4
''', 'two');
      expect(mesh.materials.map((m) => m.name), ['Walls', 'Roof']);
      expect(mesh.faces.map((f) => f.materialIndex), [0, 1]);
    });

    test('a repeated usemtl reuses the material it already made', () {
      final mesh = parseObjMesh('''
v 0 0 0
v 1 0 0
v 1 1 0
v 0 1 0
usemtl Walls
f 1 2 3
usemtl Roof
f 1 3 4
usemtl Walls
f 2 3 4
''', 'repeat');
      expect(mesh.materials, hasLength(2));
      expect(mesh.faces.map((f) => f.materialIndex), [0, 1, 0]);
    });

    test('an OBJ with no materials still parses, with one of its own', () {
      final mesh = parseObjMesh('''
v 0 0 0
v 1 0 0
v 1 1 0
f 1 2 3
''', 'bare');
      expect(mesh.faces, hasLength(1));
      expect(mesh.materials, hasLength(1));
      expect(mesh.textureFiles, isEmpty);
    });

    test('v//vn corners carry no UV rather than a wrong one', () {
      final mesh = parseObjMesh('''
v 0 0 0
v 1 0 0
v 1 1 0
vt 0 0
vn 0 0 1
f 1//1 2//1 3//1
''', 'normals');
      expect(mesh.faces.single.uvs, isEmpty);
    });

    test('a polygon that is only partly textured contributes no UVs', () {
      final mesh = parseObjMesh('''
v 0 0 0
v 1 0 0
v 1 1 0
vt 0 0
vt 1 0
f 1/1 2/2 3
''', 'partial');
      expect(mesh.faces.single.uvs, isEmpty);
    });

    test('negative indices count back from the current end', () {
      final mesh = parseObjMesh('''
v 0 0 0
v 1 0 0
v 1 1 0
vt 0 0
vt 1 0
vt 1 1
f -3/-3 -2/-2 -1/-1
''', 'negative');
      expect(mesh.faces.single.indices, [0, 1, 2]);
      expect(mesh.faces.single.uvs, hasLength(3));
    });

    test('an out-of-range index is dropped, not clamped to a real vertex', () {
      final mesh = parseObjMesh('''
v 0 0 0
v 1 0 0
v 1 1 0
f 1 2 3 99
''', 'bad');
      expect(mesh.faces.single.indices, [0, 1, 2]);
    });

    test('geometry is still required', () {
      expect(
        () => parseObjMesh('# nothing here\nmtllib x.mtl\n', 'empty'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
