import 'dart:math';

import '../../core/models/track.dart';
import '../../core/services/playback_controller.dart';

/// Plays [tracks] in shuffle mode, starting from a song picked at random.
///
/// What every Shuffle button (album, artist, playlist, smart mix) means.
/// Turning shuffle on and playing the collection from its start did not mean
/// that: a shuffled queue keeps the song it starts on first, so every shuffle
/// opened with the collection's first song and only shuffled the rest.
///
/// [random] is for tests.
Future<void> playShuffled(
  PlaybackController controller,
  List<Track> tracks, {
  Random? random,
}) {
  if (tracks.isEmpty) return Future<void>.value();
  controller.setShuffleEnabled(true);
  return controller.playTracks(
    tracks,
    startIndex: (random ?? Random()).nextInt(tracks.length),
  );
}
