import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asset_atlas_native/main.dart';
import 'package:asset_atlas_native/visual_tagging.dart';

/// The strip, and above all whether its controls can be reached.
///
/// Written because they could not be. The idle state returned an empty box,
/// so the strip only appeared once a run was going — which is after the
/// point at which anyone needs the button that starts one. Nothing caught
/// it: the queue was tested thoroughly and the way into the queue was not
/// tested at all.
void main() {
  Future<void> pumpStrip(
    WidgetTester tester, {
    required TagProgress progress,
    String? unavailable,
    VoidCallback? onStart,
    VoidCallback? onPause,
    VoidCallback? onResume,
    VoidCallback? onStop,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: VisualTaggingStrip(
          progress: progress,
          unavailable: unavailable,
          onStart: onStart ?? () {},
          onPause: onPause ?? () {},
          onResume: onResume ?? () {},
          onStop: onStop ?? () {},
        ),
      ),
    ),
  );

  group('idle', () {
    testWidgets('it offers a way to start', (tester) async {
      await pumpStrip(
        tester,
        progress: const TagProgress(state: TagState.idle),
      );
      expect(find.text('Start visual tagging'), findsOneWidget);
    });

    testWidgets('pressing it starts', (tester) async {
      var started = 0;
      await pumpStrip(
        tester,
        progress: const TagProgress(state: TagState.idle),
        onStart: () => started += 1,
      );
      await tester.tap(find.text('Start visual tagging'));
      expect(started, 1);
    });

    testWidgets('it says what tagging is for', (tester) async {
      // Nobody should have to guess what a button marked with a sparkle is
      // about to spend three hours doing.
      await pumpStrip(
        tester,
        progress: const TagProgress(state: TagState.idle),
      );
      expect(find.textContaining('renders each model'), findsOneWidget);
    });
  });

  group('running', () {
    const running = TagProgress(
      state: TagState.running,
      done: 3,
      remaining: 7,
      current: 'SM_Barrel.fbx',
    );

    testWidgets('it shows progress and the file in hand', (tester) async {
      await pumpStrip(tester, progress: running);
      expect(find.textContaining('3 of 10'), findsOneWidget);
      expect(find.textContaining('SM_Barrel.fbx'), findsOneWidget);
    });

    testWidgets('pause and stop are both reachable', (tester) async {
      var paused = 0;
      var stopped = 0;
      await pumpStrip(
        tester,
        progress: running,
        onPause: () => paused += 1,
        onStop: () => stopped += 1,
      );
      await tester.tap(find.byIcon(Icons.pause));
      await tester.tap(find.byIcon(Icons.stop));
      expect(paused, 1);
      expect(stopped, 1);
    });

    testWidgets('there is no start button while it is running', (tester) async {
      await pumpStrip(tester, progress: running);
      expect(find.byIcon(Icons.play_arrow), findsNothing);
    });

    testWidgets('a progress bar appears', (tester) async {
      await pumpStrip(tester, progress: running);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });
  });

  group('paused', () {
    testWidgets('resume is reachable when there is work left', (tester) async {
      var resumed = 0;
      await pumpStrip(
        tester,
        progress: const TagProgress(
          state: TagState.paused,
          done: 4,
          remaining: 6,
        ),
        onResume: () => resumed += 1,
      );
      await tester.tap(find.byIcon(Icons.play_arrow));
      expect(resumed, 1);
    });

    testWidgets('no resume when nothing is left to do', (tester) async {
      await pumpStrip(
        tester,
        progress: const TagProgress(state: TagState.paused, done: 10),
      );
      expect(find.byIcon(Icons.play_arrow), findsNothing);
    });
  });

  group('finished and failed', () {
    testWidgets('finished says so and offers nothing to press', (tester) async {
      await pumpStrip(
        tester,
        progress: const TagProgress(state: TagState.finished, done: 9),
      );
      expect(find.textContaining('9'), findsOneWidget);
      expect(find.byIcon(Icons.pause), findsNothing);
      expect(find.byIcon(Icons.stop), findsNothing);
    });

    testWidgets('a failure shows why, and a way to try again', (tester) async {
      await pumpStrip(
        tester,
        progress: const TagProgress(
          state: TagState.failed,
          message: 'The renderer stopped',
        ),
      );
      expect(find.textContaining('renderer stopped'), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
    });
  });

  group('unavailable', () {
    testWidgets('it explains instead of showing a dead button',
        (tester) async {
      // A missing dependency is the one failure the person can actually fix,
      // so the strip has to name it rather than offer a button that cannot
      // work.
      await pumpStrip(
        tester,
        progress: const TagProgress(state: TagState.idle),
        unavailable: 'No Python on PATH could run the embedder.',
      );
      expect(find.textContaining('No Python on PATH'), findsOneWidget);
      expect(find.text('Start visual tagging'), findsNothing);
    });
  });

  group('counts worth seeing', () {
    testWidgets('failures and skips are reported', (tester) async {
      await pumpStrip(
        tester,
        progress: const TagProgress(
          state: TagState.running,
          done: 5,
          remaining: 5,
          failed: 2,
          givenUp: 3,
        ),
      );
      expect(find.textContaining('2 failed'), findsOneWidget);
      expect(find.textContaining('3 skipped'), findsOneWidget);
    });

    testWidgets('and left out when there are none', (tester) async {
      await pumpStrip(
        tester,
        progress: const TagProgress(
          state: TagState.running,
          done: 5,
          remaining: 5,
        ),
      );
      expect(find.textContaining('failed'), findsNothing);
    });
  });
}
