import 'package:flutter/foundation.dart';

import 'persisted_playback_session.dart' show isLogicalTrackUri;
import 'track.dart';

/// Why a track left the player.
///
/// Both count as "recently played" — the distinction is for the listener, not
/// for the model: "I skipped that, let me hear it properly" and "that was good,
/// play it again" are different intents, and the row says which one it was.
enum PlaybackHistoryOutcome {
  /// The track reached its end.
  completed,

  /// The listener moved on before the end (skip, a jump elsewhere in the queue,
  /// or a whole new queue).
  skipped,
}

/// One entry in the recent-playback history.
///
/// Carries a catalog [Track] — the same logical identity the queue and the
/// crash-safe session store hold (provider-namespaced uri, title, artist,
/// album, artwork reference). Never a resolved or authenticated stream URL:
/// [PlaybackHistory.record] refuses anything that is not a logical identity, so
/// a tokenized URL cannot reach this type in the first place.
@immutable
class PlaybackHistoryEntry {
  const PlaybackHistoryEntry({
    required this.track,
    required this.outcome,
    required this.playedAt,
  });

  final Track track;
  final PlaybackHistoryOutcome outcome;

  /// When the track left the player. Used for ordering and for the row's
  /// relative time; on-device only, never reported anywhere.
  final DateTime playedAt;

  bool get wasCompleted => outcome == PlaybackHistoryOutcome.completed;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlaybackHistoryEntry &&
          other.track.uri == track.uri &&
          other.outcome == outcome &&
          other.playedAt == playedAt);

  @override
  int get hashCode => Object.hash(track.uri, outcome, playedAt);

  @override
  String toString() =>
      'PlaybackHistoryEntry(${track.uri}, ${outcome.name}, $playedAt)';
}

/// A bounded, most-recent-first list of what just played.
///
/// This is **not** the queue. `PlaybackQueue.history` is the already-played
/// *prefix of the current queue*: it is how you step back inside the queue you
/// are in, and it disappears the moment a new queue replaces it. This is the
/// other thing — what actually played recently, across queues — which is what
/// "recently completed/skipped tracks" means and what a desktop queue pane has
/// the room to show ([#419](https://github.com/thezupzup/linthra/issues/419)).
///
/// Three properties are the whole design:
///
///  * **Bounded.** At most [limit] entries ([defaultLimit] by default). A long
///    listening session cannot grow it: the oldest entry rolls off. There is no
///    unbounded list and no growth on disk, because...
///  * **In memory only.** History lives for the session and is gone when the
///    process ends. Nothing about it is written anywhere, so the "no token, no
///    authenticated URL persisted" rule is satisfied by there being no store at
///    all rather than by sanitising one.
///  * **Logical identity only.** [record] rejects a track whose uri is not a
///    logical one ([isLogicalTrackUri] — the same guard the crash-safe session
///    store uses), so an `http(s)://` stream URL or a token-bearing uri can
///    never become an entry. Replaying an entry therefore *has* to go back
///    through the normal resolver, because the history has nothing playable in
///    it.
@immutable
class PlaybackHistory {
  const PlaybackHistory({
    this.entries = const <PlaybackHistoryEntry>[],
    this.limit = defaultLimit,
  }) : assert(limit > 0);

  static const PlaybackHistory empty = PlaybackHistory();

  /// The retention bound: how many recently played tracks are kept.
  ///
  /// 50 is deliberately a couple of albums' worth — enough to answer "what was
  /// that song twenty minutes ago", small enough that the list stays scannable
  /// and its memory cost stays a rounding error next to the catalog itself. It
  /// is a hard cap, not a hint: [record] trims on every write.
  static const int defaultLimit = 50;

  /// The retained entries, **most recent first**. Never longer than [limit].
  final List<PlaybackHistoryEntry> entries;

  /// The most entries this history will hold.
  final int limit;

  bool get isEmpty => entries.isEmpty;
  bool get isNotEmpty => entries.isNotEmpty;
  int get length => entries.length;

  /// Returns this history with [track] recorded at the front.
  ///
  /// Three rules, in order:
  ///
  ///  1. A track without a logical identity is **not recorded at all**. That is
  ///     the security guard: nothing token-bearing can enter the history.
  ///  2. A track already in the history **moves** to the front rather than
  ///     being added again, carrying its new outcome and time. Playing the same
  ///     song five times leaves one entry, so a repeat-heavy session cannot
  ///     push everything else off the end.
  ///  3. The list is trimmed to [limit], oldest first.
  PlaybackHistory record(
    Track track, {
    required PlaybackHistoryOutcome outcome,
    required DateTime at,
  }) {
    if (!isLogicalTrackUri(track.uri)) return this;

    final List<PlaybackHistoryEntry> next = <PlaybackHistoryEntry>[
      PlaybackHistoryEntry(track: track, outcome: outcome, playedAt: at),
      // Compared by uri, not by `Track`'s `==` (which keys on the bare id): two
      // providers' copies of one song can share an id, and they are different
      // rows in a history that exists to be replayed.
      for (final PlaybackHistoryEntry entry in entries)
        if (entry.track.uri != track.uri) entry,
    ];
    if (next.length > limit) next.removeRange(limit, next.length);
    return PlaybackHistory(entries: next, limit: limit);
  }

  /// Returns an empty history with the same bound.
  PlaybackHistory cleared() => isEmpty ? this : PlaybackHistory(limit: limit);

  /// The entry for [trackUri], or null when it is not in the history.
  PlaybackHistoryEntry? entryFor(String trackUri) {
    for (final PlaybackHistoryEntry entry in entries) {
      if (entry.track.uri == trackUri) return entry;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlaybackHistory &&
          other.limit == limit &&
          listEquals(other.entries, entries));

  @override
  int get hashCode => Object.hash(limit, Object.hashAll(entries));
}
