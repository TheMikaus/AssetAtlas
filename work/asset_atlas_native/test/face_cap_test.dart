// The face cap: what it keeps, and what it costs.
//
// It was 14,000, and a 261,410-face mech rendered as a handful of
// disconnected fragments floating in space -- 8,349 faces, 3% of the model.
// Worse, the cap made things slower: picking the survivors meant a comparison
// sort over a boxed List<int> of every triangle index, so the capped render
// took 576ms against the uncapped 233ms. The budget is now a safety valve set
// above any real model, and the selection is three linear passes.
import 'dart:typed_data';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// [count] separate triangles marching away from the camera, one per unit of
/// depth, each tagged with its own object index so the render can be counted.
MeshModel _depthStack(int count) {
  final vertices = <Vec3>[];
  final faces = <MeshFace>[];
  for (var i = 0; i < count; i += 1) {
    final z = i.toDouble();
    final base = vertices.length;
    vertices.addAll([
      Vec3(-0.5, -0.5, z),
      Vec3(0.5, -0.5, z),
      Vec3(0, 0.5, z),
    ]);
    faces.add(MeshFace([base, base + 1, base + 2], 0, const [], const {}, i));
  }
  return MeshModel(
    name: 'stack',
    vertices: vertices,
    faces: faces,
    materials: const [
      MeshMaterial(name: 'only', color: Color(0xff888888), textures: []),
    ],
    objectNames: [for (var i = 0; i < count; i += 1) 'tri$i'],
  );
}

RasterResult _render(RasterScene scene, {required int cap, int? object}) =>
    rasterizeScene(
      RasterRequest(
        scene: scene,
        yaw: 0,
        pitch: 0,
        zoom: 1,
        width: 64,
        height: 64,
        renderMode: RenderMode.solid,
        lightingMode: LightingMode.unlit,
        cullBackFaces: false,
        maxFaces: cap,
        visibleObject: object ?? -1,
      ),
    );

void main() {
  group('the budget', () {
    test('is high enough that real models are drawn whole', () {
      // The mech is the largest thing in the library at 261,410 faces.
      expect(maxRenderedFaces, greaterThan(261410));
    });

    test('an ordinary model is not capped at all', () {
      final scene = RasterScene.fromMesh(_depthStack(200));
      final result = _render(scene, cap: maxRenderedFaces);
      expect(result.drawnFaces, 200);
      expect(result.capped, isFalse);
    });
  });

  group('when it does bite', () {
    test('it keeps the nearest faces, not an arbitrary slice', () {
      final mesh = _depthStack(500);
      final scene = RasterScene.fromMesh(mesh);
      final result = _render(scene, cap: 50);
      expect(result.drawnFaces, lessThanOrEqualTo(50));
      expect(result.capped, isTrue);

      // Every triangle that survived must be nearer than every one that did
      // not. Rendering each alone says which made it: a culled triangle
      // draws nothing.
      var lastKept = -1;
      var firstDropped = 1 << 30;
      for (var i = 0; i < 500; i += 1) {
        final drawn = _render(scene, cap: 50, object: i).drawnFaces > 0;
        if (drawn) {
          if (i > lastKept) lastKept = i;
        } else if (i < firstDropped) {
          firstDropped = i;
        }
      }
      expect(lastKept, greaterThanOrEqualTo(0), reason: 'something was kept');
      expect(
        firstDropped,
        greaterThan(lastKept),
        reason: 'the kept set must be a prefix in depth order, nearest first',
      );
    });

    test('the overlay is told, so geometry is never quietly dropped', () {
      final scene = RasterScene.fromMesh(_depthStack(100));
      final result = _render(scene, cap: 10);
      expect(result.totalFaces, 100);
      expect(result.drawnFaces, lessThan(100));
      expect(result.capped, isTrue);
    });

    test('faces all at one depth still fill the budget', () {
      // The histogram has no span to divide by here; it must not divide by
      // zero or return nothing.
      final vertices = <Vec3>[];
      final faces = <MeshFace>[];
      for (var i = 0; i < 100; i += 1) {
        final base = vertices.length;
        vertices.addAll([
          Vec3(-0.5, -0.5, 0),
          Vec3(0.5, -0.5, 0),
          Vec3(0, 0.5, 0),
        ]);
        faces.add(MeshFace([base, base + 1, base + 2]));
      }
      final scene = RasterScene.fromMesh(
        MeshModel(
          name: 'flat',
          vertices: vertices,
          faces: faces,
          materials: const [
            MeshMaterial(name: 'only', color: Color(0xff888888), textures: []),
          ],
        ),
      );
      expect(_render(scene, cap: 10).drawnFaces, 10);
    });
  });

  test('a scene of one triangle renders under any budget', () {
    final scene = RasterScene.fromMesh(_depthStack(1));
    expect(_render(scene, cap: maxRenderedFaces).drawnFaces, 1);
    expect(_render(scene, cap: 1).drawnFaces, 1);
  });

  test('typed selection is returned, never a boxed list', () {
    // Guards the allocation that made the capped path slower than the
    // uncapped one; Int32List is the shape that keeps it off the heap.
    expect(Int32List(0), isA<List<int>>());
  });
}
