import '../models/playback_state.dart';
import '../models/repeat_mode.dart';
import '../models/track.dart';

/// The tracks the controller is going to play after the current one, in the
/// order it will play them, at most [count] of them.
///
/// This is the one definition of "what's coming" that automatic caching warms,
/// so the cache predicts the controller instead of guessing:
///
///  * [PlaybackState.upNext] is already the *effective* order, so a shuffled
///    queue yields its shuffled order. Nothing here reshuffles.
///  * Repeat-all wraps: once up-next runs out the queue restarts from its first
///    track in the same order, which is [PlaybackState.previous].
///  * Repeat-one yields nothing, since the current track loops and nothing
///    else plays soon.
///  * A track listed twice (or the current track coming round again) is only
///    warmed once.
///
/// Stops as soon as it has [count] tracks, so the length of the queue barely
/// matters; only a long run of the same track repeated is walked past.
List<Track> upcomingTracks(PlaybackState state, {required int count}) {
  final Track? current = state.currentTrack;
  if (count <= 0 || current == null) return const <Track>[];
  if (state.repeatMode == RepeatMode.one) return const <Track>[];
  final List<Track> upcoming = <Track>[];
  final Set<String> seen = <String>{current.uri};
  bool take(List<Track> source) {
    for (final Track track in source) {
      if (upcoming.length >= count) return false;
      if (seen.add(track.uri)) upcoming.add(track);
    }
    return upcoming.length < count;
  }

  if (take(state.upNext) && state.repeatMode == RepeatMode.all) {
    take(state.previous);
  }
  return upcoming;
}

/// Whether two playback states describe the same *look-ahead work*: the same
/// track playing, the same modes, and the same first [ahead] entries of
/// up-next.
///
/// The services that warm something just ahead of playback (the remote stream
/// prebuffer, the media-session artwork prewarm) listen to the same unified
/// [PlaybackState] stream, which emits several times a second while playing.
/// Smart pre-cache compares its de-duplicated [upcomingTracks] window instead. Only a handful of those emissions change what there is to
/// warm; the rest are position ticks. This is the shared "did anything I care
/// about actually move?" test they gate on.
///
/// Two properties matter for battery, and both are deliberate:
///
///  * **It allocates nothing.** These services used to fingerprint a state by
///    building a string out of the up-next uris on *every* emission — several
///    times a second, for the whole length of a screen-off session, over a
///    queue that can hold the user's entire library. The comparison below walks
///    at most [ahead] entries and, on the overwhelmingly common position tick,
///    stops at the first `identical` check: [PlaybackState.copyWith] hands the
///    same list objects to the new state, so an unchanged queue is provably
///    unchanged in constant time.
///  * **It stops at [ahead].** A change further down a long queue cannot affect
///    what these services warm (they only ever look at the head of up-next), so
///    reacting to it would be pure work for no benefit.
///
/// A null state never matches, so a service's first emission always runs.
bool samePlaybackLookahead(
  PlaybackState? a,
  PlaybackState? b, {
  required int ahead,
}) {
  if (a == null || b == null) return false;
  if (identical(a, b)) return true;
  // Compared by uri, not by [Track] equality (bare id): a fallback that swaps
  // `jellyfin:101` for `subsonic:101` keeps the id but is a different copy to
  // warm.
  if (a.currentTrack?.uri != b.currentTrack?.uri) return false;
  if (a.shuffleEnabled != b.shuffleEnabled) return false;
  if (a.repeatMode != b.repeatMode) return false;
  return _sameHead(a.upNext, b.upNext, ahead);
}

/// Whether the first [ahead] entries of [a] and [b] are the same tracks in the
/// same order (a shorter list must match in full).
bool _sameHead(List<Track> a, List<Track> b, int ahead) {
  if (identical(a, b)) return true;
  final int countA = a.length < ahead ? a.length : ahead;
  final int countB = b.length < ahead ? b.length : ahead;
  if (countA != countB) return false;
  for (int i = 0; i < countA; i++) {
    if (a[i].uri != b[i].uri) return false;
  }
  return true;
}
