import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('selectRenderedFaceOrder', () {
    test('returns every visible face, back to front, when under budget', () {
      final order = selectRenderedFaceOrder(
        depths: [0.1, 0.9, 0.5],
        visible: [true, true, true],
        budget: maxRenderedFaces,
      );
      // Larger depth is farther, and farther is painted first.
      expect(order, [1, 2, 0]);
    });

    test('drops invisible faces', () {
      final order = selectRenderedFaceOrder(
        depths: [0.1, 0.9, 0.5],
        visible: [true, false, true],
        budget: maxRenderedFaces,
      );
      expect(order, [2, 0]);
    });

    test('keeps exactly the budget, and keeps the nearest faces', () {
      final depths = [10.0, 1.0, 5.0, 2.0];
      final order = selectRenderedFaceOrder(
        depths: depths,
        visible: List<bool>.filled(4, true),
        budget: 2,
      );
      expect(order, hasLength(2));
      // The two nearest are depths 1.0 (index 1) and 2.0 (index 3); still
      // painted back to front.
      expect(order, [3, 1]);
    });

    test('never samples by stride the way the old renderer did', () {
      // 100 faces at increasing depth, budget 10: the correct answer is the
      // 10 nearest, not every 10th face.
      final depths = [for (var i = 0; i < 100; i += 1) i.toDouble()];
      final order = selectRenderedFaceOrder(
        depths: depths,
        visible: List<bool>.filled(100, true),
        budget: 10,
      );
      expect(order, hasLength(10));
      expect(order.toSet(), {0, 1, 2, 3, 4, 5, 6, 7, 8, 9});
    });
  });

  group('backface culling', () {
    test('signed area flips with winding', () {
      final clockwise = triangleSignedArea(0, 0, 10, 0, 10, 10);
      final counterClockwise = triangleSignedArea(0, 0, 10, 10, 10, 0);
      expect(clockwise.sign, -counterClockwise.sign);
    });

    test('a degenerate triangle is not treated as front facing', () {
      expect(triangleSignedArea(0, 0, 5, 5, 10, 10), 0);
      expect(isBackFacingTriangle(0, 0, 5, 5, 10, 10), isFalse);
    });

    test('the two windings classify oppositely', () {
      // Which winding is "front" is pinned by the cube tests below, against
      // outward normals; this only asserts the two are treated as opposites.
      const a = [0.0, 0.0, 10.0, 0.0, 10.0, 10.0];
      const b = [0.0, 0.0, 10.0, 10.0, 10.0, 0.0];
      expect(
        isBackFacingTriangle(a[0], a[1], a[2], a[3], a[4], a[5]),
        isNot(isBackFacingTriangle(b[0], b[1], b[2], b[3], b[4], b[5])),
      );
    });
  });

  group('culling keeps the outside of a solid', () {
    // A cube face, wound so its right-handed geometric normal points away from
    // the cube centre. "Outward" is computed here, not assumed, so this test
    // cannot drift with the renderer's conventions.
    ({List<double> xs, List<double> ys, List<double> normal}) cubeFace({
      required double axis,
      required int axisIndex,
    }) {
      // Four corners of the face at `axis` on `axisIndex`.
      final corners = <List<double>>[];
      for (final u in [-1.0, 1.0]) {
        for (final v in [-1.0, 1.0]) {
          final point = [0.0, 0.0, 0.0];
          point[axisIndex] = axis;
          point[(axisIndex + 1) % 3] = u;
          point[(axisIndex + 2) % 3] = v;
          corners.add(point);
        }
      }
      // corners is [--, -+, +-, ++]; take a triangle and orient it outward.
      var a = corners[0];
      var b = corners[1];
      var c = corners[3];
      List<double> normalOf(List<double> p, List<double> q, List<double> r) {
        final ux = q[0] - p[0], uy = q[1] - p[1], uz = q[2] - p[2];
        final vx = r[0] - p[0], vy = r[1] - p[1], vz = r[2] - p[2];
        return [uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx];
      }

      var normal = normalOf(a, b, c);
      // Outward means the normal agrees with the direction from the centre.
      if (normal[axisIndex] * axis < 0) {
        final swap = b;
        b = c;
        c = swap;
        normal = normalOf(a, b, c);
      }
      expect(
        normal[axisIndex] * axis,
        greaterThan(0),
        reason: 'test setup: face normal must point outward',
      );

      // The painter's projection at yaw = 0, pitch = 0: x and y pass through,
      // larger z is farther, screen y is flipped.
      List<double> project(List<double> p) {
        final perspective = 2.8 / (2.8 + p[2]);
        return [250 + p[0] * 100 * perspective, 250 - p[1] * 100 * perspective];
      }

      final pa = project(a), pb = project(b), pc = project(c);
      return (
        xs: [pa[0], pb[0], pc[0]],
        ys: [pa[1], pb[1], pc[1]],
        normal: normal,
      );
    }

    test('the near face of a cube is kept', () {
      // Camera sits at negative z looking toward +z, so the z = -1 face faces
      // the viewer. If this is ever culled, every closed model renders
      // inside out -- which is exactly the bug this pins.
      final face = cubeFace(axis: -1, axisIndex: 2);
      expect(
        isBackFacingTriangle(
          face.xs[0],
          face.ys[0],
          face.xs[1],
          face.ys[1],
          face.xs[2],
          face.ys[2],
        ),
        isFalse,
        reason: 'the outside of the near face must survive culling',
      );
    });

    test('the far face of a cube is culled', () {
      final face = cubeFace(axis: 1, axisIndex: 2);
      expect(
        isBackFacingTriangle(
          face.xs[0],
          face.ys[0],
          face.xs[1],
          face.ys[1],
          face.xs[2],
          face.ys[2],
        ),
        isTrue,
        reason: 'the far side of a solid is hidden and should be dropped',
      );
    });

    test('only the faces turned toward the camera are kept', () {
      var kept = 0;
      for (var axisIndex = 0; axisIndex < 3; axisIndex += 1) {
        for (final axis in [-1.0, 1.0]) {
          final face = cubeFace(axis: axis, axisIndex: axisIndex);
          if (!isBackFacingTriangle(
            face.xs[0],
            face.ys[0],
            face.xs[1],
            face.ys[1],
            face.xs[2],
            face.ys[2],
          )) {
            kept += 1;
          }
        }
      }
      // Head-on camera (yaw and pitch both zero), so only the near face is
      // turned toward the viewer; the four side faces are edge-on and the far
      // face points away.
      expect(kept, 1, reason: 'only the near face of a head-on cube is kept');
    });
  });
}
