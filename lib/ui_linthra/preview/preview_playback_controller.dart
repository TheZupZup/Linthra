import 'dart:async';

import '../../core/models/playback_state.dart';
import '../../core/models/repeat_mode.dart';
import '../../core/models/track.dart';
import '../../core/services/playback_controller.dart';

/// A tiny, in-memory [PlaybackController] used **only** by the Now Playing UI
/// preview (`now_playing_preview_main.dart`).
///
/// It never touches `just_audio`, the network, or any music provider — it simply
/// holds a [PlaybackState] you hand it and emits it to the screen, plus enough
/// interactivity (play/pause, seek, shuffle, repeat, light queue edits) that the
/// real Now Playing widgets feel alive while you tweak the design. It is not used
/// by the shipping app and has no effect on real playback.
class PreviewPlaybackController implements PlaybackController {
  PreviewPlaybackController(PlaybackState initial) : _state = initial;

  final StreamController<PlaybackState> _states =
      StreamController<PlaybackState>.broadcast();
  PlaybackState _state;

  @override
  PlaybackState get state => _state;

  @override
  Stream<PlaybackState> get stateStream => _states.stream;

  void _emit(PlaybackState next) {
    _state = next;
    _states.add(next);
  }

  /// Swaps in a different sample state. Used by the preview's sample picker.
  void load(PlaybackState sample) => _emit(sample);

  @override
  Future<void> play() async {
    _emit(_state.copyWith(status: PlaybackStatus.playing));
  }

  @override
  Future<void> pause() async {
    _emit(_state.copyWith(status: PlaybackStatus.paused));
  }

  @override
  Future<void> seek(Duration position) async {
    _emit(_state.copyWith(position: position));
  }

  @override
  void setShuffleEnabled(bool enabled) {
    _emit(_state.copyWith(shuffleEnabled: enabled));
  }

  @override
  void setRepeatMode(RepeatMode mode) {
    _emit(_state.copyWith(repeatMode: mode));
  }

  @override
  void clearQueue() {
    _emit(_state.copyWith(upNext: const <Track>[]));
  }

  @override
  void removeFromQueue(int upNextIndex) {
    if (upNextIndex < 0 || upNextIndex >= _state.upNext.length) return;
    final List<Track> next = List<Track>.of(_state.upNext)
      ..removeAt(upNextIndex);
    _emit(_state.copyWith(upNext: next));
  }

  @override
  void reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _state.upNext.length) return;
    final List<Track> next = List<Track>.of(_state.upNext);
    final Track moved = next.removeAt(oldIndex);
    next.insert(newIndex.clamp(0, next.length), moved);
    _emit(_state.copyWith(upNext: next));
  }

  // ── The rest are inert: the preview never changes tracks or starts real
  //    playback, so these are deliberate no-ops. ───────────────────────────────

  @override
  Future<void> playTrack(Track track) async {}

  @override
  Future<void> playTracks(List<Track> tracks, {int startIndex = 0}) async {}

  @override
  void playNext(Track track) {}

  @override
  void addToQueue(Track track) {}

  @override
  Future<void> playFromQueue(int upNextIndex) async {}

  @override
  Future<void> playFromHistory(int previousIndex) async {}

  @override
  Future<void> skipToNext() async {}

  @override
  Future<void> skipToPrevious() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    await _states.close();
  }
}
