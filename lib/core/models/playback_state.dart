import 'package:flutter/foundation.dart';

import 'playback_source.dart';
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
    this.hasPrevious = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.source,
    this.errorMessage,
  });

  static const PlaybackState idle = PlaybackState();

  final PlaybackStatus status;
  final Track? currentTrack;

  /// Where [currentTrack]'s audio is coming from (local file, direct stream, or
  /// offline cache), as decided by the resolver at play time. Null until a track
  /// resolves, and cleared when playback stops or errors — so the UI only shows
  /// a source badge for audio actually loaded.
  final PlaybackSource? source;

  /// Tracks queued to play after [currentTrack], in play order. Empty when the
  /// queue holds only the current track.
  final List<Track> upNext;

  /// Whether a previous track exists to step back to. Stored as a flag (unlike
  /// [hasNext], which reads off [upNext]) because the state carries no played
  /// history — the controller derives it from the queue's current position.
  final bool hasPrevious;

  final Duration position;
  final Duration duration;

  /// A friendly, secret-free explanation shown when [status] is
  /// [PlaybackStatus.error]. Deliberately *not* carried by [copyWith]: it is set
  /// only on a freshly built error state and clears on the next state change, so
  /// a stale message can never ride along onto a later playing/paused state.
  final String? errorMessage;

  bool get isPlaying => status == PlaybackStatus.playing;
  bool get hasTrack => currentTrack != null;
  bool get hasNext => upNext.isNotEmpty;

  PlaybackState copyWith({
    PlaybackStatus? status,
    Track? currentTrack,
    List<Track>? upNext,
    bool? hasPrevious,
    Duration? position,
    Duration? duration,
    PlaybackSource? source,
  }) {
    return PlaybackState(
      status: status ?? this.status,
      currentTrack: currentTrack ?? this.currentTrack,
      upNext: upNext ?? this.upNext,
      hasPrevious: hasPrevious ?? this.hasPrevious,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      source: source ?? this.source,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlaybackState &&
          other.status == status &&
          other.currentTrack == currentTrack &&
          listEquals(other.upNext, upNext) &&
          other.hasPrevious == hasPrevious &&
          other.position == position &&
          other.duration == duration &&
          other.source == source &&
          other.errorMessage == errorMessage);

  @override
  int get hashCode {
    return Object.hash(
      status,
      currentTrack,
      Object.hashAll(upNext),
      hasPrevious,
      position,
      duration,
      source,
      errorMessage,
    );
  }
}
