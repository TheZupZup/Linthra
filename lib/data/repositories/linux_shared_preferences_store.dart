import 'dart:convert' show json, utf8;
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

/// Linux preferences, in the same file `shared_preferences_linux` keeps them
/// in, saved so that a save can never destroy what was already there.
///
/// Playlists, favourites, the music folders, play history, download records,
/// the saved queue and every setting live in that one file. The plugin
/// rewrites it in place: it truncates the file, then writes the new contents.
/// A full disk, a crash or a power cut in between leaves it either empty,
/// which the next launch reads as "nothing was ever saved" (and the next save
/// makes permanent), or cut off partway, which it cannot read at all: every
/// read and every save then fails, on every launch, until the file is removed
/// by hand.
///
/// A save here writes a sibling temporary file, flushes it to disk and renames
/// it over the old one, so the file is always either the previous complete
/// contents or the new ones. A file an earlier save already damaged is moved
/// aside (kept, so it can still be recovered by hand) and the app carries on
/// from defaults instead of failing every time it asks.
///
/// Same file, same format, same keys: an install upgraded from the plugin
/// reads everything it wrote, and the plugin can read what this writes.
class LinuxSharedPreferencesStore extends SharedPreferencesStorePlatform {
  LinuxSharedPreferencesStore({Future<String?> Function()? directory})
      : _directory = directory ?? _applicationSupportPath;

  /// The plugin's file name, in the plugin's directory.
  static const String fileName = 'shared_preferences.json';

  /// The prefix `SharedPreferences` stores its keys under.
  static const String _defaultPrefix = 'flutter.';

  final Future<String?> Function() _directory;
  Map<String, Object>? _cached;

  /// Where `shared_preferences_linux` keeps the file: the application support
  /// directory path_provider_linux answers with, which is what
  /// `getApplicationSupportDirectory` asks on Linux.
  static Future<String?> _applicationSupportPath() async {
    try {
      return (await getApplicationSupportDirectory()).path;
    } on MissingPlatformDirectoryException {
      return null;
    }
  }

  Future<File?> _file() async {
    final String? directory = await _directory();
    return directory == null ? null : File(p.join(directory, fileName));
  }

  Future<Map<String, Object>> _read() async => _cached ??= await _load();

  Future<Map<String, Object>> _load() async {
    final File? file = await _file();
    if (file == null) return <String, Object>{};
    // Only a file that isn't there is "never saved". Any other failure to
    // read it (an I/O error on a network or FUSE home, a permission being
    // changed) is thrown, and not remembered, so the next read asks the file
    // again. `existsSync()` answered false for those too, and the empty map
    // remembered for them had the next save of any one setting replace the
    // whole file with that setting.
    final List<int> bytes;
    try {
      bytes = file.readAsBytesSync();
    } on PathNotFoundException {
      return <String, Object>{};
    }

    // An earlier save cut off before it wrote anything: nothing to recover.
    if (bytes.isEmpty) return <String, Object>{};
    try {
      // Decoded here rather than by the read: a save cut off inside a
      // character that isn't plain ASCII leaves bytes that aren't text, and
      // that has to be set aside like any other cut, not fail every read.
      final Object? data = json.decode(utf8.decode(bytes));
      if (data is Map) return data.cast<String, Object>();
    } on FormatException {
      // Cut off partway by an earlier save; set aside below.
    }
    _setAside(file);
    return <String, Object>{};
  }

  /// Moves a file that can't be read out of the way, under a name no later
  /// save will overwrite. If even that fails, the next save replaces it.
  static void _setAside(File file) {
    final int stamp = DateTime.now().millisecondsSinceEpoch;
    try {
      file.renameSync('${file.path}.damaged-$stamp');
    } on FileSystemException {
      // Left in place; the next complete save takes its place.
    }
  }

  Future<bool> _write(Map<String, Object> preferences) async {
    final File? file = await _file();
    if (file == null) return false;
    // Named for this process: a second Linthra instance saving at the same
    // moment writes its own, rather than truncating this one just before it
    // is renamed into place.
    final File temporary = File('${file.path}.$pid.tmp');
    try {
      file.parent.createSync(recursive: true);
      final RandomAccessFile out = temporary.openSync(mode: FileMode.write);
      try {
        out.writeStringSync(json.encode(preferences));
        // On disk before the rename makes it the file, so a power cut can't
        // leave a renamed but empty file behind.
        out.flushSync();
      } finally {
        out.closeSync();
      }
      temporary.renameSync(file.path);
      return true;
    } on FileSystemException {
      // Nothing was replaced: the previous file is still whole. The unfinished
      // temporary file goes, or the next save writes over it.
      try {
        if (temporary.existsSync()) temporary.deleteSync();
      } on FileSystemException {
        // The next save writes over it.
      }
      return false;
    }
  }

  @override
  Future<bool> clear() => clearWithParameters(
        ClearParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
      );

  @override
  Future<bool> clearWithPrefix(String prefix) => clearWithParameters(
        ClearParameters(filter: PreferencesFilter(prefix: prefix)),
      );

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async {
    final PreferencesFilter filter = parameters.filter;
    final Map<String, Object> preferences = await _read();
    preferences.removeWhere(
      (String key, _) =>
          key.startsWith(filter.prefix) &&
          (filter.allowList == null || filter.allowList!.contains(key)),
    );
    return _write(preferences);
  }

  @override
  Future<Map<String, Object>> getAll() => getAllWithParameters(
        GetAllParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
      );

  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) =>
      getAllWithParameters(
        GetAllParameters(filter: PreferencesFilter(prefix: prefix)),
      );

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async {
    final PreferencesFilter filter = parameters.filter;
    final Map<String, Object> matching =
        Map<String, Object>.from(await _read());
    matching.removeWhere(
      (String key, _) => !(key.startsWith(filter.prefix) &&
          (filter.allowList?.contains(key) ?? true)),
    );
    return matching;
  }

  @override
  Future<bool> remove(String key) async {
    final Map<String, Object> preferences = await _read();
    preferences.remove(key);
    return _write(preferences);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final Map<String, Object> preferences = await _read();
    preferences[key] = value;
    return _write(preferences);
  }
}

/// Makes [LinuxSharedPreferencesStore] the store every `SharedPreferences`
/// call in this process uses. Called before anything reads a preference.
void useLinuxSharedPreferencesStore([LinuxSharedPreferencesStore? store]) {
  SharedPreferencesStorePlatform.instance =
      store ?? LinuxSharedPreferencesStore();
}
