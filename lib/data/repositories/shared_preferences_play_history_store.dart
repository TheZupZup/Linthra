import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/play_history.dart';
import '../../core/repositories/play_history_store.dart';

/// A [PlayHistoryStore] backed by `shared_preferences`.
///
/// Play history is a small map of non-secret track uris to a play count and a
/// last-played timestamp, so a key/value document is the right weight (the same
/// reasoning favourites and the offline-download set follow). Stored as
/// `{ "<trackUri>": { "c": <count>, "t": <epochMs> }, ... }`, where the key is
/// the provider-namespaced [Track.uri] (`jellyfin:101`, a local path) so two
/// providers' same-id tracks keep separate counts.
///
/// Privacy: only that uri, counts, and timestamps are written — the same
/// identity the catalog and "recently added" store persist — never a token or
/// an authenticated stream URL, so the document can never carry a secret, and it
/// stays on the device.
class SharedPreferencesPlayHistoryStore implements PlayHistoryStore {
  const SharedPreferencesPlayHistoryStore();

  static const String _key = 'play_history_v1';

  @override
  Future<PlayHistory> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return PlayHistory.empty;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      // A corrupt record reads as "no history" rather than crashing.
      return PlayHistory.empty;
    }
    if (decoded is! Map<String, dynamic>) return PlayHistory.empty;
    final Map<String, TrackPlayStats> stats = <String, TrackPlayStats>{};
    decoded.forEach((String key, Object? value) {
      if (key.isEmpty || value is! Map<String, dynamic>) return;
      final Object? count = value['c'];
      final Object? millis = value['t'];
      if (count is! int || count <= 0 || millis is! int) return;
      stats[key] = TrackPlayStats(
        playCount: count,
        lastPlayedAt: DateTime.fromMillisecondsSinceEpoch(millis),
      );
    });
    return PlayHistory(stats: stats);
  }

  @override
  Future<void> save(PlayHistory history) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final Map<String, dynamic> document = <String, dynamic>{
      for (final MapEntry<String, TrackPlayStats> entry
          in history.stats.entries)
        entry.key: <String, dynamic>{
          'c': entry.value.playCount,
          't': entry.value.lastPlayedAt.millisecondsSinceEpoch,
        },
    };
    await prefs.setString(_key, jsonEncode(document));
  }
}
