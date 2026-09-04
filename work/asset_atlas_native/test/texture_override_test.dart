import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _texturePath = 'test/fixtures/fbx/normal_map.png';

MeshModel _quad({List<MeshMaterial> materials = const []}) => MeshModel(
  name: 'quad',
  vertices: const [Vec3(-1, -1, 0), Vec3(1, -1, 0), Vec3(1, 1, 0)],
  faces: [
    MeshFace([0, 1, 2], 0, const [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1)]),
  ],
  materials: materials,
  textureFiles: const ['barn.mtl'],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('withMaterials', () {
    test('swaps the materials and keeps everything else', () {
      final mesh = _quad(
        materials: const [
          MeshMaterial(name: 'old', color: Color(0xff112233), textures: []),
        ],
      );
      final replaced = mesh.withMaterials(const [
        MeshMaterial(name: 'new', color: Color(0xff445566), textures: []),
      ]);

      expect(replaced.materials.single.name, 'new');
      expect(replaced.vertices, same(mesh.vertices));
      expect(replaced.faces, same(mesh.faces));
      expect(replaced.textureFiles, mesh.textureFiles);
    });
  });

  group('applyChosenTexture', () {
    test('textures a model whose materials named nothing', () async {
      final mesh = _quad(
        materials: const [
          MeshMaterial(name: '', color: Color(0xffb9c2cc), textures: []),
        ],
      );
      expect(mesh.materials.single.texturePixels, isNull);

      final textured = await applyChosenTexture(mesh, _texturePath);
      final material = textured.materials.single;

      expect(material.texturePixels, isNotNull);
      expect(material.textureWidth, greaterThan(0));
      expect(material.textureHeight, greaterThan(0));
      expect(material.resolvedTextures, [_texturePath]);
    });

    test('gives a mesh with no materials one to hold the texture', () async {
      final textured = await applyChosenTexture(_quad(), _texturePath);
      expect(textured.materials, hasLength(1));
      expect(textured.materials.single.texturePixels, isNotNull);
    });

    test('applies to every material, not just the first', () async {
      final mesh = MeshModel(
        name: 'two',
        vertices: const [Vec3(-1, -1, 0), Vec3(1, -1, 0), Vec3(1, 1, 0)],
        faces: [
          MeshFace([0, 1, 2], 0, const []),
          MeshFace([0, 1, 2], 1, const []),
        ],
        materials: const [
          MeshMaterial(name: 'a', color: Color(0xff111111), textures: []),
          MeshMaterial(name: 'b', color: Color(0xff222222), textures: []),
        ],
      );
      final textured = await applyChosenTexture(mesh, _texturePath);
      expect(
        textured.materials.every((material) => material.texturePixels != null),
        isTrue,
      );
    });

    test('keeps the geometry and the other channels', () async {
      final mesh = _quad(
        materials: const [
          MeshMaterial(
            name: 'm',
            color: Color(0xff445566),
            textures: ['wanted.png'],
            emissiveFactor: 1.5,
            specularFactor: 0.8,
            roughness: 0.25,
            opacity: 0.5,
          ),
        ],
      );
      final textured = await applyChosenTexture(mesh, _texturePath);
      final material = textured.materials.single;

      expect(textured.faces, same(mesh.faces));
      expect(material.emissiveFactor, 1.5);
      expect(material.specularFactor, 0.8);
      expect(material.roughness, 0.25);
      expect(material.opacity, 0.5);
      expect(
        material.textures,
        ['wanted.png'],
        reason: 'what the file asked for is still worth reporting',
      );
    });

    test('a path that does not exist leaves the mesh alone', () async {
      final mesh = _quad(
        materials: const [
          MeshMaterial(name: 'm', color: Color(0xff445566), textures: []),
        ],
      );
      final result = await applyChosenTexture(mesh, 'no/such/file.png');
      expect(result.materials.single.texturePixels, isNull);
    });
  });
}
