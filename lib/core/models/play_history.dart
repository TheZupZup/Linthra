import 'package:flutter/foundation.dart';

/// How often a single track has been played, and when it last finished.
///
/// Deliberately tiny and id-free: the owning [PlayHistory] keys these by track
/// id, so this carries no track identity, no uri, and never a token or stream
/// URL. Play history is on-device only.
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
/// mixes. Stores only non-secret track ids mapped to [TrackPlayStats] — never a
/// uri, token, or authenticated URL — and stays on the device (no telemetry, no
/// server upload).
@immutable
class PlayHistory {
  const PlayHistory({this.stats = const <String, TrackPlayStats>{}});

  static const PlayHistory empty = PlayHistory();

  /// Per-track stats keyed by stable Linthra track id.
  final Map<String, TrackPlayStats> stats;

  bool hasPlayed(String trackId) => stats.containsKey(trackId);

  int playCountFor(String trackId) => stats[trackId]?.playCount ?? 0;

  DateTime? lastPlayedFor(String trackId) => stats[trackId]?.lastPlayedAt;

  /// Track ids that have been played, ordered most-recently-played first.
  List<String> get recentlyPlayedIds {
    final List<String> ids = stats.keys.toList();
    ids.sort((String a, String b) =>
        stats[b]!.lastPlayedAt.compareTo(stats[a]!.lastPlayedAt));
    return ids;
  }

  /// Track ids that have been played, ordered most-played first; ties are
  /// broken by most-recently-played so the order is stable and meaningful.
  List<String> get mostPlayedIds {
    final List<String> ids = stats.keys.toList();
    ids.sort((String a, String b) {
      final int byCount = stats[b]!.playCount.compareTo(stats[a]!.playCount);
      if (byCount != 0) return byCount;
      return stats[b]!.lastPlayedAt.compareTo(stats[a]!.lastPlayedAt);
    });
    return ids;
  }

  /// Returns a copy with one more completed play for [trackId] recorded at [at].
  PlayHistory recordPlay(String trackId, DateTime at) {
    final Map<String, TrackPlayStats> next =
        Map<String, TrackPlayStats>.of(stats);
    final TrackPlayStats? existing = next[trackId];
    next[trackId] = existing == null
        ? TrackPlayStats(playCount: 1, lastPlayedAt: at)
        : existing.bumped(at);
    return PlayHistory(stats: next);
  }
}
