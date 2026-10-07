import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/local_store_write_exception.dart';
import '../../core/repositories/pending_track_move_store.dart';

/// A [PendingTrackMoveStore] backed by `shared_preferences`.
///
/// Stored as `[{"f": from, "t": to, "s": [store, …]}, …]` under its own key,
/// which is removed once nothing is pending, so a library whose moves all
/// landed keeps no record at all. An entry that can't be read drops only
/// itself.
class SharedPreferencesPendingTrackMoveStore implements PendingTrackMoveStore {
  const SharedPreferencesPendingTrackMoveStore();

  static const String _key = 'pending_track_moves_v1';

  @override
  Future<List<PendingTrackMove>> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const <PendingTrackMove>[];
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const <PendingTrackMove>[];
    }
    if (decoded is! List) return const <PendingTrackMove>[];
    return <PendingTrackMove>[
      for (final Object? entry in decoded)
        if (_fromJson(entry) case final PendingTrackMove move) move,
    ];
  }

  @override
  Future<void> save(List<PendingTrackMove> moves) async {
    bool written;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      written = moves.isEmpty
          ? await prefs.remove(_key)
          : await prefs.setString(
              _key,
              jsonEncode(<Map<String, Object>>[
                for (final PendingTrackMove move in moves)
                  <String, Object>{
                    'f': move.from,
                    't': move.to,
                    's': move.targets.toList()..sort(),
                  },
              ]),
            );
    } catch (_) {
      // Thrown rather than answered false: it didn't happen either.
      written = false;
    }
    if (!written) {
      throw const LocalStoreWriteException(LocalStoreArea.trackMoves);
    }
  }

  static PendingTrackMove? _fromJson(Object? entry) {
    if (entry is! Map) return null;
    final Object? from = entry['f'];
    final Object? to = entry['t'];
    final Object? targets = entry['s'];
    if (from is! String || from.isEmpty) return null;
    if (to is! String || to.isEmpty || to == from) return null;
    if (targets is! List) return null;
    final Set<String> names = <String>{
      for (final Object? name in targets)
        if (name is String && name.isNotEmpty) name,
    };
    if (names.isEmpty) return null;
    return PendingTrackMove(from: from, to: to, targets: names);
  }
}
