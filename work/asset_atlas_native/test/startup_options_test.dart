import 'package:flutter_test/flutter_test.dart';
import 'package:asset_atlas_native/main.dart';
import 'package:asset_atlas_native/visual_tag_queue.dart';

/// The launch flags, which exist so the whole library can be tagged with
/// nobody watching.
///
/// Worth testing despite being a dozen lines: a flag that silently fails to
/// parse during an unattended overnight run looks exactly like a run that
/// went slowly, and there is nobody there to notice the difference.
void main() {
  group('by default', () {
    test('nothing starts itself', () {
      final options = parseStartupOptions(const []);
      expect(options.tagAll, isFalse);
      expect(options.renderLanes, isNull);
    });

    test('and no lane count is imposed', () {
      // null, not 4: the queue owns its own default and this must not
      // quietly pin a second copy of that number.
      expect(parseStartupOptions(const ['--tag-all']).renderLanes, isNull);
    });
  });

  group('--tag-all', () {
    test('asks for the whole library', () {
      expect(parseStartupOptions(const ['--tag-all']).tagAll, isTrue);
    });

    test('and is found among other arguments', () {
      final options = parseStartupOptions(
        const ['--enable-dart-profiling', '--tag-all', '--observe'],
      );
      expect(options.tagAll, isTrue);
    });

    test('a near miss does not count', () {
      expect(parseStartupOptions(const ['--tag']).tagAll, isFalse);
      expect(parseStartupOptions(const ['tag-all']).tagAll, isFalse);
      expect(parseStartupOptions(const ['--tag-all=1']).tagAll, isFalse);
    });
  });

  group('--tag-lanes', () {
    test('sets the renders in flight', () {
      expect(parseStartupOptions(const ['--tag-lanes=8']).renderLanes, 8);
    });

    test('tolerates spacing', () {
      expect(parseStartupOptions(const ['--tag-lanes= 6 ']).renderLanes, 6);
    });

    test('rubbish leaves the default alone', () {
      // An app that refuses to open because of a typo in a convenience flag
      // would be a worse outcome than one that runs at the default speed.
      for (final argument in const [
        '--tag-lanes=',
        '--tag-lanes=none',
        '--tag-lanes=4.5',
        '--tag-lanes=-2',
        '--tag-lanes=0',
      ]) {
        expect(
          parseStartupOptions([argument]).renderLanes,
          isNull,
          reason: argument,
        );
      }
    });

    test('an absurd number is refused, not obeyed', () {
      // Each lane is a subprocess and an isolate. A mistyped 400 would ask
      // the machine for 400 of each and is far more likely to be a slip
      // than an intention.
      expect(parseStartupOptions(const ['--tag-lanes=400']).renderLanes,
          isNull);
      expect(parseStartupOptions(const ['--tag-lanes=32']).renderLanes, 32);
    });

    test('the last one given wins', () {
      final options = parseStartupOptions(
        const ['--tag-lanes=4', '--tag-lanes=12'],
      );
      expect(options.renderLanes, 12);
    });

    test('it works without --tag-all, for an interactive run', () {
      final options = parseStartupOptions(const ['--tag-lanes=2']);
      expect(options.tagAll, isFalse);
      expect(options.renderLanes, 2);
    });
  });

  group('the queue default', () {
    test('is the one the flag falls back to', () {
      // The app reads `renderLanes ?? defaultRenderLanes`, so these two
      // have to be the same idea in one place rather than two numbers that
      // drift apart.
      expect(VisualTagQueue.defaultRenderLanes, greaterThanOrEqualTo(1));
      expect(
        VisualTagQueue(
          python: 'python',
          script: 'atlas_embed.py',
          vectorsPath: 'v.f32',
          indexPath: 'i.sqlite',
          renderAsset: (path, size) async => throw UnimplementedError(),
        ).renderConcurrency,
        VisualTagQueue.defaultRenderLanes,
      );
    });
  });
}
