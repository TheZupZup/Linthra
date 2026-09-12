import 'dart:async';

import '../models/playback_failure.dart';
import '../models/playback_state.dart';
import '../models/repeat_mode.dart';
import '../models/track.dart';
import 'local_playback_controller.dart';

/// The on-device engine for a platform that does not have one yet.
///
/// Linthra's audio engine is `just_audio`, and `just_audio` ships no Linux
/// implementation. Rather than let the app reach a plugin that isn't there —
/// where a tap on a song produces a `MissingPluginException` from somewhere deep
/// in the engine, or worse, silence with no explanation — the desktop build gets
/// this: a controller that satisfies the whole [LocalPlaybackController]
/// contract and answers every playback request with one clear, deliberate error.
///
/// It is a placeholder with an expiry date. Linux audio playback is the next
/// piece of desktop work; when a real desktop backend lands, this class is
/// deleted and the platform selection in `localPlaybackControllerProvider`
/// points at that backend instead. Nothing else has to change, because the UI
/// only ever knew [PlaybackController].
///
/// What it deliberately does *not* do is pretend. It keeps no queue, reports no
/// position, and never claims [PlaybackStatus.playing] — a fake queue that never
/// plays is harder to reason about than an honest failure, and it would let a
/// broken desktop build look healthy in a screenshot.
class UnsupportedPlaybackController implements LocalPlaybackController {
  UnsupportedPlaybackController({String? reason})
      : _reason = reason ?? defaultReason;

  /// The message surfaced on the now-playing screen when a track is requested.
  /// Deliberately plain and user-facing: someone running the desktop build
  /// should learn *why* nothing played, not see a stack trace.
  static const String defaultReason =
      'Audio playback is not available on this platform yet.';

  final String _reason;

  /// The failure every refusal publishes: this host has no audio backend, so
  /// nothing here is retryable and no other provider copy would fare better.
  /// Skipping is left to the queue, which [_refuse] fills in.
  late final PlaybackFailure _failure = PlaybackFailure(
    kind: PlaybackFailureKind.unplayableMedia,
    message: _reason,
  );
  final StreamController<PlaybackState> _states =
      StreamController<PlaybackState>.broadcast();

  PlaybackState _state = PlaybackState.idle;
  double _volume = 1.0;
  bool _muted = false;
  bool _disposed = false;

  @override
  PlaybackState get state => _state;

  @override
  Stream<PlaybackState> get stateStream => _states.stream;

  /// Why playback is unavailable. Read by tests and, later, by diagnostics.
  String get reason => _reason;

  // Any request to *make sound* lands here: remember which track was asked for
  // (so the UI can name it) and publish the explicit failure.
  void _refuse(Track? track) {
    _emit(PlaybackState(
      status: PlaybackStatus.error,
      currentTrack: track ?? _state.currentTrack,
      failure: _failure,
      shuffleEnabled: _state.shuffleEnabled,
      repeatMode: _state.repeatMode,
    ));
  }

  void _emit(PlaybackState next) {
    if (_disposed) return;
    // Stamped from one place, like the real engine's emit, so every path here
    // (including the refusals, which build a state from scratch) publishes the
    // listener's current level.
    final PlaybackState stamped =
        next.withVolume(volume: _volume, muted: _muted);
    if (identical(stamped, _state)) return;
    _state = stamped;
    _states.add(stamped);
  }

  @override
  Future<void> playTrack(Track track) async => _refuse(track);

  @override
  Future<void> playTracks(List<Track> tracks, {int startIndex = 0}) async {
    final bool inRange = startIndex >= 0 && startIndex < tracks.length;
    _refuse(inRange ? tracks[startIndex] : null);
  }

  @override
  void playNext(Track track) => _refuse(track);

  @override
  void addToQueue(Track track) => _refuse(track);

  @override
  Future<void> play() async => _refuse(null);

  @override
  Future<void> playFromQueue(int upNextIndex) async => _refuse(null);

  @override
  Future<void> playFromHistory(int previousIndex) async => _refuse(null);

  @override
  Future<void> skipToNext() async => _refuse(null);

  @override
  Future<void> skipToPrevious() async => _refuse(null);

  // There is nothing to recover *to* on a host with no audio engine, so the
  // recovery actions refuse exactly like play does rather than pretending to
  // try. The published failure offers neither, so the error UI shows neither.
  @override
  Future<void> retryCurrentTrack() async => _refuse(null);

  @override
  Future<void> tryAnotherSource() async => _refuse(null);

  // Everything below either has no audio to act on or is a mode the UI may set
  // before anything plays. These stay quiet no-ops so the settings and queue
  // screens behave normally instead of erroring at rest.

  @override
  void removeFromQueue(int upNextIndex) {}

  @override
  void reorderQueue(int oldIndex, int newIndex) {}

  @override
  void clearQueue() {}

  @override
  void setShuffleEnabled(bool enabled) {
    _emit(PlaybackState(
      status: _state.status,
      currentTrack: _state.currentTrack,
      failure: _state.failure,
      shuffleEnabled: enabled,
      repeatMode: _state.repeatMode,
    ));
  }

  @override
  void setRepeatMode(RepeatMode mode) {
    _emit(PlaybackState(
      status: _state.status,
      currentTrack: _state.currentTrack,
      failure: _state.failure,
      shuffleEnabled: _state.shuffleEnabled,
      repeatMode: mode,
    ));
  }

  // The listener's volume is real state even here: there is no engine to apply
  // it to, but remembering it (and reflecting it in the emitted state) keeps the
  // contract honest and means a host that later grows an engine starts at the
  // level the user chose rather than at full volume.

  @override
  void setVolume(double volume) {
    final double next = PlaybackState.sanitizeVolume(volume);
    final bool nextMuted = _muted && next <= 0.0;
    if (next == _volume && nextMuted == _muted) return;
    _volume = next;
    _muted = nextMuted;
    _emit(_state);
  }

  @override
  void setMuted(bool muted) {
    if (muted == _muted) return;
    _muted = muted;
    _emit(_state);
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> stop() async => _emit(PlaybackState.idle);

  // --- LocalPlaybackController: the cast-handoff and engine-lifecycle half ---
  //
  // There is no engine to silence or restore, so these are inert. `isSuspended`
  // stays false: reporting "suspended" would tell the cast controller a local
  // engine is being held back, which is not what is happening.

  @override
  bool get isSuspended => false;

  @override
  Future<void> suspend() async {}

  @override
  Future<void> resume({Duration at = Duration.zero, bool play = false}) async {}

  @override
  Future<void> restoreSession({
    required List<Track> tracks,
    int startIndex = 0,
    Duration position = Duration.zero,
    bool shuffleEnabled = false,
    RepeatMode repeatMode = RepeatMode.off,
    List<Track>? originalOrder,
  }) async {
    // No engine to load into; refuse with the same clear error as playTracks so
    // a persisted session on an unsupported host never pretends to restore.
    final bool inRange = startIndex >= 0 && startIndex < tracks.length;
    _refuse(inRange ? tracks[startIndex] : null);
  }

  @override
  Future<void> restartQueue() async {}

  @override
  void setVolumeNormalizationEnabled(bool enabled) {}

  @override
  void onAppBackgrounded() {}

  @override
  void onAppForegrounded() {}

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _states.close();
  }
}
