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
    this.paceMs = 250,
    this.renderSize = 224,
    this.maxAttempts = 3,
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
  final int threads;
  final int batchSize;

  /// A gap between renders. The whole reason this queue exists is to leave
  /// the machine usable, and a render saturates a core in the importer.
  final int paceMs;

  final int renderSize;
  final int maxAttempts;

  /// Whether the renderer is still there. Consulted only when a render
  /// fails, to decide whether the file is at fault or the app has gone.
  final Future<bool> Function()? isRendererAlive;

  /// A seam for tests: the real one starts a Python child process.
  final TagWorkerStarter startWorker;

  /// A run of failures this long means the problem is not the files. A
  /// renderer that answers and refuses everything looks exactly like a
  /// library of broken models, and the wrong reading is permanent.
  static const consecutiveFailureLimit = 25;

  TagProgress _progress = const TagProgress(state: TagState.idle);
  TagProgress get progress => _progress;

  Completer<void>? _resume;
  bool _stopping = false;
  Future<void>? _running;

  bool get isRunning => _running != null;

  void _emit(TagProgress next) {
    _progress = next;
    onProgress?.call(next);
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

        final work = await worker.ask('next', {
          'limit': batchSize * 8,
          'max_attempts': maxAttempts,
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

        for (final asset in assets) {
          if (_stopping) break;
          await _waitWhilePaused();
          if (_stopping) break;

          final assetId = asset['asset_id'] as String;
          taken.add(assetId);
          _emit(_progress.copyWith(current: asset['name'] as String?));

          final Uint8List png;
          try {
            png = await renderAsset(asset['path'] as String, renderSize);
          } catch (error) {
            // Charging the asset is only right when the asset is at fault.
            // If the renderer has gone, every remaining file would be
            // charged an attempt for something that is not about it, and
            // three such runs would permanently skip thousands of models.
            if (!await _rendererStillThere()) {
              stoppedBecause = 'The renderer stopped, so the rest were left '
                  'alone rather than blamed';
              _stopping = true;
              break;
            }
            consecutive += 1;
            if (consecutive >= consecutiveFailureLimit) {
              stoppedBecause =
                  '$consecutive renders failed in a row, so something '
                  'systemic is wrong and the rest were left alone';
              _stopping = true;
              break;
            }
            failures += 1;
            await worker.ask('failed', {
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
            embedded += await _handOver(worker, batch);
            batch.clear();
            _emit(_progress.copyWith(embeddedThisRun: embedded));
          }
          if (paceMs > 0) {
            await Future<void>.delayed(Duration(milliseconds: paceMs));
          }
        }
      }
    } on TagWorkerException catch (error) {
      stoppedBecause = error.message;
    } finally {
      // Whatever is in hand gets written, on every path out: the store's
      // append order makes a partial batch exactly as safe as a full one,
      // and discarding it would throw away real renders for nothing.
      if (batch.isNotEmpty) {
        try {
          embedded += await _handOver(worker, batch);
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
    final reply = await worker.ask('images', {'entries': batch});
    return _asInt(reply['stored']);
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
