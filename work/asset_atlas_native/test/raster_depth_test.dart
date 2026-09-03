import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two quads crossing through each other. Which one is nearer changes *within*
/// each face, so no per-face ordering can draw this correctly.
MeshModel _crossingQuads() => MeshModel(
  name: 'cross',
  vertices: const [
    Vec3(-1, -0.6, -1), Vec3(1, -0.6, 1), Vec3(1, 0.6, 1),
    Vec3(-1, -0.6, -1), Vec3(1, 0.6, 1), Vec3(-1, 0.6, -1),
    Vec3(-1, -0.6, 1), Vec3(1, -0.6, -1), Vec3(1, 0.6, -1),
    Vec3(-1, -0.6, 1), Vec3(1, 0.6, -1), Vec3(-1, 0.6, 1),
  ],
  faces: [
    MeshFace([0, 1, 2], 0, const []),
    MeshFace([3, 4, 5], 0, const []),
    MeshFace([6, 7, 8], 1, const []),
    MeshFace([9, 10, 11], 1, const []),
  ],
  materials: const [
    MeshMaterial(name: 'red', color: Color(0xffdd2222), textures: []),
    MeshMaterial(name: 'blue', color: Color(0xff2244dd), textures: []),
  ],
);

({int r, int g, int b}) _pixel(RasterResult raster, int x, int y) {
  final i = (y * raster.width + x) * 4;
  return (r: raster.pixels[i], g: raster.pixels[i + 1], b: raster.pixels[i + 2]);
}

RasterResult _render(MeshModel mesh, {bool cull = false}) => rasterizeMesh(
  mesh: mesh,
  yaw: 0,
  pitch: 0,
  zoom: 1,
  width: 200,
  height: 200,
  renderMode: RenderMode.solid,
  lightingMode: LightingMode.unlit,
  cullBackFaces: cull,
);

void main() {
  group('depth buffer', () {
    test('interpenetrating faces each win where they are nearer', () {
      final raster = _render(_crossingQuads());

      // The red quad comes forward on the left, the blue one on the right.
      final left = _pixel(raster, 40, 100);
      final right = _pixel(raster, 160, 100);

      expect(left.r, greaterThan(150), reason: 'left half should be red');
      expect(left.b, lessThan(100));
      expect(right.b, greaterThan(150), reason: 'right half should be blue');
      expect(right.r, lessThan(100));
    });

    test('the crossing line is vertical, not along a triangle edge', () {
      final raster = _render(_crossingQuads());

      // Per-face sorting split these along each quad's diagonal, so the
      // boundary moved with height. With per-pixel depth it stays put.
      int boundaryAt(int y) {
        for (var x = 1; x < raster.width; x += 1) {
          final previous = _pixel(raster, x - 1, y);
          final current = _pixel(raster, x, y);
          final wasRed = previous.r > previous.b;
          final isRed = current.r > current.b;
          if (wasRed && !isRed) return x;
        }
        return -1;
      }

      final upper = boundaryAt(80);
      final lower = boundaryAt(120);
      expect(upper, greaterThan(0));
      expect(lower, greaterThan(0));
      expect(
        (upper - lower).abs(),
        lessThanOrEqualTo(2),
        reason: 'a diagonal split is the artifact this replaces',
      );
    });

    test('nothing is drawn where the mesh is not', () {
      final raster = _render(_crossingQuads());
      final corner = _pixel(raster, 2, 2);
      expect(corner.r, 0xe9);
      expect(corner.g, 0xed);
      expect(corner.b, 0xf3);
    });

    test('reports how much of the mesh it drew', () {
      final raster = _render(_crossingQuads());
      expect(raster.totalFaces, 4);
      expect(raster.drawnFaces, 4);
      expect(raster.capped, isFalse);
    });

    test('the face budget caps what is drawn', () {
      final raster = rasterizeMesh(
        mesh: _crossingQuads(),
        yaw: 0,
        pitch: 0,
        zoom: 1,
        width: 100,
        height: 100,
        renderMode: RenderMode.solid,
        lightingMode: LightingMode.unlit,
        cullBackFaces: false,
        maxFaces: 2,
      );
      expect(raster.totalFaces, 4);
      expect(raster.drawnFaces, lessThanOrEqualTo(2));
      expect(raster.capped, isTrue);
    });

    test('culling drops the faces turned away', () {
      final withCull = _render(_crossingQuads(), cull: true);
      final without = _render(_crossingQuads());
      expect(withCull.drawnFaces, lessThan(without.drawnFaces));
    });
  });
}
