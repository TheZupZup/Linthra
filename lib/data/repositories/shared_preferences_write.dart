import 'package:shared_preferences/shared_preferences.dart';

/// Runs [write] on [key] and, when the platform refuses it or throws, puts
/// [key] back to what it held before. Completes with whether it was written.
///
/// `shared_preferences` changes its in-memory copy before the platform
/// answers, and keeps the change when the write is refused. A store read again
/// in the same run would take that copy for what is on disk: a record that was
/// never saved, or none where the disk still has one.
///
/// A later write to [key] started meanwhile is left alone: it holds the newer
/// value, and answers for itself.
Future<bool> writeOrRestore(
  SharedPreferences prefs,
  String key,
  Future<bool> Function() write,
) async {
  final int started = _started[key] = (_started[key] ?? 0) + 1;
  final Object? before = prefs.get(key);
  if (await _attempt(write)) return true;
  if (_started[key] != started) return false;
  await _attempt(
    () =>
        before == null ? prefs.remove(key) : putPreference(prefs, key, before),
  );
  return false;
}

/// How many writes [writeOrRestore] has started on each key.
final Map<String, int> _started = <String, int>{};

/// Writes [value] under [key] with the type it was read with. False for a
/// value preferences can't hold.
Future<bool> putPreference(
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

Future<bool> _attempt(Future<bool> Function() write) async {
  try {
    return await write();
  } catch (_) {
    return false;
  }
}
