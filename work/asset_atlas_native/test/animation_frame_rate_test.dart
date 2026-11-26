import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// One pose per clip frame, not one per display frame.
///
/// The player's ticker fires at the display's rate and used to call
/// `setState` every time. Each of those rebuilds skins every vertex of the
/// character and rasterises the whole pane on the UI isolate -- animated
/// frames deliberately bypass the render worker, because the geometry
/// changes every frame and there is no stable scene for it to hold. On a
/// 60 Hz display a 30 fps clip therefore paid for every frame twice, and
/// paid it on the isolate that also has to drain a model import's stdout
/// pipe: the window could not do both.
///
/// The ticker asks this function whether the frame has changed and does
/// nothing when it has not, so these are the cases that decide how much
/// work playback costs.
void main() {
  group('which frame is showing', () {
    test('it starts on the first frame', () {
      expect(
        animationFrameAt(Duration.zero, frameCount: 30, frameRate: 30),
        0,
      );
    });

    test('a 30 fps clip advances every 33 ms, not every 16', () {
      // The whole point: two consecutive 60 Hz ticks land on one frame.
      const rate = 30.0;
      final first = animationFrameAt(
        const Duration(milliseconds: 16),
        frameCount: 60,
        frameRate: rate,
      );
      final second = animationFrameAt(
        const Duration(milliseconds: 32),
        frameCount: 60,
        frameRate: rate,
      );
      final third = animationFrameAt(
        const Duration(milliseconds: 34),
        frameCount: 60,
        frameRate: rate,
      );
      expect(first, 0);
      expect(second, 0);
      expect(third, 1);
    });

    test('a 144 Hz display skips nearly four ticks in five', () {
      // Counted the way the ticker counts: how many of the ticks in one
      // second of a 30 fps clip change the frame.
      var changed = 0;
      var previous = 0;
      for (var tick = 1; tick <= 144; tick += 1) {
        final elapsed = Duration(microseconds: (tick * 1e6 / 144).round());
        final frame = animationFrameAt(
          elapsed,
          frameCount: 120,
          frameRate: 30,
        );
        if (frame != previous) changed += 1;
        previous = frame;
      }
      expect(changed, 30);
    });

    test('it loops, because a locomotion clip is watched repeatedly', () {
      expect(
        animationFrameAt(
          const Duration(seconds: 1),
          frameCount: 10,
          frameRate: 30,
        ),
        0,
      );
      expect(
        animationFrameAt(
          const Duration(milliseconds: 1100),
          frameCount: 10,
          frameRate: 30,
        ),
        3,
      );
    });

    test('a single frame never advances', () {
      expect(
        animationFrameAt(
          const Duration(seconds: 9),
          frameCount: 1,
          frameRate: 30,
        ),
        0,
      );
      expect(
        animationFrameAt(
          const Duration(seconds: 9),
          frameCount: 0,
          frameRate: 30,
        ),
        0,
      );
    });

    test('a clip with no rate recorded plays at 30', () {
      // Rather than dividing by zero or standing still: every clip in this
      // library that states a rate states 30.
      expect(
        animationFrameAt(
          const Duration(milliseconds: 100),
          frameCount: 60,
          frameRate: 0,
        ),
        3,
      );
      expect(
        animationFrameAt(
          const Duration(milliseconds: 100),
          frameCount: 60,
          frameRate: -5,
        ),
        3,
      );
    });

    test('a 60 fps clip does advance every tick', () {
      // The throttle must not cost anything where there is nothing to save.
      expect(
        animationFrameAt(
          const Duration(milliseconds: 16),
          frameCount: 60,
          frameRate: 60,
        ),
        0,
      );
      expect(
        animationFrameAt(
          const Duration(milliseconds: 17),
          frameCount: 60,
          frameRate: 60,
        ),
        1,
      );
    });
  });
}
