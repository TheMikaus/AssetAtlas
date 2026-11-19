// Taking a character sheet apart along its nodes, and not painting the
// unpainted black.
//
// Every "Characters.fbx" in the library is a dozen bodies standing in one
// place. Dungeon Realms gives each its own material, Battle Royale packs
// twenty-one into five, and Ancient Empire puts eleven in one -- so the
// material seam separates one sheet in three. The node seam separates all of
// them, because the nodes are the characters, by name.
import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Several full-height bodies in one place, each its own node, one material.
MeshModel _sheet(int bodies) {
  final vertices = <Vec3>[];
  final faces = <MeshFace>[];
  for (var b = 0; b < bodies; b += 1) {
    final base = vertices.length;
    vertices.addAll(const [Vec3(-1, -1, 0), Vec3(1, -1, 0), Vec3(0, 1, 0)]);
    faces.add(MeshFace([base, base + 1, base + 2], 0, const [], const {}, b));
  }
  return MeshModel(
    name: 'sheet',
    vertices: vertices,
    faces: faces,
    materials: const [
      MeshMaterial(name: 'only', color: Color(0xff888888), textures: []),
    ],
    objectNames: [for (var b = 0; b < bodies; b += 1) 'Chr_$b'],
  );
}

void main() {
  group('a sheet with one material', () {
    test('does not come apart by material', () {
      expect(materialsAreStackedVariants(_sheet(4)), isFalse);
    });

    test('comes apart by node', () {
      expect(objectsAreStackedVariants(_sheet(4)), isTrue);
    });

    test('two nodes are a model and a part, not a sheet', () {
      expect(objectsAreStackedVariants(_sheet(2)), isFalse);
    });

    test('the grid offers one cell per node, named', () {
      final cells = CellVariantGrid.byObject(_sheet(3));
      expect(cells.map((c) => c.label), ['Chr_0', 'Chr_1', 'Chr_2']);
      expect(cells.map((c) => c.object), [0, 1, 2]);
    });

    test('the rasteriser draws one node when asked', () {
      final sheet = _sheet(3);
      final scene = RasterScene.fromMesh(sheet);
      expect(scene.triangleObject, [0, 1, 2]);
      final one = rasterizeScene(
        RasterRequest(
          scene: scene,
          yaw: 0,
          pitch: 0,
          zoom: 1,
          width: 32,
          height: 32,
          renderMode: RenderMode.solid,
          lightingMode: LightingMode.unlit,
          cullBackFaces: false,
          visibleObject: 1,
        ),
      );
      final all = rasterizeScene(
        RasterRequest(
          scene: scene,
          yaw: 0,
          pitch: 0,
          zoom: 1,
          width: 32,
          height: 32,
          renderMode: RenderMode.solid,
          lightingMode: LightingMode.unlit,
          cullBackFaces: false,
        ),
      );
      expect(one.drawnFaces, 1);
      expect(all.drawnFaces, 3);
    });
  });

  group('unpainted vertices', () {
    test('an alpha-zero corner does not tint the face', () {
      final mesh = MeshModel(
        name: 'painted',
        vertices: const [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)],
        faces: const [MeshFace([0, 1, 2])],
        // Two corners painted white, one never painted: an exporter writes
        // (0,0,0,0) for that, and taken as a colour it is black.
        vertexColors: const [
          Color(0xffffffff),
          Color(0xffffffff),
          Color(0x00000000),
        ],
      );
      final tint = mesh.averageFaceVertexColor(mesh.faces.first)!;
      expect(tint.r, closeTo(1, 1e-6), reason: 'white, not two-thirds grey');
    });

    test('a face nobody painted at all is untinted', () {
      final mesh = MeshModel(
        name: 'bare',
        vertices: const [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)],
        faces: const [MeshFace([0, 1, 2])],
        vertexColors: const [
          Color(0x00000000),
          Color(0x00000000),
          Color(0x00000000),
        ],
      );
      expect(mesh.averageFaceVertexColor(mesh.faces.first), isNull);
    });
  });

  group('paging', () {
    testWidgets('nine cells fit a page and the tenth turns one', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PagedGrid(
              itemCount: 10,
              itemBuilder: (context, index) => Text('cell $index'),
            ),
          ),
        ),
      );
      expect(find.text('cell 0'), findsOneWidget);
      expect(find.text('cell 8'), findsOneWidget);
      expect(find.text('cell 9'), findsNothing);
      expect(find.text('Page 1 of 2'), findsOneWidget);
      await tester.tap(find.byTooltip('Next page'));
      await tester.pump();
      expect(find.text('cell 9'), findsOneWidget);
      expect(find.text('cell 0'), findsNothing);
    });

    testWidgets('a single page shows no page controls', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PagedGrid(
              itemCount: 4,
              itemBuilder: (context, index) => Text('cell $index'),
            ),
          ),
        ),
      );
      expect(find.textContaining('Page'), findsNothing);
    });
  });
}
