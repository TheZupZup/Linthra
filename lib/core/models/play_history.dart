import 'package:flutter/foundation.dart';

/// How often a single track has been played, and when it last finished.
///
/// Deliberately tiny and identity-free: the owning [PlayHistory] keys these by
/// the track's uri, so this value carries no identity itself and never a token
/// or stream URL. Play history is on-device only.
@immutable
class TrackPlayStats {
  const TrackPlayStats({required this.playCount, required this.lastPlayedAt});

  /// Number of completed plays (a play is counted when a track reaches its end).
  final int playCount;

  /// When the track most recently finished playing.
  final DateTime lastPlayedAt;

  /// Returns these stats with one more completed play recorded at [at].
  TrackPlayStats bumped(DateTime at) =>
      TrackPlayStats(playCount: playCount + 1, lastPlayedAt: at);
}

/// On-device playback history: per-track play counts and last-played times.
///
/// The data behind "Recently played", "Most played", and "Never played" smart
/// mixes. Keyed by the provider-namespaced [Track.uri] (e.g. `jellyfin:101`, a
/// local path), not the bare server-side id — so playing `jellyfin:101` never
/// makes `subsonic:101` look played. Stores only that non-secret uri mapped to
/// [TrackPlayStats] (the same identity the catalog and "recently added" store
/// persist) — never a token or authenticated stream URL — and stays on the
/// device (no telemetry, no server upload).
@immutable
class PlayHistory {
  const PlayHistory({this.stats = const <String, TrackPlayStats>{}});

  static const PlayHistory empty = PlayHistory();

  /// Per-track stats keyed by the provider-namespaced [Track.uri].
  final Map<String, TrackPlayStats> stats;

  bool hasPlayed(String trackUri) => stats.containsKey(trackUri);

  int playCountFor(String trackUri) => stats[trackUri]?.playCount ?? 0;

  DateTime? lastPlayedFor(String trackUri) => stats[trackUri]?.lastPlayedAt;

  /// Track uris that have been played, ordered most-recently-played first.
  List<String> get recentlyPlayedKeys {
    final List<String> keys = stats.keys.toList();
    keys.sort((String a, String b) =>
        stats[b]!.lastPlayedAt.compareTo(stats[a]!.lastPlayedAt));
    return keys;
  }

  /// Track uris that have been played, ordered most-played first; ties are
  /// broken by most-recently-played so the order is stable and meaningful.
  List<String> get mostPlayedKeys {
    final List<String> keys = stats.keys.toList();
    keys.sort((String a, String b) {
      final int byCount = stats[b]!.playCount.compareTo(stats[a]!.playCount);
      if (byCount != 0) return byCount;
      return stats[b]!.lastPlayedAt.compareTo(stats[a]!.lastPlayedAt);
    });
    return keys;
  }

  /// Returns a copy with one more completed play for [trackUri] recorded at
  /// [at].
  PlayHistory recordPlay(String trackUri, DateTime at) {
    final Map<String, TrackPlayStats> next =
        Map<String, TrackPlayStats>.of(stats);
    final TrackPlayStats? existing = next[trackUri];
    next[trackUri] = existing == null
        ? TrackPlayStats(playCount: 1, lastPlayedAt: at)
        : existing.bumped(at);
    return PlayHistory(stats: next);
  }

  /// Returns a copy with [from]'s stats merged onto the [to] key and the [from]
  /// key removed. Used by the one-time bare-id → uri migration: a play count
  /// recorded under the legacy bare id is folded into the same track's uri
  /// (counts summed, the later last-played time kept). A no-op when [from]
  /// carries no stats.
  PlayHistory remapKey(String from, String to) {
    final TrackPlayStats? moving = stats[from];
    if (moving == null || from == to) return this;
    final Map<String, TrackPlayStats> next =
        Map<String, TrackPlayStats>.of(stats)..remove(from);
    final TrackPlayStats? existing = next[to];
    next[to] = existing == null
        ? moving
        : TrackPlayStats(
            playCount: existing.playCount + moving.playCount,
            lastPlayedAt: existing.lastPlayedAt.isAfter(moving.lastPlayedAt)
                ? existing.lastPlayedAt
                : moving.lastPlayedAt,
          );
    return PlayHistory(stats: next);
  }
}
