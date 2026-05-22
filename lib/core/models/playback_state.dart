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
    this.position = Duration.zero,
    this.duration = Duration.zero,
  });

  static const PlaybackState idle = PlaybackState();

  final PlaybackStatus status;
  final Track? currentTrack;
  final Duration position;
  final Duration duration;

  bool get isPlaying => status == PlaybackStatus.playing;
  bool get hasTrack => currentTrack != null;

  PlaybackState copyWith({
    PlaybackStatus? status,
    Track? currentTrack,
    Duration? position,
    Duration? duration,
  }) {
    return PlaybackState(
      status: status ?? this.status,
      currentTrack: currentTrack ?? this.currentTrack,
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
          other.position == position &&
          other.duration == duration);

  @override
  int get hashCode =>
      Object.hash(status, currentTrack, position, duration);
}
