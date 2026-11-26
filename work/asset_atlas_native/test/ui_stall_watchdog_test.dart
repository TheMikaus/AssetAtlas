import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// Naming the work that froze the window.
///
/// Written after a stall was diagnosed by elimination instead of
/// measurement: the window burned a core for twelve minutes, a model load
/// behind it never finished, and nothing in the app could say which stage
/// was running. The watchdog's timer cannot be faked here -- it measures
/// real lateness against `DateTime.now()` -- so the decision it makes is a
/// pure function, and this is that function.
void main() {
  setUp(uiStageCounts.clear);

  group('what counts as a stall', () {
    test('an ordinary gap between ticks says nothing', () {
      expect(uiStallReport(260, const {'sort': 1}), isNull);
    });

    test('a gap just under the threshold still says nothing', () {
      expect(uiStallReport(uiStallThresholdMs - 1, const {}), isNull);
    });

    test('a long gap reports how long and what ran', () {
      final report = uiStallReport(4200, const {'sort': 2, 'filter': 4});
      expect(report, isNotNull);
      expect(report, contains('4200 ms'));
      expect(report, contains('filter x4'));
      expect(report, contains('sort x2'));
    });

    test('the busiest stage is named first', () {
      // The point of the line is to be read at a glance, and the stage that
      // ran most is the one worth looking at.
      expect(
        uiStallReport(1000, const {'sort': 1, 'raster': 9, 'collapse': 3}),
        contains('raster x9, collapse x3, sort x1'),
      );
    });

    test('equal counts fall back to name, so the line is stable', () {
      expect(
        describeUiStages(const {'sort': 2, 'collapse': 2, 'filter': 2}),
        'collapse x2, filter x2, sort x2',
      );
    });

    test('a stall with nothing instrumented in it says that', () {
      // Worth distinguishing: it means the block was somewhere this does not
      // yet watch, which is the next thing to instrument.
      expect(uiStallReport(3000, const {}), contains('nothing instrumented'));
    });
  });

  group('counting stages', () {
    test('each call adds one, not one per asset', () {
      countUiStage('sort');
      countUiStage('sort');
      countUiStage('filter');
      expect(uiStageCounts, {'sort': 2, 'filter': 1});
    });

    test('starting and stopping the watchdog leaves nothing behind', () {
      UiStallWatchdog.start();
      // Idempotent: the window starts it once, but a restarted catalog
      // should not leave two timers logging the same stall twice.
      UiStallWatchdog.start();
      UiStallWatchdog.stop();
      UiStallWatchdog.stop();
    });
  });
}
