import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// One list refresh per burst of background verdicts, not one per file.
///
/// The texture filter validates models lazily: its own pass queues every
/// model it has no verdict for ([main.dart] `_assetsMatching`), and each
/// verdict changes what the list shows. Each refresh re-runs both filter
/// passes and both collapses over 480,826 assets -- about 1.3 s, on the UI
/// thread -- so applying 48,000 verdicts one at a time is a thread pinned
/// for hours. It was measured pinned for 46 minutes, with the model load
/// waiting behind it taking 13 minutes 57 seconds.
///
/// `testWidgets` is used for its fake clock, not for any widget.
void main() {
  testWidgets('a burst of requests costs one refresh', (tester) async {
    var refreshes = 0;
    final coalescer = ListRefreshCoalescer(
      onRefresh: () => refreshes += 1,
      window: const Duration(milliseconds: 500),
    );

    for (var verdict = 0; verdict < 50; verdict += 1) {
      coalescer.request();
    }
    expect(refreshes, 0, reason: 'nothing redraws while the burst arrives');

    await tester.pump(const Duration(milliseconds: 500));
    expect(refreshes, 1);
    expect(coalescer.hasPending, isFalse);
  });

  testWidgets('a long sweep refreshes on its own schedule, not per verdict', (
    tester,
  ) async {
    var refreshes = 0;
    final coalescer = ListRefreshCoalescer(
      onRefresh: () => refreshes += 1,
      window: const Duration(milliseconds: 500),
    );

    // Ten verdicts a second for five seconds: 50 files, which used to be 50
    // whole-catalog refreshes.
    for (var tick = 0; tick < 50; tick += 1) {
      coalescer.request();
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(refreshes, lessThanOrEqualTo(10));
    expect(refreshes, greaterThan(0), reason: 'the list must still catch up');
  });

  testWidgets('a verdict after a quiet spell still redraws', (tester) async {
    var refreshes = 0;
    final coalescer = ListRefreshCoalescer(
      onRefresh: () => refreshes += 1,
      window: const Duration(milliseconds: 500),
    );

    coalescer.request();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 5));
    coalescer.request();
    await tester.pump(const Duration(milliseconds: 500));

    expect(refreshes, 2);
  });

  testWidgets('cancelling drops the pending redraw', (tester) async {
    // The window closing mid-sweep must not call setState afterwards.
    var refreshes = 0;
    final coalescer = ListRefreshCoalescer(
      onRefresh: () => refreshes += 1,
      window: const Duration(milliseconds: 500),
    );

    coalescer.request();
    expect(coalescer.hasPending, isTrue);
    coalescer.cancel();
    await tester.pump(const Duration(seconds: 2));

    expect(refreshes, 0);
    expect(coalescer.hasPending, isFalse);
  });

  test('the default window is longer than a refresh costs', () {
    // A window shorter than the work it guards would still spend more of the
    // thread on redrawing the list than on validating the files.
    expect(listRefreshWindowMs, greaterThan(1300));
  });
}
