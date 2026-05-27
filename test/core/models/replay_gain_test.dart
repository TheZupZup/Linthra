import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/replay_gain.dart';

void main() {
  group('ReplayGain.linearVolume', () {
    test('no data plays at full volume (untouched)', () {
      expect(ReplayGain.none.linearVolume(), 1.0);
      expect(const ReplayGain(trackPeak: 0.9).linearVolume(), 1.0);
    });

    test('a negative gain attenuates', () {
      // -6 dB ≈ half amplitude.
      final double v = const ReplayGain(trackGainDb: -6.0).linearVolume();
      expect(v, closeTo(0.501, 0.01));
      expect(v, lessThan(1.0));
    });

    test('a positive gain cannot amplify past full (attenuation only)', () {
      // +6 dB would be ~2.0 linear, but just_audio can't amplify, so it's
      // clamped to 1.0 — a quiet track plays at its original level.
      expect(const ReplayGain(trackGainDb: 6.0).linearVolume(), 1.0);
    });

    test('peak limiting keeps a positive gain from clipping', () {
      // A modest positive gain that, with this peak, would push past full
      // scale: the result is capped at 1/peak (still ≤ 1.0 here anyway).
      final double v =
          const ReplayGain(trackGainDb: 3.0, trackPeak: 0.8).linearVolume();
      // 1/0.8 = 1.25, but the global ≤1.0 clamp wins.
      expect(v, 1.0);
    });

    test('peak below the gain bounds the result when attenuating', () {
      // Negative gain (0.5 linear) with a loud peak: peak limit 1/0.95 ≈ 1.05
      // doesn't bind, so the gain itself applies.
      final double v =
          const ReplayGain(trackGainDb: -6.0, trackPeak: 0.95).linearVolume();
      expect(v, closeTo(0.501, 0.01));
    });

    test('result never leaves 0.0..1.0', () {
      final double loud = const ReplayGain(trackGainDb: 60.0).linearVolume();
      final double quiet = const ReplayGain(trackGainDb: -120.0).linearVolume();
      expect(loud, inInclusiveRange(0.0, 1.0));
      expect(quiet, inInclusiveRange(0.0, 1.0));
    });
  });

  group('ReplayGain mode selection', () {
    const both = ReplayGain(
      trackGainDb: -8.0,
      trackPeak: 0.99,
      albumGainDb: -5.0,
      albumPeak: 0.95,
    );

    test('track mode prefers track gain', () {
      expect(both.gainDbFor(ReplayGainMode.track), -8.0);
      expect(both.peakFor(ReplayGainMode.track), 0.99);
    });

    test('album mode prefers album gain', () {
      expect(both.gainDbFor(ReplayGainMode.album), -5.0);
      expect(both.peakFor(ReplayGainMode.album), 0.95);
    });

    test('album mode falls back to track gain when album gain is missing', () {
      const trackOnly = ReplayGain(trackGainDb: -7.0, trackPeak: 0.9);
      expect(trackOnly.gainDbFor(ReplayGainMode.album), -7.0);
      expect(trackOnly.peakFor(ReplayGainMode.album), 0.9);
    });

    test('track mode falls back to album gain when track gain is missing', () {
      const albumOnly = ReplayGain(albumGainDb: -4.0, albumPeak: 0.92);
      expect(albumOnly.gainDbFor(ReplayGainMode.track), -4.0);
      expect(albumOnly.peakFor(ReplayGainMode.track), 0.92);
    });
  });

  group('ReplayGain value semantics', () {
    test('isEmpty reflects absence of any gain', () {
      expect(ReplayGain.none.isEmpty, isTrue);
      expect(const ReplayGain(trackPeak: 0.9).isEmpty, isTrue);
      expect(const ReplayGain(trackGainDb: -3.0).isEmpty, isFalse);
      expect(const ReplayGain(albumGainDb: -3.0).isEmpty, isFalse);
    });

    test('equality and hashCode are value-based', () {
      const a = ReplayGain(trackGainDb: -6.0, trackPeak: 0.9);
      const b = ReplayGain(trackGainDb: -6.0, trackPeak: 0.9);
      const c = ReplayGain(trackGainDb: -7.0, trackPeak: 0.9);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });
}
