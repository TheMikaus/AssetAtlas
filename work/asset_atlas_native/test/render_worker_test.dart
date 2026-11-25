import 'dart:async';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rasteriser on a worker isolate that stays alive between frames.
///
/// The viewer drew moving frames by calling [rasterizeScene] straight on the
/// UI isolate, so every frame of a drag was time the window could not lay out,
/// paint, or read the mouse: 8 ms a frame for an ordinary kit model at half
/// resolution, and 36-47 ms for the 33k- and 133k-face meshes in this library.
///
/// The alternative already in the file, [rasterizeSceneInIsolate], spawns an
/// isolate per call, which is why it was only used for the settled frame. So
/// these tests are about the worker that stays: that it draws the same picture,
/// that it leaves the calling isolate free while it draws, and that it holds
/// the scene instead of being sent it again every frame.
void main() {
  /// A grid of quads, big enough that one frame of it is unmistakably longer
  /// than an event-loop turn.
  MeshModel gridMesh({required int columns, required int rows}) {
    final vertices = <Vec3>[];
    final faces = <MeshFace>[];
    for (var row = 0; row < rows; row += 1) {
      for (var column = 0; column < columns; column += 1) {
        final x = (column / columns) * 2 - 1;
        final y = (row / rows) * 2 - 1;
        final step = 2.0 / columns;
        final base = vertices.length;
        vertices.addAll([
          Vec3(x, y, 0),
          Vec3(x + step, y, 0.1),
          Vec3(x + step, y + step, 0),
          Vec3(x, y + step, -0.1),
        ]);
        faces.add(MeshFace([base, base + 1, base + 2], 0, const []));
        faces.add(MeshFace([base, base + 2, base + 3], 0, const []));
      }
    }
    return MeshModel(
      name: 'grid${columns}x$rows',
      vertices: vertices,
      faces: faces,
      materials: const [
        MeshMaterial(name: 'surface', color: Color(0xffcc5533), textures: []),
      ],
    );
  }

  RasterRequest requestFor(
    RasterScene scene, {
    double yaw = 0.6,
    int width = 450,
    int height = 350,
  }) => RasterRequest(
    scene: scene,
    yaw: yaw,
    pitch: 0.35,
    zoom: 1.0,
    width: width,
    height: height,
    renderMode: RenderMode.solid,
    lightingMode: LightingMode.corner,
    cullBackFaces: false,
  );

  tearDown(() {
    // The isolate outlives the test otherwise, and the suite never finishes.
    RenderWorker.shared.dispose();
  });

  test('the worker draws the same picture as drawing here does', () async {
    final scene = RasterScene.fromMesh(gridMesh(columns: 12, rows: 12));
    final request = requestFor(scene);

    final here = rasterizeScene(request);
    final there = await RenderWorker.shared.render(request, sceneKey: 'grid');

    expect(there.width, here.width);
    expect(there.height, here.height);
    expect(there.drawnFaces, here.drawnFaces);
    expect(there.totalFaces, here.totalFaces);
    expect(there.pixels, here.pixels,
        reason: 'the worker runs the same rasteriser over a copy of the same '
            'scene, so the frame must be identical byte for byte');
  });

  test('the calling isolate stays free while the frame is drawn', () async {
    // 20,000 triangles: comfortably more than one event-loop turn of work,
    // and in the range of the library meshes that made the drag unusable.
    final scene = RasterScene.fromMesh(gridMesh(columns: 100, rows: 100));
    final request = requestFor(scene, width: 600, height: 600);

    Future<int> ticksDuring(Future<void> Function() work) async {
      var ticks = 0;
      final timer = Timer.periodic(Duration.zero, (_) => ticks += 1);
      await work();
      timer.cancel();
      return ticks;
    }

    // What the viewer used to do. A synchronous call cannot be interrupted by
    // the event loop, so nothing else on this isolate runs for its whole
    // duration -- no layout, no paint, no pointer event. That is not a timing
    // assumption; it is what synchronous means.
    final whileDrawingHere = await ticksDuring(() async {
      rasterizeScene(request);
    });
    expect(whileDrawingHere, 0,
        reason: 'the old path blocked this isolate for the whole frame');

    final whileDrawingOnWorker = await ticksDuring(() async {
      await RenderWorker.shared.render(request, sceneKey: 'grid');
    });
    expect(whileDrawingOnWorker, greaterThan(0),
        reason: 'the window must be able to run between frames');
  });

  test('a drag of many frames sends the scene once', () async {
    final scene = RasterScene.fromMesh(gridMesh(columns: 20, rows: 20));
    final worker = RenderWorker.shared;

    for (var frame = 0; frame < 30; frame += 1) {
      // The camera moves every frame, so nothing upstream can answer from a
      // cache -- each of these is a frame the worker actually drew.
      final raster = await worker.render(
        requestFor(scene, yaw: 0.1 + frame * 0.03),
        sceneKey: 'grid',
      );
      expect(raster.drawnFaces, greaterThan(0));
    }

    expect(worker.sceneTransfers, 1,
        reason: 'sending the flattened scene per frame is the cost this exists '
            'to avoid: on a large mesh it is megabytes, copied, per frame');
  });

  test('two scenes are told apart, and neither is drawn for the other',
      () async {
    final wide = RasterScene.fromMesh(gridMesh(columns: 16, rows: 4));
    final tall = RasterScene.fromMesh(gridMesh(columns: 4, rows: 16));
    final worker = RenderWorker.shared;

    final wideFrame = await worker.render(requestFor(wide), sceneKey: 'wide');
    final tallFrame = await worker.render(requestFor(tall), sceneKey: 'tall');
    final wideAgain = await worker.render(requestFor(wide), sceneKey: 'wide');

    expect(wideAgain.pixels, wideFrame.pixels);
    expect(wideFrame.pixels, isNot(tallFrame.pixels),
        reason: 'a shared key would have drawn one mesh for the other');
    expect(worker.sceneTransfers, 2);
  });

  test('a scene pushed out by newer ones is sent again, not drawn wrong',
      () async {
    final worker = RenderWorker.shared;
    final first = RasterScene.fromMesh(gridMesh(columns: 16, rows: 4));
    final expected = rasterizeScene(requestFor(first));

    await worker.render(requestFor(first), sceneKey: 'first');
    // Fill every slot with something else.
    for (var index = 0; index < renderWorkerSceneSlots; index += 1) {
      final filler = RasterScene.fromMesh(
        gridMesh(columns: 5 + index, rows: 5),
      );
      await worker.render(requestFor(filler), sceneKey: 'filler$index');
    }

    final again = await worker.render(requestFor(first), sceneKey: 'first');
    expect(again.pixels, expected.pixels,
        reason: 'the worker must ask for a scene it no longer holds rather '
            'than draw whatever it has');
    expect(worker.sceneTransfers, renderWorkerSceneSlots + 2,
        reason: 'the evicted scene is sent a second time, and only then');
  });

  test('the placeholder scene draws nothing at all', () async {
    // The protocol guard: the placeholder goes over the wire in place of the
    // real scene, and the worker swaps its own copy back in. If a mistake ever
    // let the placeholder reach the rasteriser, the frame must come back empty
    // rather than wrong.
    final raster = rasterizeScene(requestFor(RasterScene.placeholder));
    expect(raster.drawnFaces, 0);
    expect(raster.totalFaces, 0);
    final background = raster.pixels.sublist(0, 4);
    for (var pixel = 0; pixel < raster.width * raster.height; pixel += 1) {
      expect(raster.pixels.sublist(pixel * 4, pixel * 4 + 4), background);
    }
  });

  testWidgets('the viewer draws a moving frame through the worker', (
    tester,
  ) async {
    // The worker tests above exercise the worker. This one exercises the path
    // that reaches it: a moving frame used to be drawn on the UI isolate by
    // this widget, and the branch that decided so lived here, not in the
    // worker.
    final mesh = gridMesh(columns: 8, rows: 8);
    final worker = RenderWorker.shared;

    // runAsync, because a widget test runs in fake async and the worker's
    // reply arrives on a real port -- awaited under fake time it never comes.
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 200,
            child: RasterModelView(
              mesh: mesh,
              yaw: 0.6,
              pitch: 0.35,
              zoom: 1.0,
              renderMode: RenderMode.solid,
              lightingMode: LightingMode.corner,
              cullBackFaces: false,
              useBaseTexture: true,
              useNormalMaps: true,
              useEmissiveMaps: true,
              useSpecular: true,
              // The state this fix is about.
              interacting: true,
            ),
          ),
        ),
      );
      // A spinner until the first frame arrives, and the frame arrives from
      // another isolate, so pumping alone will not do: give it real time.
      for (var attempt = 0; attempt < 40; attempt += 1) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        await tester.pump();
        if (find.byType(RawImage).evaluate().isNotEmpty) break;
      }
    });

    expect(find.byType(RawImage), findsOneWidget,
        reason: 'the view must end up showing a rendered frame');
    expect(worker.running, isTrue,
        reason: 'a moving frame must have gone to the worker, not been drawn '
            'on this isolate');
    expect(worker.sceneTransfers, 1);
  });

  test('a mesh names its scene once and keeps that name', () {
    final mesh = gridMesh(columns: 2, rows: 2);
    final other = gridMesh(columns: 2, rows: 2);

    expect(sceneNameFor(mesh, null), sceneNameFor(mesh, null));
    expect(sceneNameFor(mesh, null), isNot(sceneNameFor(other, null)),
        reason: 'two meshes that happen to be identical are still two scenes');
    expect(sceneNameFor(mesh, 'uv1'), isNot(sceneNameFor(mesh, null)),
        reason: 'the UV set is baked into the flattened scene, so it is part '
            'of what the worker is holding');
  });
}
