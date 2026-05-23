import 'package:flutter/foundation.dart';

import 'track.dart';

/// High-level playback status, deliberately decoupled from any audio package.
enum PlaybackStatus { idle, loading, playing, paused, completed, error }

/// An immutable snapshot of what the player is doing. The UI renders from this
/// instead of reaching into the audio backend, which keeps playback internals
/// swappable (just_audio today, audio_service/MPRIS later).
class PlaybackState {
  const PlaybackState({
    this.status = PlaybackStatus.idle,
    this.currentTrack,
    this.upNext = const <Track>[],
    this.position = Duration.zero,
    this.duration = Duration.zero,
  });

  static const PlaybackState idle = PlaybackState();

  final PlaybackStatus status;
  final Track? currentTrack;

  /// Tracks queued to play after [currentTrack], in play order. Empty when the
  /// queue holds only the current track.
  final List<Track> upNext;

  final Duration position;
  final Duration duration;

  bool get isPlaying => status == PlaybackStatus.playing;
  bool get hasTrack => currentTrack != null;
  bool get hasNext => upNext.isNotEmpty;

  PlaybackState copyWith({
    PlaybackStatus? status,
    Track? currentTrack,
    List<Track>? upNext,
    Duration? position,
    Duration? duration,
  }) {
    return PlaybackState(
      status: status ?? this.status,
      currentTrack: currentTrack ?? this.currentTrack,
      upNext: upNext ?? this.upNext,
      position: position ?? this.position,
      duration: duration ?? this.duration,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlaybackState &&
          other.status == status &&
          other.currentTrack == currentTrack &&
          listEquals(other.upNext, upNext) &&
          other.position == position &&
          other.duration == duration);

  @override
  int get hashCode => Object.hash(
        status,
        currentTrack,
        Object.hashAll(upNext),
        position,
        duration,
      );
}
