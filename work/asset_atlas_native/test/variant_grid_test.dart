import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two quads at the same depth, one per material: the shape of a file that
/// stacks its variants.
MeshModel _stacked() => MeshModel(
  name: 'stacked',
  vertices: const [
    Vec3(-1, -1, 0),
    Vec3(1, -1, 0),
    Vec3(1, 1, 0),
    Vec3(-1, 1, 0),
  ],
  faces: [
    MeshFace([0, 1, 2], 0, const []),
    MeshFace([0, 2, 3], 0, const []),
    MeshFace([0, 1, 2], 1, const []),
    MeshFace([0, 2, 3], 1, const []),
  ],
  materials: const [
    MeshMaterial(name: 'red', color: Color(0xffdd2222), textures: []),
    MeshMaterial(name: 'blue', color: Color(0xff2244dd), textures: []),
  ],
);

({int r, int g, int b}) _centre(RasterResult raster) {
  final i = ((raster.height ~/ 2) * raster.width + raster.width ~/ 2) * 4;
  return (
    r: raster.pixels[i],
    g: raster.pixels[i + 1],
    b: raster.pixels[i + 2],
  );
}

RasterResult _render({int material = -1}) => rasterizeMesh(
  mesh: _stacked(),
  yaw: 0,
  pitch: 0,
  zoom: 1,
  width: 80,
  height: 80,
  renderMode: RenderMode.solid,
  lightingMode: LightingMode.unlit,
  cullBackFaces: false,
  visibleMaterial: material,
);

void main() {
  group('visibleMaterial', () {
    test('picks out one variant of coincident geometry', () {
      final red = _centre(_render(material: 0));
      final blue = _centre(_render(material: 1));
      expect(red.r, greaterThan(red.b));
      expect(blue.b, greaterThan(blue.r));
    });

    test('drawn together the result is one of them, not a blend', () {
      // Equal depth means whichever survives is arbitrary -- which is exactly
      // why the grid exists.
      final both = _centre(_render());
      expect(
        both.r > both.b || both.b > both.r,
        isTrue,
        reason: 'not a blend of the two',
      );
    });

    test('only the chosen material is counted as drawn', () {
      expect(_render(material: 0).drawnFaces, 2);
      expect(_render().drawnFaces, 4);
    });

    test('a material index nothing uses draws nothing', () {
      final none = _render(material: 7);
      expect(none.drawnFaces, 0);
      // Background, untouched.
      expect(_centre(none).r, 0xe9);
    });

    test('negative means every material', () {
      expect(_render(material: -1).drawnFaces, 4);
    });
  });

  group('the grid widget', () {
    testWidgets('shows one cell per material', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MaterialVariantGrid(
              mesh: _stacked(),
              yaw: 0,
              pitch: 0,
              zoom: 1,
              renderMode: RenderMode.solid,
              lightingMode: LightingMode.unlit,
              cullBackFaces: false,
              interacting: true,
            ),
          ),
        ),
      );
      expect(find.text('red'), findsOneWidget);
      expect(find.text('blue'), findsOneWidget);
    });

    testWidgets('says so when there is nothing to compare', (tester) async {
      final single = MeshModel(
        name: 'one',
        vertices: const [Vec3(0, 0, 0)],
        faces: const [],
        materials: const [
          MeshMaterial(name: 'only', color: Color(0xff888888), textures: []),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MaterialVariantGrid(
              mesh: single,
              yaw: 0,
              pitch: 0,
              zoom: 1,
              renderMode: RenderMode.solid,
              lightingMode: LightingMode.unlit,
              cullBackFaces: false,
              interacting: true,
            ),
          ),
        ),
      );
      expect(find.textContaining('one material'), findsOneWidget);
    });
  });
}
