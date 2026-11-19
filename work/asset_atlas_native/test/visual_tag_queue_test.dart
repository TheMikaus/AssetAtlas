import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:asset_atlas_native/visual_tagging.dart';
import 'package:asset_atlas_native/visual_tag_queue.dart';

/// A worker that answers the protocol from memory.
///
/// Worth the hundred lines: the real one starts Python and loads 325 MB of
/// ONNX, and what these tests are about is the queue's behaviour when things
/// go wrong — stopping, pausing, and who gets blamed for a failed render.
/// The store's own guarantees are tested on the Python side.
class FakeWorker implements TagWorker {
  FakeWorker(this.assets);

  /// asset_id -> name. Order is the order they come back in.
  final Map<String, String> assets;

  final Set<String> stored = {};
  final Map<String, int> failures = {};
  final List<String> ops = [];
  int handOvers = 0;
  bool closed = false;

  /// Makes `ask` yield partway through, so an overlapping call is visible.
  Duration askDelay = Duration.zero;

  /// How many asks were in flight at once. Anything above one means two
  /// requests shared one pipe and each could take the other's reply.
  int askesInFlight = 0;
  int peakAskesInFlight = 0;

  /// Set to make the next `ask` throw, as a dead child process would.
  String? dieWith;

  @override
  Future<Map<String, Object?>> ask(
    String op, [
    Map<String, Object?> extra = const {},
  ]) async {
    ops.add(op);
    askesInFlight += 1;
    peakAskesInFlight = peakAskesInFlight > askesInFlight
        ? peakAskesInFlight
        : askesInFlight;
    try {
      return await _answer(op, extra);
    } finally {
      askesInFlight -= 1;
    }
  }

  Future<Map<String, Object?>> _answer(
    String op,
    Map<String, Object?> extra,
  ) async {
    if (askDelay > Duration.zero) await Future<void>.delayed(askDelay);
    final dying = dieWith;
    if (dying != null && op != 'next') {
      throw TagWorkerException(dying);
    }
    switch (op) {
      case 'next':
        final pending = assets.keys
            .where((id) => !stored.contains(id))
            .where((id) => (failures[id] ?? 0) < 3)
            .toList();
        final limit = (extra['limit'] as num?)?.toInt() ?? pending.length;
        return {
          'ok': true,
          'selected': assets.length,
          'done': stored.length,
          'remaining': pending.length,
          'given_up': assets.keys
              .where((id) => (failures[id] ?? 0) >= 3)
              .length,
          'assets': [
            for (final id in pending.take(limit))
              {
                'asset_id': id,
                'path': 'K:/lib/${assets[id]}',
                'name': assets[id],
                'relative_path': 'pack/${assets[id]}',
              },
          ],
        };
      case 'images':
        handOvers += 1;
        final entries = (extra['entries'] as List).cast<Map<String, Object?>>();
        for (final entry in entries) {
          // Decoding proves the driver sent a real picture, not a placeholder.
          base64Decode(entry['png'] as String);
          stored.add(entry['asset_id'] as String);
        }
        return {'ok': true, 'stored': entries.length, 'count': stored.length};
      case 'failed':
        for (final entry
            in (extra['entries'] as List).cast<Map<String, Object?>>()) {
          final id = entry['asset_id'] as String;
          failures[id] = (failures[id] ?? 0) + 1;
        }
        return {'ok': true, 'recorded': 1};
      case 'retry':
        final forgotten = failures.length;
        failures.clear();
        return {'ok': true, 'forgotten': forgotten};
    }
    throw TagWorkerException('no such op $op');
  }

  @override
  Future<void> close() async => closed = true;
}

void main() {
  Map<String, String> libraryOf(int count) => {
    for (var index = 0; index < count; index += 1)
      'id:${index.toString().padLeft(2, '0')}':
          'SM_Thing_${index.toString().padLeft(2, '0')}.fbx',
  };

  /// A queue wired to [worker], rendering whatever [render] says.
  VisualTagQueue queueFor(
    FakeWorker worker, {
    RenderAsset? render,
    Future<bool> Function()? alive,
    int batchSize = 4,
    int renderConcurrency = 4,
    void Function(TagProgress)? onProgress,
  }) => VisualTagQueue(
    python: 'python',
    script: 'atlas_embed.py',
    vectorsPath: 'v.f32',
    indexPath: 'i.sqlite',
    batchSize: batchSize,
    renderConcurrency: renderConcurrency,
    // No pacing in tests: it is the one thing here that is pure waiting.
    paceMs: 0,
    isRendererAlive: alive,
    onProgress: onProgress,
    renderAsset:
        render ?? ((path, size) async => Uint8List.fromList([1, 2, 3])),
    startWorker:
        ({
          required python,
          required script,
          required vectorsPath,
          required indexPath,
          threads = 2,
        }) async => worker,
  );

  group('a straightforward run', () {
    test('it embeds everything and finishes', () async {
      final worker = FakeWorker(libraryOf(10));
      final queue = queueFor(worker);
      await queue.start(const TagScope());
      expect(worker.stored.length, 10);
      expect(queue.progress.state, TagState.finished);
      expect(queue.progress.embeddedThisRun, 10);
    });

    test('it closes the worker even so', () async {
      // One child per run, holding 325 MB. Leaking one is not an option.
      final worker = FakeWorker(libraryOf(4));
      await queueFor(worker).start(const TagScope());
      expect(worker.closed, isTrue);
    });

    test('a partial final batch is still handed over', () async {
      // Ten assets in batches of four: the last two must not be dropped.
      final worker = FakeWorker(libraryOf(10));
      await queueFor(worker, batchSize: 4).start(const TagScope());
      expect(worker.stored.length, 10);
      expect(worker.handOvers, 3);
    });

    test('nothing is rendered twice', () async {
      // A render not yet handed over is not in the store, so a top-up can
      // hand the same asset back. The other driver got this wrong and ten
      // assets produced twelve vectors.
      final rendered = <String>[];
      final worker = FakeWorker(libraryOf(10));
      await queueFor(
        worker,
        batchSize: 3,
        render: (path, size) async {
          rendered.add(path);
          return Uint8List.fromList([1]);
        },
      ).start(const TagScope());
      expect(rendered.length, 10);
      expect(rendered.toSet().length, 10);
    });

    test('an empty library finishes rather than hanging', () async {
      final queue = queueFor(FakeWorker({}));
      await queue.start(const TagScope());
      expect(queue.progress.state, TagState.finished);
    });

    test('a second start while running returns the same run', () async {
      final worker = FakeWorker(libraryOf(6));
      final queue = queueFor(worker);
      final first = queue.start(const TagScope());
      final second = queue.start(const TagScope());
      await Future.wait([first, second]);
      expect(worker.stored.length, 6);
    });
  });

  group('stopping', () {
    test('stop keeps what was rendered and reports paused', () async {
      final worker = FakeWorker(libraryOf(40));
      late final VisualTagQueue queue;
      var seen = 0;
      queue = queueFor(
        worker,
        batchSize: 4,
        render: (path, size) async {
          seen += 1;
          if (seen == 6) queue.stop();
          return Uint8List.fromList([1]);
        },
      );
      await queue.start(const TagScope());
      // Four from the full batch plus the two in hand: nothing thrown away.
      expect(worker.stored.length, 6);
      expect(queue.progress.state, TagState.paused);
    });

    test('a stopped run leaves the rest of the queue alone', () async {
      final worker = FakeWorker(libraryOf(40));
      late final VisualTagQueue queue;
      var seen = 0;
      queue = queueFor(
        worker,
        render: (path, size) async {
          seen += 1;
          if (seen == 5) queue.stop();
          return Uint8List.fromList([1]);
        },
      );
      await queue.start(const TagScope());
      expect(worker.failures, isEmpty);
      expect(worker.stored.length, lessThan(40));
    });

    test('starting again carries on from where it stopped', () async {
      final worker = FakeWorker(libraryOf(12));
      late final VisualTagQueue first;
      var seen = 0;
      first = queueFor(
        worker,
        batchSize: 4,
        render: (path, size) async {
          seen += 1;
          if (seen == 4) first.stop();
          return Uint8List.fromList([1]);
        },
      );
      await first.start(const TagScope());
      final partway = worker.stored.length;
      expect(partway, inInclusiveRange(1, 11));

      await queueFor(worker, batchSize: 4).start(const TagScope());
      expect(worker.stored.length, 12);
    });
  });

  group('pausing', () {
    test('pause holds, and resume carries on', () async {
      final worker = FakeWorker(libraryOf(12));
      late final VisualTagQueue queue;
      var seen = 0;
      queue = queueFor(
        worker,
        batchSize: 2,
        render: (path, size) async {
          seen += 1;
          if (seen == 3) {
            queue.pause();
            // Let it come to rest, then let it go again.
            Future<void>.delayed(const Duration(milliseconds: 10), () {
              expect(queue.progress.state, TagState.paused);
              queue.resumeRun();
            });
          }
          return Uint8List.fromList([1]);
        },
      );
      await queue.start(const TagScope());
      expect(worker.stored.length, 12);
      expect(queue.progress.state, TagState.finished);
    });

    test('pause on an idle queue does nothing', () {
      final queue = queueFor(FakeWorker(libraryOf(2)));
      queue.pause();
      expect(queue.progress.state, TagState.idle);
    });

    test('stop releases a paused run rather than deadlocking it', () async {
      final worker = FakeWorker(libraryOf(20));
      late final VisualTagQueue queue;
      var seen = 0;
      queue = queueFor(
        worker,
        render: (path, size) async {
          seen += 1;
          if (seen == 2) {
            queue.pause();
            Future<void>.delayed(
              const Duration(milliseconds: 10),
              queue.stop,
            );
          }
          return Uint8List.fromList([1]);
        },
      );
      // The thing under test is that this returns at all.
      await queue.start(const TagScope());
      expect(queue.isRunning, isFalse);
    });
  });

  group('who gets blamed for a failed render', () {
    test('one bad file is recorded and the run continues', () async {
      final worker = FakeWorker(libraryOf(8));
      await queueFor(
        worker,
        alive: () async => true,
        render: (path, size) async {
          if (path.endsWith('SM_Thing_03.fbx')) {
            throw Exception('has no geometry to draw');
          }
          return Uint8List.fromList([1]);
        },
      ).start(const TagScope());
      expect(worker.failures.keys, ['id:03']);
      expect(worker.stored.length, 7);
    });

    test('a dead renderer blames nothing at all', () async {
      // The bug this exists for: charging every remaining asset an attempt
      // for something that is not about it would, after three such runs,
      // permanently skip thousands of good files.
      final worker = FakeWorker(libraryOf(20));
      var alive = true;
      final queue = queueFor(
        worker,
        alive: () async => alive,
        render: (path, size) async {
          if (path.endsWith('SM_Thing_06.fbx')) {
            alive = false;
            throw Exception('connection refused');
          }
          return Uint8List.fromList([1]);
        },
      );
      await queue.start(const TagScope());
      expect(worker.failures, isEmpty);
      expect(queue.progress.state, TagState.failed);
      expect(queue.progress.message, contains('renderer stopped'));
    });

    test('the renders already done are still kept', () async {
      final worker = FakeWorker(libraryOf(20));
      var alive = true;
      await queueFor(
        worker,
        batchSize: 4,
        alive: () async => alive,
        render: (path, size) async {
          if (path.endsWith('SM_Thing_06.fbx')) {
            alive = false;
            throw Exception('connection refused');
          }
          return Uint8List.fromList([1]);
        },
      ).start(const TagScope());
      // Six renders preceded the failure, and the lanes that were already
      // drawing when it happened finish and are kept too -- which is the
      // point of the test. What matters is that the run stopped there
      // rather than working through the other fourteen.
      expect(worker.stored.length, greaterThanOrEqualTo(6));
      expect(worker.stored.length, lessThan(12));
    });

    test('an asset that fails three times drops out of the queue', () async {
      final worker = FakeWorker(libraryOf(4));
      for (var attempt = 0; attempt < 3; attempt += 1) {
        await queueFor(
          worker,
          alive: () async => true,
          render: (path, size) async {
            if (path.endsWith('SM_Thing_02.fbx')) {
              throw Exception('broken');
            }
            return Uint8List.fromList([1]);
          },
        ).start(const TagScope());
      }
      expect(worker.failures['id:02'], 3);
      final queue = queueFor(worker, alive: () async => true);
      await queue.start(const TagScope());
      expect(queue.progress.givenUp, 1);
    });
  });

  group('when the worker dies', () {
    test('it reports why instead of hanging', () async {
      final worker = FakeWorker(libraryOf(8))..dieWith = 'the pipe closed';
      final queue = queueFor(worker);
      await queue.start(const TagScope());
      expect(queue.progress.state, TagState.failed);
      expect(queue.progress.message, contains('pipe closed'));
    });

    test('it still closes the process', () async {
      final worker = FakeWorker(libraryOf(8))..dieWith = 'gone';
      await queueFor(worker).start(const TagScope());
      expect(worker.closed, isTrue);
    });

    test('a worker that will not start is reported, not thrown', () async {
      final queue = VisualTagQueue(
        python: 'python',
        script: 'atlas_embed.py',
        vectorsPath: 'v.f32',
        indexPath: 'i.sqlite',
        renderAsset: (path, size) async => Uint8List(0),
        startWorker:
            ({
              required python,
              required script,
              required vectorsPath,
              required indexPath,
              threads = 2,
            }) async => throw TagWorkerException('Python is not installed'),
      );
      await queue.start(const TagScope());
      expect(queue.progress.state, TagState.failed);
      expect(queue.progress.message, contains('Python'));
    });
  });

  group('progress reporting', () {
    test('it names the file being worked on', () async {
      final seen = <String>[];
      final worker = FakeWorker(libraryOf(4));
      await queueFor(
        worker,
        onProgress: (progress) {
          final current = progress.current;
          if (current != null) seen.add(current);
        },
      ).start(const TagScope());
      expect(seen, contains('SM_Thing_00.fbx'));
    });

    test('the summary reads sensibly in each state', () {
      expect(
        const TagProgress(state: TagState.idle).summary,
        contains('not running'),
      );
      expect(
        const TagProgress(state: TagState.running, done: 3, remaining: 7)
            .summary,
        contains('3 of 10'),
      );
      expect(
        const TagProgress(state: TagState.finished, done: 9).summary,
        contains('9'),
      );
    });

    test('the fraction is null before anything is known', () {
      // A progress bar at zero of zero would read as "stuck", which is a
      // different claim from "nothing has been counted yet".
      expect(const TagProgress(state: TagState.starting).fraction, isNull);
      expect(
        const TagProgress(state: TagState.running, done: 1, remaining: 3)
            .fraction,
        0.25,
      );
    });

    test('a scope describes itself for the status line', () {
      expect(const TagScope().toString(), 'the whole library');
      expect(const TagScope(pack: 'POLYGON_Town').toString(), 'POLYGON_Town');
      expect(
        const TagScope(folder: 'Characters').asRequest,
        {'folder': 'Characters'},
      );
      expect(const TagScope().asRequest, isEmpty);
    });
  });

  group('renders in parallel', () {
    /// A render that takes long enough to still be running when the next
    /// one starts, reporting how many were ever in flight together.
    ({RenderAsset render, List<String> seen, int Function() peak})
        overlapping() {
      final seen = <String>[];
      var inFlight = 0;
      var peak = 0;
      Future<Uint8List> render(String path, int size) async {
        seen.add(path);
        inFlight += 1;
        peak = peak > inFlight ? peak : inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inFlight -= 1;
        return Uint8List.fromList([1, 2, 3]);
      }

      return (render: render, seen: seen, peak: () => peak);
    }

    test('several renders really do overlap', () async {
      final worker = FakeWorker(libraryOf(12));
      final probe = overlapping();
      await queueFor(worker, render: probe.render, renderConcurrency: 4)
          .start(const TagScope());
      expect(probe.peak(), greaterThan(1));
      expect(worker.stored.length, 12);
    });

    test('and never more than the dial allows', () async {
      final worker = FakeWorker(libraryOf(12));
      final probe = overlapping();
      await queueFor(worker, render: probe.render, renderConcurrency: 3)
          .start(const TagScope());
      expect(probe.peak(), lessThanOrEqualTo(3));
    });

    test('a dial of one is still sequential', () async {
      // The old behaviour has to remain reachable: a slower machine may
      // want it, and a test that could not ask for it would not notice if
      // the dial stopped being honoured.
      final worker = FakeWorker(libraryOf(8));
      final probe = overlapping();
      await queueFor(worker, render: probe.render, renderConcurrency: 1)
          .start(const TagScope());
      expect(probe.peak(), 1);
      expect(worker.stored.length, 8);
    });

    test('nothing is rendered twice', () async {
      // The hazard parallel lanes add: a render not yet handed over is not
      // in the store, so two lanes asking what is left both hear about it.
      final worker = FakeWorker(libraryOf(20));
      final probe = overlapping();
      await queueFor(worker, render: probe.render, batchSize: 3)
          .start(const TagScope());
      expect(probe.seen.length, 20);
      expect(probe.seen.toSet().length, 20);
      expect(worker.stored.length, 20);
    });

    test('and nothing is embedded twice', () async {
      // Two lanes seeing a full batch at the same moment would hand over
      // the same renders, which is how ten assets became twelve vectors in
      // the other driver.
      final worker = FakeWorker(libraryOf(16));
      final probe = overlapping();
      final queue = queueFor(worker, render: probe.render, batchSize: 2);
      await queue.start(const TagScope());
      expect(queue.progress.embeddedThisRun, 16);
    });

    test('the worker is never asked two things at once', () async {
      // Replies come back in order off one pipe, so an overlap means each
      // ask can take the other's answer.
      final worker = FakeWorker(libraryOf(16))
        ..askDelay = const Duration(milliseconds: 2);
      final probe = overlapping();
      await queueFor(worker, render: probe.render, batchSize: 2)
          .start(const TagScope());
      expect(worker.peakAskesInFlight, 1);
      expect(worker.stored.length, 16);
    });

    test('a failing render still blames only itself', () async {
      final worker = FakeWorker(libraryOf(10));
      var calls = 0;
      Future<Uint8List> render(String path, int size) async {
        calls += 1;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        if (path.endsWith('04.fbx')) throw StateError('no geometry');
        return Uint8List.fromList([1, 2, 3]);
      }

      final queue = queueFor(
        worker,
        render: render,
        alive: () async => true,
        batchSize: 3,
      );
      await queue.start(const TagScope());
      expect(calls, greaterThanOrEqualTo(10));
      expect(worker.failures.keys.length, 1);
      expect(worker.stored.length, 9);
    });

    test('stopping mid-flight keeps what was already drawn', () async {
      final worker = FakeWorker(libraryOf(40));
      late VisualTagQueue queue;
      var rendered = 0;
      Future<Uint8List> render(String path, int size) async {
        rendered += 1;
        if (rendered == 6) queue.stop();
        await Future<void>.delayed(const Duration(milliseconds: 2));
        return Uint8List.fromList([1, 2, 3]);
      }

      queue = queueFor(worker, render: render, batchSize: 8);
      await queue.start(const TagScope());
      // Everything drawn before the stop is written, and nothing after it
      // is drawn: a partial batch is as safe as a full one, so discarding
      // it would throw away real renders for nothing.
      expect(worker.stored.length, greaterThan(0));
      expect(worker.stored.length, lessThan(40));
      expect(queue.progress.state, TagState.paused);
      expect(worker.closed, isTrue);
    });
  });
}
