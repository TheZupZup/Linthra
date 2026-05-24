import 'dart:math';

import 'package:flutter/foundation.dart';

import 'track.dart';

/// An immutable ordered list of tracks plus a pointer to the one playing now.
///
/// This is the pure queue model the [PlaybackController] keeps behind its
/// state. Every mutation returns a new instance, so transitions are trivial to
/// test in isolation — no audio engine required.
///
/// Shuffle lives here too: [tracks] is always the *effective* play order, so
/// `current`/`upNext`/`next`/`previous` never need to know about shuffle. When
/// shuffled, [originalOrder] remembers the pre-shuffle order so [unshuffled] can
/// restore it with the current track kept in place.
@immutable
class PlaybackQueue {
  const PlaybackQueue({
    this.tracks = const <Track>[],
    this.currentIndex = -1,
    this.originalOrder,
  });

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

  /// The play order before shuffle was applied, or null when not shuffled.
  /// Carried so [unshuffled] can restore the original order; never read by the
  /// normal playback getters, which always work off the effective [tracks].
  final List<Track>? originalOrder;

  /// Whether the queue is currently in shuffled order.
  bool get isShuffled => originalOrder != null;

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
    return PlaybackQueue(
      tracks: tracks,
      currentIndex: currentIndex + 1,
      originalOrder: originalOrder,
    );
  }

  /// Steps back to the previous track. Returns this queue unchanged when the
  /// current track is the first, so callers can branch on [hasPrevious].
  PlaybackQueue previous() {
    if (!hasPrevious) return this;
    return PlaybackQueue(
      tracks: tracks,
      currentIndex: currentIndex - 1,
      originalOrder: originalOrder,
    );
  }

  /// Wraps back to the first track in the effective order, keeping the queue
  /// (and its shuffle) intact. Used by repeat-all when the last track finishes.
  PlaybackQueue restarted() {
    if (isEmpty) return this;
    return PlaybackQueue(
      tracks: tracks,
      currentIndex: 0,
      originalOrder: originalOrder,
    );
  }

  /// Inserts [track] immediately after the current one ("play next"). With an
  /// empty queue it becomes the current track. When shuffled, the track is also
  /// appended to [originalOrder] so it survives a later unshuffle.
  PlaybackQueue enqueueNext(Track track) {
    if (current == null) return PlaybackQueue.single(track);
    final updated = List<Track>.of(tracks)..insert(currentIndex + 1, track);
    final updatedOriginal = originalOrder == null
        ? null
        : (List<Track>.of(originalOrder!)..add(track));
    return PlaybackQueue(
      tracks: updated,
      currentIndex: currentIndex,
      originalOrder: updatedOriginal,
    );
  }

  /// Drops every upcoming track, keeping only the one playing now. The result
  /// is a plain single-track queue (no shuffle to restore).
  PlaybackQueue cleared() {
    final track = current;
    if (track == null) return empty;
    return PlaybackQueue.single(track);
  }

  /// Returns a shuffled copy: the current track stays current (moved to the
  /// front so playback continues uninterrupted) and every other track is
  /// randomised after it. The pre-shuffle order is remembered in
  /// [originalOrder]. A no-op on an empty queue, and re-shuffling keeps the
  /// first remembered order so [unshuffled] still restores the true original.
  PlaybackQueue shuffled([Random? random]) {
    final track = current;
    if (track == null) return this;
    final original = originalOrder ?? List<Track>.of(tracks);
    final rest = List<Track>.of(tracks)..removeAt(currentIndex);
    rest.shuffle(random);
    return PlaybackQueue(
      tracks: <Track>[track, ...rest],
      currentIndex: 0,
      originalOrder: original,
    );
  }

  /// Restores the pre-shuffle order, keeping the current track current. A no-op
  /// when the queue was not shuffled.
  PlaybackQueue unshuffled() {
    final original = originalOrder;
    if (original == null) return this;
    final track = current;
    final index = track == null ? -1 : original.indexOf(track);
    return PlaybackQueue(
      tracks: List<Track>.of(original),
      currentIndex: index < 0 ? (original.isEmpty ? -1 : 0) : index,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlaybackQueue &&
          other.currentIndex == currentIndex &&
          listEquals(other.tracks, tracks) &&
          listEquals(other.originalOrder, originalOrder));

  @override
  int get hashCode => Object.hash(
        currentIndex,
        Object.hashAll(tracks),
        originalOrder == null ? null : Object.hashAll(originalOrder!),
      );
}
