import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// A model load that does not depend on the window being idle.
///
/// What this protects, measured on the running app: a 705 KB FBX prints
/// 5.3 MB of JSON and imports in 0.31 s when something reads its stdout.
/// The drain used to run on the UI isolate, so the child could only hand
/// over about 64 KB -- one Windows pipe buffer -- per turn of the event
/// loop. With the window busy for seconds at a time, that one import was
/// still unfinished after 12 minutes, the child sitting at 0.25 s of CPU
/// with nothing to do but wait for a reader.
///
/// Corpus-gated: it needs a model big enough to fill the pipe several times
/// over, which no fixture in this repository is.
void main() {
  final importer = File(
    'build/windows/x64/runner/Release/asset_atlas_mesh_importer.exe',
  );
  // 705 KB, and the file the stall was reported on.
  final corpus = File(
    r'Z:\Assets\Future Slums\Future Slums Unity\AbondonedDistrictUnity'
    r'\Library\PackageCache\com.unity.cinemachine@2.6.11\Samples~'
    r'\Cinemachine Example Scenes\Shared\Models\UnityCharacter\Models'
    r'\DefaultMale.fbx',
  );

  test('the import finishes while the caller keeps blocking', () async {
    if (!importer.existsSync()) {
      markTestSkipped('Build the Windows app first.');
      return;
    }
    if (!corpus.existsSync()) {
      markTestSkipped('Needs the asset library on Z:.');
      return;
    }

    var finished = false;
    final pending = runMeshImporterOffThread(
      importer.absolute.path,
      corpus.path,
    ).then((value) {
      finished = true;
      return value;
    });

    // A window under load does not block once; it blocks for a long frame,
    // turns the event loop, and blocks again. Each turn moved the import on
    // by one pipe buffer, which is why 5.3 MB of JSON took minutes: the
    // child refills 64 KB and waits for the next turn. Draining on a worker
    // makes the number of turns irrelevant.
    var slices = 0;
    while (!finished && slices < 60) {
      slices += 1;
      final frame = Stopwatch()..start();
      while (frame.elapsedMilliseconds < 200) {
        // A frame's worth of synchronous work, with no await in it.
      }
      await Future<void>.delayed(Duration.zero);
    }

    final result = await pending;
    expect(result.exitCode, 0);
    expect(result.stdout.length, greaterThan(1000000));
    expect(
      slices,
      lessThan(10),
      reason: 'the import needed $slices turns of a blocked event loop for '
          '${result.stdout.length} bytes; it should need none',
    );
  });

  test('its output is the same as the caller-side drain', () async {
    if (!importer.existsSync() || !corpus.existsSync()) {
      markTestSkipped('Needs the built app and the asset library on Z:.');
      return;
    }
    // Chunk-at-a-time collection replaced a byte-at-a-time one. The bytes
    // must be identical, or every model in the library quietly changes shape.
    final offThread = await runMeshImporterOffThread(
      importer.absolute.path,
      corpus.path,
    );
    final inline = await runMeshImporter(importer.absolute.path, corpus.path);
    expect(offThread.exitCode, inline.exitCode);
    expect(offThread.stdout.length, inline.stdout.length);
    expect(offThread.stdout, inline.stdout);
  });
}
