import 'package:flutter/foundation.dart';

import 'playback_failure.dart';
import 'playback_source.dart';
import 'repeat_mode.dart';
import 'track.dart';

/// High-level playback status, deliberately decoupled from any audio package.
///
/// [loading] is the initial *preparing* state (resolving + opening a source);
/// [buffering] is a distinct mid-playback re-buffer (the engine wants to play but
/// is waiting for more data over the network). [reconnecting] is a bounded
/// mid-stream recovery after a network drop (re-resolving a fresh stream URL),
/// shown separately from plain buffering and from a permanent [error]. Keeping
/// them apart lets the UI show "Buffering…" / "Reconnecting…" / Retry instead of
/// a frozen player or a misleading permanent-failure look.
enum PlaybackStatus {
  idle,
  loading,
  buffering,
  reconnecting,
  playing,
  paused,
  completed,
  error,
}

/// An immutable snapshot of what the player is doing. The UI renders from this
/// instead of reaching into the audio backend, which keeps playback internals
/// swappable (just_audio today, and read by the audio_service and MPRIS
/// sessions rather than replaced by them).
class PlaybackState {
  const PlaybackState({
    this.status = PlaybackStatus.idle,
    this.currentTrack,
    this.upNext = const <Track>[],
    this.previous = const <Track>[],
    this.hasPrevious = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.source,
    this.shuffleEnabled = false,
    this.repeatMode = RepeatMode.off,
    this.volume = 1.0,
    this.muted = false,
    this.interruptedByTransientFocus = false,
    this.failure,
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

  /// Tracks played before [currentTrack], in play order — the queue's history,
  /// shown in the Queue screen so the listener can step back to one. Empty when
  /// the current track is the first. Carries only catalog [Track]s (id, title,
  /// artist, album, artwork) — never a resolved/authenticated stream URL.
  final List<Track> previous;

  /// Whether a previous track exists to step back to. Kept as a flag the
  /// transport controls read directly; it mirrors `previous.isNotEmpty` (both
  /// are set together by the controller from the queue's current position).
  final bool hasPrevious;

  final Duration position;
  final Duration duration;

  /// Whether shuffle is on. A playback *mode* owned by the controller, so it
  /// persists across track changes and is re-applied to any new queue — not a
  /// property of a single track. The UI renders the shuffle button from this.
  final bool shuffleEnabled;

  /// The active repeat behaviour (off / repeat all / repeat one). Like
  /// [shuffleEnabled] this is a controller-owned mode the UI renders the repeat
  /// button from; the controller consults it when a track finishes.
  final RepeatMode repeatMode;

  /// The listener's own playback volume, 0.0 (silent) to 1.0 (full).
  ///
  /// A controller-owned mode like [shuffleEnabled] and [repeatMode], and the
  /// *user's* level — not the engine's. What the engine is actually set to also
  /// folds in ReplayGain normalization and any audio-focus duck, so the two are
  /// deliberately not the same number: those are automatic attenuations the
  /// listener never asked for and must not see their slider move for.
  ///
  /// Kept out of range by nothing: every writer goes through
  /// [PlaybackState.sanitizeVolume], so a stored, remote (MPRIS), or arithmetic
  /// value can never land here out of range or as NaN.
  final double volume;

  /// Whether playback is muted. Independent of [volume], which keeps the level
  /// to come back to — so unmute restores exactly what was playing before.
  final bool muted;

  /// Whether playback is paused *only* because another app is holding a
  /// transient audio focus (a call, a navigation prompt, a voice interaction)
  /// and Linthra intends to resume the moment focus comes back.
  ///
  /// This is the signal the Android media session uses to keep its foreground
  /// service (and the CPU wake lock that comes with it) alive across such a
  /// pause: the on-device focus handling runs in the Flutter isolate, so a
  /// demoted service can be frozen by the OS and never see the `AUDIOFOCUS_GAIN`
  /// that ends the interruption. It is set only while a transient loss that
  /// interrupted *active* playback is outstanding, and cleared on the regain, on
  /// a permanent loss, on any explicit user transport, and once the controller's
  /// bounded hold window expires — so an ordinary user pause still demotes the
  /// service and holds no wake lock. See
  /// `JustAudioPlaybackController._armTransientResume` and
  /// `LinthraAudioHandler._isSessionPlaying`.
  final bool interruptedByTransientFocus;

  /// Why the current track isn't playing and what the listener can do about it,
  /// set when [status] is [PlaybackStatus.error]. Deliberately *not* carried by
  /// [copyWith]: it is set only on a freshly built error state and clears on the
  /// next state change, so a stale failure can never ride along onto a later
  /// playing/paused state.
  ///
  /// The controller decides the offered recoveries when it builds this, because
  /// only it knows whether the song has another provider copy and whether the
  /// bounded retry budget is spent, so the UI renders the actions rather than
  /// deciding which ones are valid.
  final PlaybackFailure? failure;

  /// The failure's friendly, secret-free message, for the surfaces (and tests)
  /// that only want the sentence. Null when nothing has failed.
  String? get errorMessage => failure?.message;

  /// The level actually heard: zero while muted, [volume] otherwise. What a
  /// volume UI (and MPRIS' `Volume`) should show, so muted always reads as
  /// silent without losing the level unmute restores.
  double get effectiveVolume => muted ? 0.0 : volume;

  bool get isPlaying => status == PlaybackStatus.playing;
  bool get hasTrack => currentTrack != null;
  bool get hasNext => upNext.isNotEmpty;

  /// Whether a mid-playback re-buffer is in progress (engine waiting on data),
  /// including a bounded network reconnect attempt.
  bool get isBuffering =>
      status == PlaybackStatus.buffering ||
      status == PlaybackStatus.reconnecting;

  /// Whether a temporary network drop is being recovered (fresh URL resolve).
  bool get isReconnecting => status == PlaybackStatus.reconnecting;

  /// Whether the player is preparing, re-buffering, or reconnecting — i.e.
  /// working, not idle and not steadily playing. The mini-player shows a
  /// spinner for this so it never looks frozen during a network stall.
  bool get isBusy =>
      status == PlaybackStatus.loading ||
      status == PlaybackStatus.buffering ||
      status == PlaybackStatus.reconnecting;

  PlaybackState copyWith({
    PlaybackStatus? status,
    Track? currentTrack,
    List<Track>? upNext,
    List<Track>? previous,
    bool? hasPrevious,
    Duration? position,
    Duration? duration,
    PlaybackSource? source,
    bool? shuffleEnabled,
    RepeatMode? repeatMode,
    double? volume,
    bool? muted,
    bool? interruptedByTransientFocus,
  }) {
    return PlaybackState(
      status: status ?? this.status,
      currentTrack: currentTrack ?? this.currentTrack,
      upNext: upNext ?? this.upNext,
      previous: previous ?? this.previous,
      hasPrevious: hasPrevious ?? this.hasPrevious,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      source: source ?? this.source,
      shuffleEnabled: shuffleEnabled ?? this.shuffleEnabled,
      repeatMode: repeatMode ?? this.repeatMode,
      volume: volume ?? this.volume,
      muted: muted ?? this.muted,
      interruptedByTransientFocus:
          interruptedByTransientFocus ?? this.interruptedByTransientFocus,
    );
  }

  /// Returns this state with [interruptedByTransientFocus] set to [value].
  ///
  /// Unlike [copyWith] this preserves [failure], because it re-stamps a state
  /// the controller has *already* built rather than deriving a new one: the
  /// focus hold is orthogonal to why playback stopped, so an error state must
  /// keep its failure when the flag is stamped onto it.
  PlaybackState withTransientFocusInterruption(bool value) {
    if (value == interruptedByTransientFocus) return this;
    return PlaybackState(
      status: status,
      currentTrack: currentTrack,
      upNext: upNext,
      previous: previous,
      hasPrevious: hasPrevious,
      position: position,
      duration: duration,
      source: source,
      shuffleEnabled: shuffleEnabled,
      repeatMode: repeatMode,
      volume: volume,
      muted: muted,
      interruptedByTransientFocus: value,
      failure: failure,
    );
  }

  /// Returns this state carrying [volume] and [muted].
  ///
  /// Like [withTransientFocusInterruption] this re-stamps a state the
  /// controller has already built, so [failure] survives: the volume is
  /// orthogonal to why playback stopped. Controllers stamp every emission
  /// through here, so no emit path can publish a stale level — including the
  /// paths that build a fresh state rather than copying the last one.
  PlaybackState withVolume({required double volume, required bool muted}) {
    if (volume == this.volume && muted == this.muted) return this;
    return PlaybackState(
      status: status,
      currentTrack: currentTrack,
      upNext: upNext,
      previous: previous,
      hasPrevious: hasPrevious,
      position: position,
      duration: duration,
      source: source,
      shuffleEnabled: shuffleEnabled,
      repeatMode: repeatMode,
      volume: volume,
      muted: muted,
      interruptedByTransientFocus: interruptedByTransientFocus,
      failure: failure,
    );
  }

  /// Forces [value] into the only range a volume may ever hold: 0.0–1.0.
  ///
  /// Every path that can produce a volume from outside the app — a persisted
  /// preference, an MPRIS client, a scroll/keyboard step's arithmetic — goes
  /// through here, so an out-of-range or non-finite value is corrected at the
  /// edge instead of reaching the audio engine. A non-finite value has no
  /// sensible clamp, so it falls back to full volume: the level the app plays
  /// at with no preference at all.
  static double sanitizeVolume(double value) =>
      value.isFinite ? value.clamp(0.0, 1.0) : 1.0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlaybackState &&
          other.status == status &&
          other.currentTrack == currentTrack &&
          listEquals(other.upNext, upNext) &&
          listEquals(other.previous, previous) &&
          other.hasPrevious == hasPrevious &&
          other.position == position &&
          other.duration == duration &&
          other.source == source &&
          other.shuffleEnabled == shuffleEnabled &&
          other.repeatMode == repeatMode &&
          other.volume == volume &&
          other.muted == muted &&
          other.interruptedByTransientFocus == interruptedByTransientFocus &&
          other.failure == failure);

  @override
  int get hashCode {
    return Object.hash(
      status,
      currentTrack,
      Object.hashAll(upNext),
      Object.hashAll(previous),
      hasPrevious,
      position,
      duration,
      source,
      shuffleEnabled,
      repeatMode,
      volume,
      muted,
      interruptedByTransientFocus,
      failure,
    );
  }
}
