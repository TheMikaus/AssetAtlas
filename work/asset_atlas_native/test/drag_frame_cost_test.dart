@Tags(['benchmark'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:asset_atlas_native/main.dart';

/// What one dragged frame costs, and where it is paid.
///
/// The load-path benchmarks next door ([render_stage_timing_test] and
/// [render_breakdown_test]) time `loadMesh` plus one isolate render, which is
/// what the tagging pass and the bridge do. Neither measures the viewer's
/// drag: a repeated render of a scene that is already flattened and already
/// in memory, at the half resolution the viewer uses while the camera moves.
///
/// That is the number that decides whether the drag can be real time, because
/// while the camera moves the viewer calls [rasterizeScene] straight on the UI
/// thread -- no isolate -- so the cost below is time the window cannot paint,
/// cannot lay out, and cannot read the mouse.
///
/// Prints a table; asserts only that something rendered. Run with:
///   `ATLAS_BENCH_PATHS=<file of asset paths>` flutter test
///     test/drag_frame_cost_test.dart
void main() {
  final listing = Platform.environment['ATLAS_BENCH_PATHS'];

  // A viewer panel in a maximised window, and the half-scale frame the
  // rasteriser is actually asked for while the camera moves.
  const fullWidth = 900;
  const fullHeight = 700;
  const movingWidth = fullWidth ~/ 2;
  const movingHeight = fullHeight ~/ 2;
  // The rasteriser is a long numeric loop, and `flutter test` runs the VM in
  // JIT: the first renders of a session are compiled while they run. Measured
  // without a warm-up, the same code reported 75 ms for a 24-face road tile
  // and 7 ms for a 22-face one later in the list -- a decay curve in list
  // order, not a property of the models. So warm up, then measure.
  const warmupFrames = 4;
  const frames = 10;

  test(
    'what one dragged frame costs',
    () async {
      final paths = File(listing!)
          .readAsLinesSync()
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();

      AssetItem itemFor(String path) => AssetItem(
        id: path,
        name: path.split(RegExp(r'[\\/]')).last,
        path: path,
        relativePath: path.split(RegExp(r'[\\/]')).last,
        sourceRoot: parentPath(path),
        sourceName: 'bench',
        ext: extensionOf(path),
        type: 'model',
        size: File(path).existsSync() ? File(path).lengthSync() : 0,
        modified: DateTime.now(),
        tags: const [],
      );

      RasterRequest requestFor(
        RasterScene scene,
        double yaw,
        int width,
        int height,
      ) => RasterRequest(
        scene: scene,
        yaw: yaw,
        pitch: 0.35,
        zoom: 1.0,
        width: width,
        height: height,
        renderMode: RenderMode.textured,
        lightingMode: LightingMode.corner,
        cullBackFaces: true,
      );

      /// Milliseconds per frame over [frames] renders, the camera moved each
      /// time so nothing upstream can answer from a cache.
      double perFrameMs(RasterScene scene, int width, int height) {
        for (var frame = 0; frame < warmupFrames; frame += 1) {
          rasterizeScene(requestFor(scene, 0.2 + frame * 0.05, width, height));
        }
        final clock = Stopwatch()..start();
        for (var frame = 0; frame < frames; frame += 1) {
          rasterizeScene(
            requestFor(scene, 0.6 + frame * 0.05, width, height),
          );
        }
        clock.stop();
        return clock.elapsedMicroseconds / frames / 1000.0;
      }

      /// The same frames through [RenderWorker]: the raster happens elsewhere,
      /// so this is the round trip -- message out, frame drawn, pixels copied
      /// back -- and the difference from [perFrameMs] is what the worker costs
      /// over drawing here. What it buys is that none of it is spent on this
      /// isolate.
      Future<double> perWorkerFrameMs(
        RasterScene scene,
        String sceneKey,
        int width,
        int height,
      ) async {
        final worker = RenderWorker.shared;
        for (var frame = 0; frame < warmupFrames; frame += 1) {
          await worker.render(
            requestFor(scene, 0.2 + frame * 0.05, width, height),
            sceneKey: sceneKey,
          );
        }
        final clock = Stopwatch()..start();
        for (var frame = 0; frame < frames; frame += 1) {
          await worker.render(
            requestFor(scene, 0.6 + frame * 0.05, width, height),
            sceneKey: sceneKey,
          );
        }
        clock.stop();
        return clock.elapsedMicroseconds / frames / 1000.0;
      }

      stdout.writeln('');
      stdout.writeln(
        '   faces  flatten   moving    fps   worker    fps   settled  name',
      );

      var counted = 0;
      for (final path in paths) {
        try {
          final mesh = await loadMesh(itemFor(path));
          if (mesh.faces.isEmpty) continue;

          // Flattening is per mesh, not per frame: the viewer caches it in
          // _RasterModelViewState._scene. Timed anyway, to show it is not
          // where the drag goes.
          final flattenClock = Stopwatch()..start();
          final scene = RasterScene.fromMesh(mesh);
          flattenClock.stop();

          final moving = perFrameMs(scene, movingWidth, movingHeight);
          final worker = await perWorkerFrameMs(
            scene,
            path,
            movingWidth,
            movingHeight,
          );
          final settled = perFrameMs(scene, fullWidth, fullHeight);
          counted += 1;

          stdout.writeln(
            '${scene.totalTriangles.toString().padLeft(8)}'
            '${(flattenClock.elapsedMicroseconds / 1000).toStringAsFixed(0).padLeft(9)}'
            '${moving.toStringAsFixed(1).padLeft(9)}'
            '${(1000 / moving).toStringAsFixed(0).padLeft(7)}'
            '${worker.toStringAsFixed(1).padLeft(9)}'
            '${(1000 / worker).toStringAsFixed(0).padLeft(7)}'
            '${settled.toStringAsFixed(1).padLeft(10)}'
            '  ${itemFor(path).name}',
          );
        } catch (error) {
          stdout.writeln('    ----     ----     ----   ----      ----  '
              '${itemFor(path).name}: $error');
        }
      }

      expect(counted, greaterThan(0), reason: 'nothing rendered');

      // The floor: two triangles at the same resolution. Whatever this costs
      // is paid by every frame whatever the model is -- clearing the colour
      // buffer, filling the depth buffer, allocating both -- so it says how
      // much of the figures above is geometry and how much is just the frame.
      final floor = RasterScene.fromMesh(
        parseObjMesh(
          'v -1 -1 0\nv 1 -1 0\nv 1 1 0\nv -1 1 0\nf 1 2 3\nf 1 3 4\n',
          'floor',
        ),
      );
      stdout.writeln('');
      stdout.writeln(
        '2 triangles, same size: moving '
        '${perFrameMs(floor, movingWidth, movingHeight).toStringAsFixed(1)} ms, '
        'settled '
        '${perFrameMs(floor, fullWidth, fullHeight).toStringAsFixed(1)} ms '
        '-- the cost no model can avoid.',
      );
      // What the round trip costs when there is nothing to draw and nothing
      // to copy back, against the same trip carrying a frame's worth of
      // pixels: the first is the message and the two event-loop turns, the
      // difference is the pixels.
      stdout.writeln(
        '2 triangles through the worker: at 1x1 '
        '${(await perWorkerFrameMs(floor, 'floor', 1, 1)).toStringAsFixed(1)} '
        'ms, at ${movingWidth}x$movingHeight '
        '${(await perWorkerFrameMs(floor, 'floor', movingWidth, movingHeight)).toStringAsFixed(1)}'
        ' ms.',
      );
      stdout.writeln('');
      stdout.writeln(
        'moving = ${movingWidth}x$movingHeight drawn on this isolate, which '
        'is what the drag used to pay and could not overlap with anything; '
        'worker = the same frame through RenderWorker, round trip, with this '
        'isolate free throughout; settled = ${fullWidth}x$fullHeight.',
      );
      RenderWorker.shared.dispose();
    },
    skip: listing == null
        ? 'set ATLAS_BENCH_PATHS to a file of asset paths to run this'
        : null,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
