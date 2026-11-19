/// Atlas's own background queue for visual tagging.
///
/// Point Atlas at a folder and this works through it: render each model, hand
/// the picture to the embedder, move on. It runs behind whatever else the
/// machine is doing and is meant to be forgotten about.
///
/// It decides nothing. Which assets are outstanding, what counts as done,
/// what a failure costs and who writes the vectors all live in
/// `work/atlas_mcp/tagging.py`, reached by asking `atlas_embed.py --serve`
/// over a pipe. `tag_assets.py` is the other driver and asks the same
/// questions, so the two cannot disagree about the same library -- and the
/// embedding store, whose crash-safety depends on one writer keeping an
/// ordering across two files, only ever has that one writer.
///
/// What this file owns is pacing. A render measures about 2 s per asset and
/// the whole library is 18 hours, so nobody watches it and it has to stay out
/// of the way: a handful of renders in flight, and a stop that loses at most
/// the batch being embedded.
///
/// The 2 s is not where it was assumed to be. The importer subprocess is
/// 27 ms and the raster has its own isolate; what is left is per-asset work
/// on the calling isolate -- inflating an archive entry (83% of the library
/// lives inside zips), decoding the importer's JSON, decoding textures,
/// encoding a PNG. That part does not parallelise, so it sets the floor.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// How a tagging run is going, for the strip at the bottom of the window.
class TagProgress {
  const TagProgress({
    required this.state,
    this.selected = 0,
    this.done = 0,
    this.remaining = 0,
    this.failed = 0,
    this.givenUp = 0,
    this.embeddedThisRun = 0,
    this.current,
    this.message,
  });

  final TagState state;

  /// Distinct models in scope, after duplicates and clips are removed.
  final int selected;

  /// How many of those already have a vector, from any run.
  final int done;
  final int remaining;

  /// Failures this run, and assets abandoned after too many attempts.
  final int failed;
  final int givenUp;
  final int embeddedThisRun;

  /// The file being rendered, for something to look at.
  final String? current;

  /// Why it stopped, when it stopped for a reason worth reading.
  final String? message;

  bool get isBusy => state == TagState.running || state == TagState.starting;

  double? get fraction {
    final total = done + remaining;
    if (total == 0) return null;
    return done / total;
  }

  String get summary => switch (state) {
    TagState.idle => 'Visual tagging is not running',
    TagState.starting => 'Starting the embedder',
    TagState.running =>
      'Tagging $done of ${done + remaining}'
          '${current == null ? '' : ' — $current'}',
    TagState.paused => 'Paused at $done of ${done + remaining}',
    TagState.finished => 'Tagged everything in scope ($done)',
    TagState.failed => message ?? 'Visual tagging stopped',
  };

  TagProgress copyWith({
    TagState? state,
    int? selected,
    int? done,
    int? remaining,
    int? failed,
    int? givenUp,
    int? embeddedThisRun,
    String? current,
    String? message,
    bool clearCurrent = false,
  }) => TagProgress(
    state: state ?? this.state,
    selected: selected ?? this.selected,
    done: done ?? this.done,
    remaining: remaining ?? this.remaining,
    failed: failed ?? this.failed,
    givenUp: givenUp ?? this.givenUp,
    embeddedThisRun: embeddedThisRun ?? this.embeddedThisRun,
    current: clearCurrent ? null : (current ?? this.current),
    message: message ?? this.message,
  );
}

enum TagState { idle, starting, running, paused, finished, failed }

/// Where the pass is allowed to look. Null everywhere means the library.
class TagScope {
  const TagScope({this.folder, this.pack, this.ext});

  final String? folder;
  final String? pack;
  final String? ext;

  Map<String, Object?> get asRequest => {
    if (folder != null) 'folder': folder,
    if (pack != null) 'pack': pack,
    if (ext != null) 'ext': ext,
  };

  @override
  String toString() =>
      folder ?? pack ?? ext ?? 'the whole library';
}

/// A render the queue asked for, and what came back.
typedef RenderAsset =
    Future<Uint8List> Function(String assetPath, int size);

/// How a worker gets started. A seam for tests, which supply one that answers
/// the protocol from memory instead of starting Python.
typedef TagWorkerStarter =
    Future<TagWorker> Function({
      required String python,
      required String script,
      required String vectorsPath,
      required String indexPath,
      int threads,
    });

/// Thrown when the worker cannot be started or stops answering. Carries the
/// child's stderr, because an unreadable "exit code 1" is no use to anyone.
class TagWorkerException implements Exception {
  TagWorkerException(this.message, {this.details = ''});

  final String message;
  final String details;

  @override
  String toString() =>
      details.isEmpty ? message : '$message\n$details';
}

/// Whatever answers the tagging protocol.
///
/// An interface rather than just the process class, so a test can answer the
/// protocol from memory instead of starting Python and loading 325 MB of
/// ONNX to find out whether the queue stops when asked.
abstract class TagWorker {
  /// One request, one reply. Replies come back in order, so this is safe to
  /// await in sequence and must not be called concurrently.
  Future<Map<String, Object?>> ask(
    String op, [
    Map<String, Object?> extra = const {},
  ]);

  Future<void> close();

  /// Start the real one: `atlas_embed.py --serve` as a child process.
  static Future<TagWorker> start({
    required String python,
    required String script,
    required String vectorsPath,
    required String indexPath,
    int threads = 2,
  }) => ProcessTagWorker.start(
    python: python,
    script: script,
    vectorsPath: vectorsPath,
    indexPath: indexPath,
    threads: threads,
  );
}

/// `atlas_embed.py --serve`, as a child process over two pipes.
///
/// One child per run. The ONNX session costs about a second to construct, so
/// a process per batch would spend longer loading the model than using it.
class ProcessTagWorker implements TagWorker {
  ProcessTagWorker._(this._process, this._lines);

  final Process _process;
  final StreamQueue<String> _lines;
  final StringBuffer _errors = StringBuffer();
  bool _closed = false;

  /// [python] is the interpreter to run; [script] is `atlas_embed.py`; the
  /// two paths are the store, which the worker owns.
  static Future<ProcessTagWorker> start({
    required String python,
    required String script,
    required String vectorsPath,
    required String indexPath,
    int threads = 2,
  }) async {
    final Process process;
    try {
      process = await Process.start(python, [
        // -P, not -I: both keep the working directory off sys.path, but -I
        // also hides user site-packages, which is where onnxruntime and the
        // rest of the embedder's dependencies are installed.
        '-P',
        script,
        '--serve',
        '--threads',
        '$threads',
        '--vectors',
        vectorsPath,
        '--index',
        indexPath,
      ], workingDirectory: File(script).parent.path);
    } on ProcessException catch (error) {
      throw TagWorkerException(
        'Could not start the embedder with "$python".',
        details:
            'Visual tagging needs Python with onnxruntime, Pillow, numpy and '
            'sentencepiece installed — see work/atlas_mcp/README.md.\n'
            '${error.message}',
      );
    }

    final worker = ProcessTagWorker._(
      process,
      StreamQueue<String>(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ),
    );
    // Drained continuously, not read on failure: a child that fills its
    // stderr pipe blocks on the write and never answers, which looks exactly
    // like a hang.
    process.stderr
        .transform(utf8.decoder)
        .listen(worker._errors.write, onError: (Object _) {});
    return worker;
  }

  @override
  Future<Map<String, Object?>> ask(
    String op, [
    Map<String, Object?> extra = const {},
  ]) async {
    if (_closed) {
      throw TagWorkerException('The embedder has already been shut down.');
    }
    _process.stdin.writeln(jsonEncode({'op': op, ...extra}));
    await _process.stdin.flush();

    if (!await _lines.hasNext) {
      throw TagWorkerException(
        'The embedder stopped answering.',
        details: _errors.toString(),
      );
    }
    final decoded = jsonDecode(await _lines.next());
    if (decoded is! Map<String, Object?>) {
      throw TagWorkerException('The embedder sent $decoded, not a reply.');
    }
    if (decoded['ok'] != true) {
      throw TagWorkerException(
        'The embedder refused: ${decoded['error']}',
        details: _errors.toString(),
      );
    }
    return decoded;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _process.stdin.close();
    } on IOException catch (_) {
      // Already gone; nothing to close politely.
    }
    await _lines.cancel(immediate: true);
    // Closing stdin asks it to finish. If it will not, stop waiting: a run
    // that cannot be stopped is worse than a process that has to be killed.
    try {
      await _process.exitCode.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      _process.kill();
    }
  }
}

/// A minimal single-subscription queue over a stream of lines.
///
/// `package:async`'s StreamQueue would do, but it is not a dependency of this
/// project and one class is cheaper than one more package.
class StreamQueue<T> {
  StreamQueue(Stream<T> source) {
    _subscription = source.listen(
      (value) {
        if (_waiting.isNotEmpty) {
          _waiting.removeAt(0).complete(value);
        } else {
          _buffered.add(value);
        }
      },
      onDone: () {
        _done = true;
        for (final pending in _waiting) {
          pending.complete(null);
        }
        _waiting.clear();
      },
      onError: (Object error) {
        _done = true;
        for (final pending in _waiting) {
          pending.completeError(error);
        }
        _waiting.clear();
      },
    );
  }

  late final StreamSubscription<T> _subscription;
  final List<T> _buffered = [];
  final List<Completer<T?>> _waiting = [];
  bool _done = false;

  Future<bool> get hasNext async {
    if (_buffered.isNotEmpty) return true;
    if (_done) return false;
    final completer = Completer<T?>();
    _waiting.add(completer);
    final value = await completer.future;
    if (value == null) return false;
    _buffered.add(value);
    return true;
  }

  Future<T> next() async {
    if (!await hasNext) {
      throw StateError('No more lines.');
    }
    return _buffered.removeAt(0);
  }

  Future<void> cancel({bool immediate = false}) async {
    _done = true;
    await _subscription.cancel();
  }
}
