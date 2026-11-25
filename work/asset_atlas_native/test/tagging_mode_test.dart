import 'package:asset_atlas_native/main.dart';
import 'package:asset_atlas_native/visual_tagging.dart';
import 'package:flutter_test/flutter_test.dart';

/// The four tagging modes, and the flag that picks one.
///
/// One setting rather than three dials, because the three only make sense
/// together: lanes decide how many renders are in flight, model threads
/// decide what the embedder gets, and the pause is there for the case where
/// someone is working in Atlas while it runs.
void main() {
  group('what each mode asks for', () {
    test('quiet is one of everything, with a pause', () {
      expect(TaggingMode.quiet.lanes, 1);
      expect(TaggingMode.quiet.threadsOn(20), 1);
      expect(TaggingMode.quiet.paceMs, 100);
    });

    test('balanced is what every run before this used', () {
      expect(TaggingMode.balanced.lanes, 4);
      expect(TaggingMode.balanced.threadsOn(20), 2);
      expect(TaggingMode.balanced.paceMs, 0);
    });

    test('fast and overnight ask for more and never pause', () {
      expect(TaggingMode.fast.lanes, 8);
      expect(TaggingMode.overnight.lanes, 12);
      expect(TaggingMode.fast.paceMs, 0);
      expect(TaggingMode.overnight.paceMs, 0);
    });

    test('threads are capped at the physical cores', () {
      // numberOfProcessors counts hardware threads. Asking onnxruntime for
      // twice the cores spends the gain on contention.
      expect(TaggingMode.overnight.threadsOn(20), 10);
      expect(TaggingMode.overnight.threadsOn(8), 4);
      expect(TaggingMode.fast.threadsOn(4), 2);
      expect(TaggingMode.quiet.threadsOn(1), 1);
    });

    test('every mode has something to say for itself', () {
      for (final mode in TaggingMode.values) {
        expect(mode.label, isNotEmpty);
        expect(mode.describe, isNotEmpty);
        expect(mode.lanes, greaterThan(0));
      }
    });
  });

  group('reading a mode back', () {
    test('by name', () {
      expect(taggingModeByName('quiet'), TaggingMode.quiet);
      expect(taggingModeByName('overnight'), TaggingMode.overnight);
    });

    test('anything else is the default', () {
      expect(taggingModeByName(null), TaggingMode.balanced);
      expect(taggingModeByName(''), TaggingMode.balanced);
      expect(taggingModeByName('turbo'), TaggingMode.balanced);
    });
  });

  group('--tag-mode', () {
    test('picks a mode', () {
      expect(
        parseStartupOptions(['--tag-mode=overnight']).tagMode,
        TaggingMode.overnight,
      );
    });

    test('a name it does not know leaves the saved setting alone', () {
      expect(parseStartupOptions(['--tag-mode=ludicrous']).tagMode, isNull);
      expect(parseStartupOptions([]).tagMode, isNull);
    });

    test('an explicit --tag-lanes still wins over the mode', () {
      final options = parseStartupOptions([
        '--tag-mode=quiet',
        '--tag-lanes=6',
      ]);
      expect(options.tagMode, TaggingMode.quiet);
      expect(options.renderLanes, 6);
    });

    test('the other flags still read', () {
      final options = parseStartupOptions(['--tag-all', '--tag-mode=fast']);
      expect(options.tagAll, isTrue);
      expect(options.tagMode, TaggingMode.fast);
      expect(options.tagForce, isFalse);
    });

    test('--tag-force asks for the embedded ones again', () {
      // A vector is a picture of a model as Atlas drew it that day. When
      // the way Atlas draws changes -- a texture it now finds, say -- the
      // old vectors are wrong, and nothing in the store can say which.
      final options = parseStartupOptions(['--tag-all', '--tag-force']);
      expect(options.tagForce, isTrue);
      expect(parseStartupOptions(['--tag-all']).tagForce, isFalse);
    });
  });

  group('what a run reports about itself', () {
    test('the progress carries the rate and both waits', () {
      const progress = TagProgress(
        state: TagState.running,
        assetsPerMinute: 42,
        renderWaitMs: 1000,
        workerWaitMs: 250,
      );
      expect(progress.assetsPerMinute, 42);
      expect(progress.renderWaitMs, 1000);
      expect(progress.workerWaitMs, 250);
    });

    test('copyWith keeps them, so an emit does not reset the measurement', () {
      const progress = TagProgress(
        state: TagState.running,
        assetsPerMinute: 42,
        renderWaitMs: 1000,
        workerWaitMs: 250,
      );
      final next = progress.copyWith(done: 5);
      expect(next.assetsPerMinute, 42);
      expect(next.renderWaitMs, 1000);
      expect(next.workerWaitMs, 250);
    });
  });
}
