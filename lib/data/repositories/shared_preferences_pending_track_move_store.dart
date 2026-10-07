import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/local_store_write_exception.dart';
import '../../core/repositories/pending_track_move_store.dart';

/// A [PendingTrackMoveStore] backed by `shared_preferences`.
///
/// Stored as `[{"f": from, "t": to, "s": [store, …]}, …]` under its own key,
/// which is removed once nothing is pending, so a library whose moves all
/// landed keeps no record at all.
///
/// Only a missing key means nothing is pending. A record that can't be read,
/// even one entry of it, is reported as corrupt rather than read around:
/// that entry may be the only trace of a move, and where it stood among the
/// others matters as much as what it says.
class SharedPreferencesPendingTrackMoveStore implements PendingTrackMoveStore {
  const SharedPreferencesPendingTrackMoveStore();

  static const String _key = 'pending_track_moves_v1';

  @override
  Future<List<PendingTrackMove>> load() async {
    final Object? raw;
    try {
      raw = (await SharedPreferences.getInstance()).get(_key);
    } catch (_) {
      throw const PendingTrackMoveJournalUnreadable(
        PendingTrackMoveJournalFault.readFailed,
      );
    }
    if (raw == null) return const <PendingTrackMove>[];
    final List<PendingTrackMove>? moves = raw is String ? _decode(raw) : null;
    if (moves == null) {
      throw const PendingTrackMoveJournalUnreadable(
        PendingTrackMoveJournalFault.corrupt,
      );
    }
    return moves;
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

  /// Every entry of [raw], or null when any part of it can't be read. An
  /// empty string is never written, so one is a write cut short.
  static List<PendingTrackMove>? _decode(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! List) return null;
    final List<PendingTrackMove> moves = <PendingTrackMove>[];
    for (final Object? entry in decoded) {
      final PendingTrackMove? move = _fromJson(entry);
      if (move == null) return null;
      moves.add(move);
    }
    return moves;
  }

  static PendingTrackMove? _fromJson(Object? entry) {
    if (entry is! Map) return null;
    final Object? from = entry['f'];
    final Object? to = entry['t'];
    final Object? targets = entry['s'];
    if (from is! String || from.isEmpty) return null;
    if (to is! String || to.isEmpty || to == from) return null;
    if (targets is! List || targets.isEmpty) return null;
    final Set<String> names = <String>{};
    for (final Object? name in targets) {
      if (name is! String || name.isEmpty) return null;
      names.add(name);
    }
    return PendingTrackMove(from: from, to: to, targets: names);
  }
}
