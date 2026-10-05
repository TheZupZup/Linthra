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
///
/// Each entry also carries a private id, and that id, not the track's uri, is
/// what ties an entry in [tracks] to its place in [originalOrder]. The same
/// song can be queued twice, and going by uri, shuffle off jumped to its first
/// copy, and removing one copy could take another copy's place in the
/// pre-shuffle order (#744).
@immutable
class PlaybackQueue {
  const PlaybackQueue({
    this.tracks = const <Track>[],
    this.currentIndex = -1,
    this.originalOrder,
  })  : _ids = null,
        _originalIds = null;

  const PlaybackQueue._(
    this.tracks,
    this.currentIndex,
    this.originalOrder,
    this._ids,
    this._originalIds,
  );

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

  /// One id per entry in [tracks], or null when the queue came from the
  /// public constructor, whose entries are numbered by position.
  final List<int>? _ids;

  /// One id per entry in [originalOrder], or null when the queue came from the
  /// public constructor (see [_originalEntryIds]).
  final List<int>? _originalIds;

  List<int> get _entryIds =>
      _ids ?? List<int>.generate(tracks.length, (int i) => i);

  /// The ids of [originalOrder], or null when not shuffled. A pre-shuffle
  /// order handed to the public constructor has no ids of its own: there, each
  /// copy of a song pairs with its copies in [tracks] in turn (the first with
  /// the first), and an entry that has no copy left in [tracks] gets a new id.
  List<int>? get _originalEntryIds {
    final List<Track>? original = originalOrder;
    if (original == null) return null;
    final List<int>? ids = _originalIds;
    if (ids != null) return ids;
    final List<int> entryIds = _entryIds;
    final Map<String, List<int>> byUri = <String, List<int>>{};
    for (int i = 0; i < tracks.length; i++) {
      byUri.putIfAbsent(tracks[i].uri, () => <int>[]).add(entryIds[i]);
    }
    final Map<String, int> paired = <String, int>{};
    int fresh = _nextId(entryIds, const <int>[]);
    final List<int> originalIds = <int>[];
    for (final Track track in original) {
      final List<int>? copies = byUri[track.uri];
      final int taken = paired[track.uri] ?? 0;
      paired[track.uri] = taken + 1;
      originalIds.add(
        copies != null && taken < copies.length ? copies[taken] : fresh++,
      );
    }
    return originalIds;
  }

  /// One past the highest id in use, so a new entry never reuses one.
  static int _nextId(List<int> ids, List<int> originalIds) {
    int next = 0;
    for (final int id in ids) {
      if (id >= next) next = id + 1;
    }
    for (final int id in originalIds) {
      if (id >= next) next = id + 1;
    }
    return next;
  }

  /// Where each entry of [tracks] sits in [originalOrder], or null when not
  /// shuffled: the part of the state the ids carry, without their numbering.
  List<int>? get _originalSlots {
    final List<int>? originalIds = _originalEntryIds;
    if (originalIds == null) return null;
    final Map<int, int> slotOf = <int, int>{
      for (int i = 0; i < originalIds.length; i++) originalIds[i]: i,
    };
    return <int>[for (final int id in _entryIds) slotOf[id] ?? -1];
  }

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
    return _at(currentIndex + 1);
  }

  /// Steps back to the previous track. Returns this queue unchanged when the
  /// current track is the first, so callers can branch on [hasPrevious].
  PlaybackQueue previous() {
    if (!hasPrevious) return this;
    return _at(currentIndex - 1);
  }

  /// Wraps back to the first track in the effective order, keeping the queue
  /// (and its shuffle) intact. Used by repeat-all when the last track finishes.
  PlaybackQueue restarted() {
    if (isEmpty) return this;
    return _at(0);
  }

  /// Makes the entry at [index] (into [tracks]) the current one, keeping the
  /// queue and its shuffle as they are; the entries before it become
  /// [history]. A no-op for an out-of-range index.
  PlaybackQueue movedTo(int index) {
    if (index < 0 || index >= tracks.length) return this;
    return _at(index);
  }

  PlaybackQueue _at(int index) =>
      PlaybackQueue._(tracks, index, originalOrder, _ids, _originalIds);

  /// Inserts [track] immediately after the current one ("play next"). With an
  /// empty queue it becomes the current track. When shuffled, the track also
  /// goes right after the current one in [originalOrder], so it is still next
  /// once shuffle is turned off.
  PlaybackQueue enqueueNext(Track track) {
    if (current == null) return PlaybackQueue.single(track);
    return _inserted(<Track>[track], afterCurrent: true);
  }

  /// Appends [track] to the end of the queue ("add to queue"). With an empty
  /// queue it becomes the current track. When shuffled, the track is also
  /// appended to [originalOrder] so it survives a later unshuffle (mirroring
  /// [enqueueNext]).
  PlaybackQueue appended(Track track) {
    if (current == null) return PlaybackQueue.single(track);
    return _inserted(<Track>[track], afterCurrent: false);
  }

  /// Inserts [tracks] immediately after the current one, in the order given, as
  /// **one** transition: the set version of [enqueueNext].
  ///
  /// One call rather than a loop of single inserts is what keeps a collection's
  /// own order intact: each [enqueueNext] lands at the same slot, so inserting
  /// an album track by track puts it in the queue backwards unless the caller
  /// reverses it first. It also means one queue mutation (and one state change)
  /// per listener action instead of one per track. With an empty queue the set
  /// becomes the queue, starting at its first track, mirroring [enqueueNext]'s
  /// single-track behaviour. An empty [tracks] is a no-op.
  PlaybackQueue enqueueAllNext(List<Track> tracks) {
    if (tracks.isEmpty) return this;
    if (current == null) return PlaybackQueue.of(tracks);
    return _inserted(tracks, afterCurrent: true);
  }

  /// Appends [tracks] to the end of the queue, in the order given, as **one**
  /// transition: the set version of [appended]. With an empty queue the set
  /// becomes the queue. An empty [tracks] is a no-op.
  PlaybackQueue appendedAll(List<Track> tracks) {
    if (tracks.isEmpty) return this;
    if (current == null) return PlaybackQueue.of(tracks);
    return _inserted(tracks, afterCurrent: false);
  }

  /// Puts [added] right after the current entry, or at the end, each as a new
  /// entry. When shuffled they go into [originalOrder] too: right after the
  /// current entry's own place there for "play next" (its end when the current
  /// entry isn't in it), and at its end for "add to queue".
  PlaybackQueue _inserted(List<Track> added, {required bool afterCurrent}) {
    final List<int> ids = _entryIds;
    final List<int>? originalIds = _originalEntryIds;
    final int first = _nextId(ids, originalIds ?? const <int>[]);
    final List<int> addedIds =
        List<int>.generate(added.length, (int i) => first + i);
    final int at = afterCurrent ? currentIndex + 1 : tracks.length;
    List<Track>? original = originalOrder;
    List<int>? updatedOriginalIds = originalIds;
    if (original != null && originalIds != null) {
      final int own =
          afterCurrent ? originalIds.indexOf(ids[currentIndex]) : -1;
      final int originalAt = own < 0 ? originalIds.length : own + 1;
      original = List<Track>.of(original)..insertAll(originalAt, added);
      updatedOriginalIds = List<int>.of(originalIds)
        ..insertAll(originalAt, addedIds);
    }
    return PlaybackQueue._(
      List<Track>.of(tracks)..insertAll(at, added),
      currentIndex,
      original,
      List<int>.of(ids)..insertAll(at, addedIds),
      updatedOriginalIds,
    );
  }

  /// Removes the upcoming track at [upNextIndex] (0-based into [upNext]),
  /// leaving the current track and everything before it untouched so playback
  /// continues uninterrupted. An out-of-range index is a no-op (returns this).
  /// When shuffled, that entry's own place in [originalOrder] goes too, so a
  /// later unshuffle can't resurrect it, and another copy of the same song
  /// keeps its place.
  PlaybackQueue removeUpNextAt(int upNextIndex) {
    if (upNextIndex < 0 || upNextIndex >= upNext.length) return this;
    final int absolute = currentIndex + 1 + upNextIndex;
    final List<int> ids = _entryIds;
    final List<int>? originalIds = _originalEntryIds;
    List<Track>? original = originalOrder;
    List<int>? updatedOriginalIds = originalIds;
    if (original != null && originalIds != null) {
      final int i = originalIds.indexOf(ids[absolute]);
      if (i >= 0) {
        original = List<Track>.of(original)..removeAt(i);
        updatedOriginalIds = List<int>.of(originalIds)..removeAt(i);
      }
    }
    return PlaybackQueue._(
      List<Track>.of(tracks)..removeAt(absolute),
      currentIndex,
      original,
      List<int>.of(ids)..removeAt(absolute),
      updatedOriginalIds,
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
    final ids = List<int>.of(_entryIds);
    updated.insert(
        base + newUpNextIndex, updated.removeAt(base + oldUpNextIndex));
    ids.insert(base + newUpNextIndex, ids.removeAt(base + oldUpNextIndex));
    return PlaybackQueue._(
      updated,
      currentIndex,
      originalOrder,
      ids,
      _originalEntryIds,
    );
  }

  /// Makes the upcoming track at [upNextIndex] (0-based into [upNext]) the
  /// current one — "play this now". The tracks between the old current and it
  /// fall into [previous] (history). A no-op for an out-of-range index.
  PlaybackQueue jumpToUpNext(int upNextIndex) {
    if (upNextIndex < 0 || upNextIndex >= upNext.length) return this;
    return _at(currentIndex + 1 + upNextIndex);
  }

  /// Steps back to the previously-played track at [historyIndex] (0-based into
  /// [history]), making it current. The tracks after it — including the old
  /// current — become [upNext] again. A no-op for an out-of-range index.
  PlaybackQueue jumpToHistory(int historyIndex) {
    if (historyIndex < 0 || historyIndex >= history.length) return this;
    return _at(historyIndex);
  }

  /// Drops every upcoming track, keeping only the one playing now. The result
  /// is a plain single-track queue (no shuffle to restore).
  PlaybackQueue cleared() {
    final track = current;
    if (track == null) return empty;
    return PlaybackQueue.single(track);
  }

  /// Takes every track [test] picks out of the queue: up next, history and
  /// the current one alike. Returns this queue when it picks none.
  ///
  /// When the current track goes, the first track left after it becomes
  /// current, or with none after it the last one left before it; with nothing
  /// left the queue is [empty]. When shuffled, the same tracks leave
  /// [originalOrder], so a later unshuffle can't bring them back.
  ///
  /// [test] answers by what a track is (its provider, say), never by where it
  /// sits, so a song leaves both orders together. Every entry left keeps its
  /// id, so copies of a song queued twice stay apart (#744).
  PlaybackQueue removedWhere(bool Function(Track track) test) {
    if (!tracks.any(test)) return this;
    final List<int> ids = _entryIds;
    final List<Track> kept = <Track>[];
    final List<int> keptIds = <int>[];
    int index = -1;
    for (int i = 0; i < tracks.length; i++) {
      if (test(tracks[i])) continue;
      // The current track when it stays, else the first one kept after it.
      if (index < 0 && i >= currentIndex) index = kept.length;
      kept.add(tracks[i]);
      keptIds.add(ids[i]);
    }
    if (kept.isEmpty) return empty;
    final List<Track>? original = originalOrder;
    final List<int>? originalIds = _originalEntryIds;
    List<Track>? keptOriginal;
    List<int>? keptOriginalIds;
    if (original != null && originalIds != null) {
      keptOriginal = <Track>[];
      keptOriginalIds = <int>[];
      for (int i = 0; i < original.length; i++) {
        if (test(original[i])) continue;
        keptOriginal.add(original[i]);
        keptOriginalIds.add(originalIds[i]);
      }
    }
    return PlaybackQueue._(
      kept,
      index < 0 ? kept.length - 1 : index,
      keptOriginal,
      keptIds,
      keptOriginalIds,
    );
  }

  /// Returns a shuffled copy: the current track stays current (moved to the
  /// front so playback continues uninterrupted) and every other track is
  /// randomised after it. The pre-shuffle order is remembered in
  /// [originalOrder]. A no-op on an empty queue, and re-shuffling keeps the
  /// first remembered order so [unshuffled] still restores the true original.
  PlaybackQueue shuffled([Random? random]) {
    if (current == null) return this;
    final List<int> ids = _entryIds;
    // Positions are shuffled rather than tracks, so each entry keeps its id.
    final List<int> rest = <int>[
      for (int i = 0; i < tracks.length; i++)
        if (i != currentIndex) i,
    ]..shuffle(random);
    final List<int> order = <int>[currentIndex, ...rest];
    return PlaybackQueue._(
      <Track>[for (final int i in order) tracks[i]],
      0,
      originalOrder ?? List<Track>.of(tracks),
      <int>[for (final int i in order) ids[i]],
      _originalEntryIds ?? List<int>.of(ids),
    );
  }

  /// Restores the pre-shuffle order, keeping the current track current. A no-op
  /// when the queue was not shuffled.
  ///
  /// The current entry lands on its own place in that order, not on the first
  /// copy of the same song.
  PlaybackQueue unshuffled() {
    final List<Track>? original = originalOrder;
    final List<int>? originalIds = _originalEntryIds;
    if (original == null || originalIds == null) return this;
    final int index =
        current == null ? -1 : originalIds.indexOf(_entryIds[currentIndex]);
    return PlaybackQueue._(
      List<Track>.of(original),
      index < 0 ? (original.isEmpty ? -1 : 0) : index,
      null,
      List<int>.of(originalIds),
      null,
    );
  }

  /// Replaces the current track *in place* with [track], keeping its position,
  /// up-next, history, and shuffle intact. Used when playback fell back to
  /// another source copy of the same song, so the queue (and the now-playing UI)
  /// reflects the copy that actually started. A no-op on an empty queue or when
  /// [track] is the same copy (same provider-namespaced uri) as the current one.
  /// When shuffled, the current entry's own place in [originalOrder] is swapped
  /// too, so a later [unshuffled] keeps the copy that played.
  ///
  /// Identity is compared by [Track.uri]: two providers' copies of one song can
  /// share a bare id (e.g. `jellyfin:101` falling back to `subsonic:101`), and
  /// that swap must take effect so `current` reflects the copy that actually
  /// started.
  PlaybackQueue replaceCurrent(Track track) {
    final Track? old = current;
    if (old == null || old.uri == track.uri) return this;
    final List<int> ids = _entryIds;
    final List<int>? originalIds = _originalEntryIds;
    List<Track>? original = originalOrder;
    if (original != null && originalIds != null) {
      final int i = originalIds.indexOf(ids[currentIndex]);
      if (i >= 0) original = List<Track>.of(original)..[i] = track;
    }
    return PlaybackQueue._(
      List<Track>.of(tracks)..[currentIndex] = track,
      currentIndex,
      original,
      ids,
      originalIds,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlaybackQueue &&
          other.currentIndex == currentIndex &&
          listEquals(other.tracks, tracks) &&
          listEquals(other.originalOrder, originalOrder) &&
          listEquals(other._originalSlots, _originalSlots));

  @override
  int get hashCode => Object.hash(
        currentIndex,
        Object.hashAll(tracks),
        originalOrder == null ? null : Object.hashAll(originalOrder!),
      );
}
