import 'dart:convert';

import 'package:flutter/foundation.dart' show listEquals;
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
/// others matters as much as what it says. [setAside] moves it, exactly as
/// it is, to a key of its own that nothing ever deletes.
class SharedPreferencesPendingTrackMoveStore implements PendingTrackMoveStore {
  const SharedPreferencesPendingTrackMoveStore();

  static const String _key = 'pending_track_moves_v1';
  static const String _setAsideKey = 'pending_track_moves_v1_unreadable';

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

  @override
  Future<bool> setAside() async {
    final SharedPreferences prefs;
    final Object? raw;
    try {
      prefs = await SharedPreferences.getInstance();
      raw = prefs.get(_key);
    } catch (_) {
      return false;
    }
    if (raw == null) return true;
    final Object value = raw;
    if (value is String && _decode(value) != null) return false;
    // `shared_preferences` changes what it holds in memory before the
    // platform answers, and keeps the change when the write is refused. So
    // each refused step is undone in memory, or this run would read what the
    // disk doesn't hold: a copy that was never saved, or no record at all.
    final Object? earlier = prefs.get(_setAsideKey);
    if (earlier == null) {
      if (!await _attempt(() => _put(prefs, _setAsideKey, value))) {
        await _attempt(() => prefs.remove(_setAsideKey));
        return false;
      }
    } else if (!_same(earlier, value)) {
      // One set aside before stays as it is.
      return false;
    }
    if (await _attempt(() => prefs.remove(_key))) return true;
    await _attempt(() => _put(prefs, _key, value));
    return false;
  }

  static Future<bool> _attempt(Future<bool> Function() write) async {
    try {
      return await write();
    } catch (_) {
      return false;
    }
  }

  /// Writes [value] under [key] with the type it was read with.
  static Future<bool> _put(
    SharedPreferences prefs,
    String key,
    Object value,
  ) async =>
      switch (value) {
        final String text => await prefs.setString(key, text),
        final bool flag => await prefs.setBool(key, flag),
        final int number => await prefs.setInt(key, number),
        final double number => await prefs.setDouble(key, number),
        final List<Object?> list when list.every((Object? e) => e is String) =>
          await prefs.setStringList(key, list.cast<String>()),
        _ => false,
      };

  static bool _same(Object a, Object b) =>
      a is List && b is List ? listEquals(a, b) : a == b;

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
