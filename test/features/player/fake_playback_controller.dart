import 'dart:async';

import 'package:sonara/core/models/playback_state.dart';
import 'package:sonara/core/models/track.dart';
import 'package:sonara/core/services/playback_controller.dart';

/// In-memory [PlaybackController] for widget/provider tests.
///
/// Records the calls it receives and lets a test push arbitrary
/// [PlaybackState]s, so playback flows can be exercised without `just_audio` or
/// any platform plugin.
class FakePlaybackController implements PlaybackController {
  FakePlaybackController({PlaybackState initial = PlaybackState.idle})
      : _state = initial;

  final StreamController<PlaybackState> _states =
      StreamController<PlaybackState>.broadcast();
  PlaybackState _state;

  final List<Track> playedTracks = <Track>[];
  int playCount = 0;
  int pauseCount = 0;
  int stopCount = 0;
  final List<Duration> seeks = <Duration>[];

  /// Pushes [next] to listeners and updates the synchronous [state].
  void emit(PlaybackState next) {
    _state = next;
    _states.add(next);
  }

  @override
  PlaybackState get state => _state;

  @override
  Stream<PlaybackState> get stateStream => _states.stream;

  @override
  Future<void> playTrack(Track track) async {
    playedTracks.add(track);
    emit(PlaybackState(status: PlaybackStatus.playing, currentTrack: track));
  }

  @override
  Future<void> play() async {
    playCount++;
  }

  @override
  Future<void> pause() async {
    pauseCount++;
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
  }

  @override
  Future<void> dispose() async {
    await _states.close();
  }
}
