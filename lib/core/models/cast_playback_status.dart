import 'package:flutter/foundation.dart';

import 'playback_state.dart';

/// A snapshot of what a cast receiver is doing, reported back from the session.
///
/// This is the cast-side mirror of the playback fields in [PlaybackState]: the
/// receiver owns the audio while casting, so its position/status/duration come
/// from here (parsed from the receiver's `MEDIA_STATUS`) rather than from the
/// local engine. The `ActivePlaybackController` folds these onto the unified
/// state the UI renders, keeping the now-playing screen, mini-player, and lyrics
/// in step with the device instead of the (paused) local engine.
///
/// It deliberately reuses [PlaybackStatus] so the router needs no second status
/// vocabulary; it carries no track identity (the queue stays owned locally) and
/// never any URL or token.
@immutable
class CastPlaybackStatus {
  const CastPlaybackStatus({
    this.status = PlaybackStatus.idle,
    this.position = Duration.zero,
    this.duration = Duration.zero,
  });

  /// Nothing loaded on the receiver yet.
  static const CastPlaybackStatus idle = CastPlaybackStatus();

  final PlaybackStatus status;
  final Duration position;
  final Duration duration;

  bool get isPlaying => status == PlaybackStatus.playing;

  CastPlaybackStatus copyWith({
    PlaybackStatus? status,
    Duration? position,
    Duration? duration,
  }) {
    return CastPlaybackStatus(
      status: status ?? this.status,
      position: position ?? this.position,
      duration: duration ?? this.duration,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CastPlaybackStatus &&
          other.status == status &&
          other.position == position &&
          other.duration == duration);

  @override
  int get hashCode => Object.hash(status, position, duration);
}
