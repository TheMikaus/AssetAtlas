import 'dart:io';
import 'dart:math' as math;

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

    test('the two conventions are exact opposites', () {
      expect(isBackFacingTriangle(0, 0, 10, 0, 10, 10), isTrue);
      expect(isBackFacingTriangle(0, 0, 10, 10, 10, 0), isFalse);
    });
  });

  test('fixture faces are front facing under the default camera', () async {
    // Pins the winding convention against real ufbx output. The fixture is
    // authored to be looked at, so if these were culled the sign would be
    // inverted and closed models would render inside out.
    final helper = File(
      'build/windows/x64/runner/Release/asset_atlas_mesh_importer.exe',
    );
    if (!helper.existsSync()) {
      markTestSkipped('Build the Windows app before running native FBX tests.');
      return;
    }

    final mesh = await importFbxWithUfbx(
      File('test/fixtures/fbx/transformed_uv_embedded.fbx').absolute.path,
      'fixture',
    );

    // Same projection the painter uses, at ModelPreview's initial camera.
    const yaw = -0.6;
    const pitch = 0.35;
    final sy = math.sin(yaw);
    final cy = math.cos(yaw);
    final sx = math.sin(pitch);
    final cx = math.cos(pitch);
    final xs = <double>[];
    final ys = <double>[];
    for (final vertex in mesh.vertices) {
      final x1 = vertex.x * cy + vertex.z * sy;
      final z1 = -vertex.x * sy + vertex.z * cy;
      final y1 = vertex.y * cx - z1 * sx;
      final z2 = vertex.y * sx + z1 * cx;
      final perspective = 2.8 / (2.8 + z2);
      xs.add(200 + x1 * 100 * perspective);
      ys.add(200 - y1 * 100 * perspective);
    }

    expect(mesh.faces, isNotEmpty);
    for (final face in mesh.faces) {
      final i = face.indices;
      expect(
        isBackFacingTriangle(
          xs[i[0]],
          ys[i[0]],
          xs[i[1]],
          ys[i[1]],
          xs[i[2]],
          ys[i[2]],
        ),
        isFalse,
        reason: 'fixture geometry must survive culling at the default camera',
      );
    }
  });
}
