import 'package:flutter/foundation.dart';

import 'track.dart';

/// An immutable ordered list of tracks plus a pointer to the one playing now.
///
/// This is the pure queue model the [PlaybackController] keeps behind its
/// state. Every mutation returns a new instance, so transitions are trivial to
/// test in isolation — no audio engine required.
@immutable
class PlaybackQueue {
  const PlaybackQueue({this.tracks = const <Track>[], this.currentIndex = -1});

  static const PlaybackQueue empty = PlaybackQueue();

  /// Builds a queue from [tracks], starting playback at [startIndex] (clamped
  /// into range). An empty list yields the [empty] queue.
  factory PlaybackQueue.of(List<Track> tracks, {int startIndex = 0}) {
    if (tracks.isEmpty) return empty;
    final index = startIndex.clamp(0, tracks.length - 1);
    return PlaybackQueue(tracks: List<Track>.of(tracks), currentIndex: index);
  }

  /// A queue holding a single track as the current one.
  factory PlaybackQueue.single(Track track) =>
      PlaybackQueue(tracks: <Track>[track], currentIndex: 0);

  /// All tracks in play order. Index 0 is the start of the queue, not
  /// necessarily the current track (see [currentIndex]).
  final List<Track> tracks;

  /// Position of the current track within [tracks], or -1 when nothing is
  /// queued.
  final int currentIndex;

  /// The track playing now, or null when the queue is empty.
  Track? get current {
    if (currentIndex < 0 || currentIndex >= tracks.length) return null;
    return tracks[currentIndex];
  }

  /// The tracks queued after the current one, in play order.
  List<Track> get upNext {
    if (currentIndex < 0 || currentIndex >= tracks.length) {
      return const <Track>[];
    }
    return tracks.sublist(currentIndex + 1);
  }

  /// Whether there is at least one track after the current one.
  bool get hasNext => currentIndex >= 0 && currentIndex < tracks.length - 1;

  /// Whether there is at least one track before the current one.
  bool get hasPrevious => currentIndex > 0;

  bool get isEmpty => current == null;

  /// Advances to the next track. Returns this queue unchanged when there is no
  /// next track, so callers can branch on [hasNext] before playing.
  PlaybackQueue next() {
    if (!hasNext) return this;
    return PlaybackQueue(tracks: tracks, currentIndex: currentIndex + 1);
  }

  /// Steps back to the previous track. Returns this queue unchanged when the
  /// current track is the first, so callers can branch on [hasPrevious].
  PlaybackQueue previous() {
    if (!hasPrevious) return this;
    return PlaybackQueue(tracks: tracks, currentIndex: currentIndex - 1);
  }

  /// Inserts [track] immediately after the current one ("play next"). With an
  /// empty queue it becomes the current track.
  PlaybackQueue enqueueNext(Track track) {
    if (current == null) return PlaybackQueue.single(track);
    final updated = List<Track>.of(tracks)..insert(currentIndex + 1, track);
    return PlaybackQueue(tracks: updated, currentIndex: currentIndex);
  }

  /// Drops every upcoming track, keeping only the one playing now.
  PlaybackQueue cleared() {
    final track = current;
    if (track == null) return empty;
    return PlaybackQueue.single(track);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlaybackQueue &&
          other.currentIndex == currentIndex &&
          listEquals(other.tracks, tracks));

  @override
  int get hashCode => Object.hash(currentIndex, Object.hashAll(tracks));
}
