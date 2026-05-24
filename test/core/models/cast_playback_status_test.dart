import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cast_playback_status.dart';
import 'package:linthra/core/models/playback_state.dart';

void main() {
  group('CastPlaybackStatus', () {
    test('idle is the empty default', () {
      const status = CastPlaybackStatus.idle;
      expect(status.status, PlaybackStatus.idle);
      expect(status.position, Duration.zero);
      expect(status.duration, Duration.zero);
      expect(status.isPlaying, isFalse);
    });

    test('isPlaying reflects the status', () {
      const playing = CastPlaybackStatus(status: PlaybackStatus.playing);
      const paused = CastPlaybackStatus(status: PlaybackStatus.paused);
      expect(playing.isPlaying, isTrue);
      expect(paused.isPlaying, isFalse);
    });

    test('copyWith replaces only the given fields', () {
      const base = CastPlaybackStatus(
        status: PlaybackStatus.playing,
        position: Duration(seconds: 5),
        duration: Duration(minutes: 3),
      );
      final next = base.copyWith(position: const Duration(seconds: 9));
      expect(next.status, PlaybackStatus.playing);
      expect(next.position, const Duration(seconds: 9));
      expect(next.duration, const Duration(minutes: 3));
    });

    test('equality compares status, position, and duration', () {
      const a = CastPlaybackStatus(
        status: PlaybackStatus.playing,
        position: Duration(seconds: 5),
        duration: Duration(minutes: 3),
      );
      const b = CastPlaybackStatus(
        status: PlaybackStatus.playing,
        position: Duration(seconds: 5),
        duration: Duration(minutes: 3),
      );
      const different = CastPlaybackStatus(
        status: PlaybackStatus.paused,
        position: Duration(seconds: 5),
        duration: Duration(minutes: 3),
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(different)));
    });
  });
}
