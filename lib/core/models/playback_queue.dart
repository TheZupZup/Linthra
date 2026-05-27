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

  /// The tracks played before the current one, in play order — the queue's
  /// history. Empty when the current track is the first (or the queue is
  /// empty). Lets the queue UI show where you've been without the controller
  /// carrying a separate history list. Named [history] (not `previous`) to
  /// avoid clashing with the [previous] step-back method.
  List<Track> get history {
    if (currentIndex <= 0 || currentIndex > tracks.length) {
      return const <Track>[];
    }
    return tracks.sublist(0, currentIndex);
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

  /// Appends [track] to the end of the queue ("add to queue"). With an empty
  /// queue it becomes the current track. When shuffled, the track is also
  /// appended to [originalOrder] so it survives a later unshuffle (mirroring
  /// [enqueueNext]).
  PlaybackQueue appended(Track track) {
    if (current == null) return PlaybackQueue.single(track);
    final updated = List<Track>.of(tracks)..add(track);
    final updatedOriginal = originalOrder == null
        ? null
        : (List<Track>.of(originalOrder!)..add(track));
    return PlaybackQueue(
      tracks: updated,
      currentIndex: currentIndex,
      originalOrder: updatedOriginal,
    );
  }

  /// Removes the upcoming track at [upNextIndex] (0-based into [upNext]),
  /// leaving the current track and everything before it untouched so playback
  /// continues uninterrupted. An out-of-range index is a no-op (returns this).
  /// When shuffled, the same track is dropped from [originalOrder] so a later
  /// unshuffle can't resurrect it.
  PlaybackQueue removeUpNextAt(int upNextIndex) {
    if (upNextIndex < 0 || upNextIndex >= upNext.length) return this;
    final absolute = currentIndex + 1 + upNextIndex;
    final removed = tracks[absolute];
    final updated = List<Track>.of(tracks)..removeAt(absolute);
    final updatedOriginal = originalOrder == null
        ? null
        : (List<Track>.of(originalOrder!)..remove(removed));
    return PlaybackQueue(
      tracks: updated,
      currentIndex: currentIndex,
      originalOrder: updatedOriginal,
    );
  }

  /// Moves the upcoming track from [oldUpNextIndex] to [newUpNextIndex] (both
  /// 0-based into [upNext]; [newUpNextIndex] is the destination *after* removal,
  /// the index a normalised `ReorderableList` reports). The current track is
  /// untouched, so it keeps playing. A no-op for out-of-range or equal indices.
  ///
  /// While shuffled this reorders only the *effective* (shuffled) order;
  /// [originalOrder] is left intact, so a later [unshuffled] restores the
  /// pre-shuffle order and drops the manual move — keeping shuffle coherent.
  PlaybackQueue reorderUpNext(int oldUpNextIndex, int newUpNextIndex) {
    final int count = upNext.length;
    if (oldUpNextIndex < 0 || oldUpNextIndex >= count) return this;
    if (newUpNextIndex < 0 || newUpNextIndex >= count) return this;
    if (oldUpNextIndex == newUpNextIndex) return this;
    final int base = currentIndex + 1;
    final updated = List<Track>.of(tracks);
    final moved = updated.removeAt(base + oldUpNextIndex);
    updated.insert(base + newUpNextIndex, moved);
    return PlaybackQueue(
      tracks: updated,
      currentIndex: currentIndex,
      originalOrder: originalOrder,
    );
  }

  /// Makes the upcoming track at [upNextIndex] (0-based into [upNext]) the
  /// current one — "play this now". The tracks between the old current and it
  /// fall into [previous] (history). A no-op for an out-of-range index.
  PlaybackQueue jumpToUpNext(int upNextIndex) {
    if (upNextIndex < 0 || upNextIndex >= upNext.length) return this;
    return PlaybackQueue(
      tracks: tracks,
      currentIndex: currentIndex + 1 + upNextIndex,
      originalOrder: originalOrder,
    );
  }

  /// Steps back to the previously-played track at [historyIndex] (0-based into
  /// [history]), making it current. The tracks after it — including the old
  /// current — become [upNext] again. A no-op for an out-of-range index.
  PlaybackQueue jumpToHistory(int historyIndex) {
    if (historyIndex < 0 || historyIndex >= history.length) return this;
    return PlaybackQueue(
      tracks: tracks,
      currentIndex: historyIndex,
      originalOrder: originalOrder,
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
