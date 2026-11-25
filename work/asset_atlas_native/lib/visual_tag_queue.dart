/// The queue itself: ask, render, hand over, repeat.
///
/// A plain object with a progress callback rather than anything
/// Flutter-specific, so it can be driven from a test without a widget tree.
///
/// It decides nothing about *what* to do -- see visual_tagging.dart and
/// `work/atlas_mcp/tagging.py`. What it owns is pacing and stopping, which
/// are the two things that make an hours-long background job tolerable.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'visual_tagging.dart';

class VisualTagQueue {
  VisualTagQueue({
    required this.python,
    required this.script,
    required this.vectorsPath,
    required this.indexPath,
    required this.renderAsset,
    this.onProgress,
    this.threads = 2,
    this.batchSize = 8,
    this.paceMs = 0,
    this.renderConcurrency = defaultRenderLanes,
    this.renderSize = 224,
    this.maxAttempts = 3,
    this.force = false,
    this.isRendererAlive,
    this.startWorker = TagWorker.start,
  });

  final String python;
  final String script;
  final String vectorsPath;
  final String indexPath;

  /// Renders one asset to PNG bytes. The queue never draws anything itself:
  /// this is the app's own renderer, which is the point -- the picture being
  /// embedded is the picture the app shows you.
  final RenderAsset renderAsset;

  final void Function(TagProgress)? onProgress;

  /// How long the lanes have spent waiting for a render and for the
  /// embedder, summed across lanes, and when each asset finished.
  ///
  /// The point of measuring: this repo has six recorded hypotheses about
  /// what makes tagging slow and five of them were wrong. A run now says
  /// which of its two stages it is spending its time in, rather than
  /// inviting a seventh guess.
  int renderWaitMs = 0;
  int workerWaitMs = 0;
  final List<DateTime> _finishedAt = [];

  /// Assets finished in the last minute, as a rate.
  double get assetsPerMinute {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 1));
    _finishedAt.removeWhere((at) => at.isBefore(cutoff));
    return _finishedAt.length.toDouble();
  }

  TagProgress _withTimings(TagProgress progress) => progress.copyWith(
    assetsPerMinute: assetsPerMinute,
    renderWaitMs: renderWaitMs,
    workerWaitMs: workerWaitMs,
  );
  final int threads;
  final int batchSize;

  /// Embed again even where a vector exists.
  ///
  /// A vector is a picture of a model as Atlas drew it that day, so a change
  /// to how Atlas draws makes the old ones wrong -- and nothing in the store
  /// can say which. Off by default: redoing the library is hours.
  final bool force;

  /// A gap between renders, off by default.
  ///
  /// It was 250 ms, on the belief that a render saturates a core. It does
  /// not: the importer subprocess measures 27 ms and the raster runs on its
  /// own isolate, so the gap was 12% of a job measured at 18 hours and was
  /// buying politeness the machine did not need. Kept as a dial rather than
  /// deleted, because a slower machine may want it back.
  final int paceMs;

  /// How many renders are in flight at once.
  ///
  /// Each render is an importer subprocess and a fresh raster isolate, so
  /// that part genuinely spreads across cores. What cannot spread is the
  /// work this isolate does per asset -- inflating the archive entry,
  /// decoding the importer's JSON, decoding textures, encoding the PNG --
  /// which the event loop serialises however high this is set. That is the
  /// ceiling, and it is why this is a handful rather than the core count.
  final int renderConcurrency;

  final int renderSize;
  final int maxAttempts;

  /// Whether the renderer is still there. Consulted only when a render
  /// fails, to decide whether the file is at fault or the app has gone.
  final Future<bool> Function()? isRendererAlive;

  /// A seam for tests: the real one starts a Python child process.
  final TagWorkerStarter startWorker;

  /// Renders in flight when nothing says otherwise.
  ///
  /// Four, not twenty: the per-asset work that cannot leave this isolate
  /// sets the ceiling, so the extra lanes would queue behind each other
  /// while making the window stutter. `--tag-lanes=N` overrides it.
  static const defaultRenderLanes = 4;

  /// A run of failures this long means the problem is not the files. A
  /// renderer that answers and refuses everything looks exactly like a
  /// library of broken models, and the wrong reading is permanent.
  static const consecutiveFailureLimit = 25;

  TagProgress _progress = const TagProgress(state: TagState.idle);
  TagProgress get progress => _progress;

  Completer<void>? _resume;
  bool _stopping = false;
  Future<void>? _running;

  /// Requests to the worker, one at a time.
  ///
  /// [TagWorker.ask] reads replies in order off a single pipe, so two
  /// overlapping asks would each take the other's answer. With renders
  /// running in parallel the overlap is no longer hypothetical: a lane
  /// reporting a failure and a lane handing over a batch want the worker in
  /// the same instant. Every ask goes through this chain so the pipe still
  /// sees one request at a time.
  Future<void> _askChain = Future<void>.value();

  Future<Map<String, Object?>> _ask(
    TagWorker worker,
    String op, [
    Map<String, Object?> extra = const {},
  ]) {
    final answer = Completer<Map<String, Object?>>();
    _askChain = _askChain.then((_) async {
      try {
        answer.complete(await worker.ask(op, extra));
      } catch (error, trace) {
        answer.completeError(error, trace);
      }
    });
    return answer.future;
  }

  bool get isRunning => _running != null;

  void _emit(TagProgress next) {
    _progress = next;
    onProgress?.call(_withTimings(next));
  }

  /// Start, or return the run already in progress.
  Future<void> start(TagScope scope) {
    final existing = _running;
    if (existing != null) return existing;
    _stopping = false;
    _resume = null;
    final started = _run(scope).whenComplete(() => _running = null);
    _running = started;
    return started;
  }

  /// Finish the batch in hand, then stop. Nothing is lost: the store knows
  /// what has a vector, so the next run carries on from there.
  void stop() {
    _stopping = true;
    _releasePause();
  }

  void pause() {
    if (_progress.state != TagState.running) return;
    _resume ??= Completer<void>();
    _emit(_progress.copyWith(state: TagState.paused, clearCurrent: true));
  }

  void resumeRun() {
    if (_progress.state != TagState.paused) return;
    _releasePause();
    _emit(_progress.copyWith(state: TagState.running));
  }

  void _releasePause() {
    final waiting = _resume;
    _resume = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }

  Future<void> _waitWhilePaused() async {
    while (_resume != null && !_stopping) {
      await _resume!.future;
    }
  }

  Future<void> _run(TagScope scope) async {
    _emit(const TagProgress(state: TagState.starting));

    final TagWorker worker;
    try {
      worker = await startWorker(
        python: python,
        script: script,
        vectorsPath: vectorsPath,
        indexPath: indexPath,
        threads: threads,
      );
    } on TagWorkerException catch (error) {
      _emit(TagProgress(state: TagState.failed, message: error.message));
      return;
    }

    // Every asset this run has taken off the queue. A render that has not
    // been handed over is not in the store yet, so without this a top-up
    // hands back whatever is still in the batch and renders it twice -- ten
    // assets produced twelve vectors when the other driver got this wrong.
    final taken = <String>{};
    final batch = <Map<String, Object?>>[];
    var embedded = 0;
    var failures = 0;
    var consecutive = 0;
    String? stoppedBecause;

    try {
      while (!_stopping) {
        await _waitWhilePaused();
        if (_stopping) break;

        final work = await _ask(worker, 'next', {
          'limit': batchSize * 8,
          'max_attempts': maxAttempts,
          if (force) 'force': true,
          ...scope.asRequest,
        });
        _emit(
          _progress.copyWith(
            state: TagState.running,
            selected: _asInt(work['selected']),
            done: _asInt(work['done']),
            remaining: _asInt(work['remaining']),
            givenUp: _asInt(work['given_up']),
          ),
        );

        final assets = ((work['assets'] as List?) ?? const [])
            .cast<Map<String, Object?>>()
            .where((asset) => !taken.contains(asset['asset_id'] as String))
            .toList();
        if (assets.isEmpty) break;

        // One shared cursor rather than a slice each, so a lane that
        // draws a mech does not leave its share waiting while the others
        // finish early on crates.
        var cursor = 0;

        Future<void> renderLane() async {
          while (true) {
            if (_stopping) return;
            await _waitWhilePaused();
            if (_stopping) return;

            // Reading and advancing the cursor happens in one synchronous
            // step, with no await between, so two lanes cannot claim the
            // same asset. The same reasoning covers `batch` below.
            if (cursor >= assets.length) return;
            final asset = assets[cursor];
            cursor += 1;

            final assetId = asset['asset_id'] as String;
            if (!taken.add(assetId)) continue;
            _emit(_progress.copyWith(current: asset['name'] as String?));

            final Uint8List png;
            final renderStarted = DateTime.now();
            try {
              png = await renderAsset(asset['path'] as String, renderSize);
              renderWaitMs +=
                  DateTime.now().difference(renderStarted).inMilliseconds;
              _finishedAt.add(DateTime.now());
            } catch (error) {
              renderWaitMs +=
                  DateTime.now().difference(renderStarted).inMilliseconds;
              // Charging the asset is only right when the asset is at fault.
              // If the renderer has gone, every remaining file would be
              // charged an attempt for something that is not about it, and
              // three such runs would permanently skip thousands of models.
              if (!await _rendererStillThere()) {
                stoppedBecause = 'The renderer stopped, so the rest were left '
                    'alone rather than blamed';
                _stopping = true;
                _releasePause();
                return;
              }
              consecutive += 1;
              if (consecutive >= consecutiveFailureLimit) {
                stoppedBecause =
                    '$consecutive renders failed in a row, so something '
                    'systemic is wrong and the rest were left alone';
                _stopping = true;
                _releasePause();
                return;
              }
              failures += 1;
              await _ask(worker, 'failed', {
                'entries': [
                  {'asset_id': assetId, 'reason': '$error'},
                ],
              });
              _emit(_progress.copyWith(failed: failures));
              continue;
            }

            consecutive = 0;
            batch.add({'asset_id': assetId, 'png': base64Encode(png)});

            if (batch.length >= batchSize) {
              // Emptied in the same synchronous step it is read, so two
              // lanes cannot hand over the same renders. Taking a copy and
              // clearing after the await produced twelve vectors from ten
              // assets in the other driver.
              final slice = List<Map<String, Object?>>.of(batch);
              batch.clear();
              // Not `embedded += await ...`: that reads `embedded` before
              // the await, so two lanes finishing together both add to the
              // same stale value and one hand-over vanishes from the count.
              final stored = await _handOver(worker, slice);
              embedded += stored;
              _emit(_progress.copyWith(embeddedThisRun: embedded));
            }
            if (paceMs > 0) {
              await Future<void>.delayed(Duration(milliseconds: paceMs));
            }
          }
        }

        // A lane keeps its own failure to itself rather than throwing
        // through Future.wait, which reports the first error and drops the
        // rest -- and a dropped TagWorkerException would lose the reason the
        // run stopped.
        Future<void> lane() async {
          try {
            await renderLane();
          } on TagWorkerException catch (error) {
            stoppedBecause ??= error.message;
            _stopping = true;
            _releasePause();
          }
        }

        final lanes = renderConcurrency < 1 ? 1 : renderConcurrency;
        await Future.wait(
          List<Future<void>>.generate(lanes, (_) => lane()),
        );
      }
    } on TagWorkerException catch (error) {
      stoppedBecause = error.message;
    } finally {
      // Whatever is in hand gets written, on every path out: the store's
      // append order makes a partial batch exactly as safe as a full one,
      // and discarding it would throw away real renders for nothing.
      if (batch.isNotEmpty) {
        try {
          final stored = await _handOver(worker, batch);
          embedded += stored;
        } on TagWorkerException catch (_) {
          // The worker is gone and these renders are lost. They kept no
          // vector, so the next run simply does them again.
        }
        batch.clear();
      }
      await worker.close();
    }

    _emit(_finalProgress(embedded, failures, stoppedBecause));
  }

  Future<bool> _rendererStillThere() async {
    final check = isRendererAlive;
    if (check == null) return true;
    return check();
  }

  Future<int> _handOver(
    TagWorker worker,
    List<Map<String, Object?>> batch,
  ) async {
    final started = DateTime.now();
    try {
      final reply = await _ask(worker, 'images', {'entries': batch});
      return _asInt(reply['stored']);
    } finally {
      workerWaitMs += DateTime.now().difference(started).inMilliseconds;
    }
  }

  TagProgress _finalProgress(
    int embedded,
    int failures,
    String? stoppedBecause,
  ) {
    final base = _progress.copyWith(
      embeddedThisRun: embedded,
      failed: failures,
      clearCurrent: true,
    );
    if (stoppedBecause != null) {
      return base.copyWith(state: TagState.failed, message: stoppedBecause);
    }
    // Stopped on request is paused, not finished: there is still work.
    if (_stopping) return base.copyWith(state: TagState.paused);
    return base.copyWith(state: TagState.finished, remaining: 0);
  }

  static int _asInt(Object? value) => (value as num?)?.toInt() ?? 0;
}
