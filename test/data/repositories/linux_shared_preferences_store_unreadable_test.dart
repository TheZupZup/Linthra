// A preferences file that is there but can't be read for a moment.
//
// Every playlist, heart, music folder, play count and download record lives
// in this one file on Linux. dart:io's `existsSync()` answers false whenever
// `stat` fails, not only when the file is missing: an I/O error on a network
// or FUSE home directory, a permission being changed. The store took that for
// "never saved", remembered an empty map for the rest of the session, and its
// next save, of any one setting, replaced the whole file with that setting.
//
// Staged with IOOverrides: while [_UnreachablePrefs.outage] is set, the file
// answers the way dart:io does when `stat` and `open` on it fail with EIO.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/linux_shared_preferences_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

const Map<String, Object> _saved = <String, Object>{
  'flutter.playlists_v1': '[{"id":"p1","name":"Road Trip"}]',
  'flutter.selected_music_folders': <String>['/home/me/Music'],
  'flutter.favorites_v2': '{"local":["/home/me/Music/a.flac"],"remote":[]}',
};

final class _UnreachablePrefs extends IOOverrides {
  _UnreachablePrefs(this.path);

  final String path;
  bool outage = true;

  @override
  File createFile(String path) {
    final File real = super.createFile(path);
    return path == this.path ? _Unreachable(real, () => outage) : real;
  }
}

class _Unreachable implements File {
  _Unreachable(this._real, this._outage);

  final File _real;
  final bool Function() _outage;

  static const OSError _eio = OSError('Input/output error', 5);

  @override
  String get path => _real.path;

  @override
  Directory get parent => _real.parent;

  @override
  bool existsSync() => !_outage() && _real.existsSync();

  @override
  Uint8List readAsBytesSync() {
    if (_outage()) throw FileSystemException('Cannot open file', path, _eio);
    return _real.readAsBytesSync();
  }

  @override
  File renameSync(String newPath) {
    if (_outage()) throw FileSystemException('Cannot rename', path, _eio);
    return _real.renameSync(newPath);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late File file;

  LinuxSharedPreferencesStore store() =>
      LinuxSharedPreferencesStore(directory: () async => directory.path);

  setUp(() {
    directory = Directory.systemTemp.createTempSync('linthra_prefs_eio_');
    file = File('${directory.path}/${LinuxSharedPreferencesStore.fileName}')
      ..writeAsStringSync(json.encode(_saved));
  });

  tearDown(() => directory.deleteSync(recursive: true));

  Map<String, Object?> onDisk() =>
      (json.decode(file.readAsStringSync()) as Map).cast<String, Object?>();

  test('a save after a read that failed keeps what the file held', () async {
    final _UnreachablePrefs io = _UnreachablePrefs(file.path);

    await IOOverrides.runWithIOOverrides(() async {
      final LinuxSharedPreferencesStore prefs = store();
      try {
        await prefs.getAll();
      } on FileSystemException {
        // Failing is an honest answer: the file could not be read.
      }
      io.outage = false;
      await prefs.setValue('String', 'flutter.theme', 'dark');
    }, io);

    expect(onDisk(), <String, Object?>{..._saved, 'flutter.theme': 'dark'});
  });

  test('the app does not start on empty settings and save them over the file',
      () async {
    final _UnreachablePrefs io = _UnreachablePrefs(file.path);
    useLinuxSharedPreferencesStore(store());
    SharedPreferences.resetStatic();
    addTearDown(() {
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.empty();
      SharedPreferences.resetStatic();
    });

    await IOOverrides.runWithIOOverrides(() async {
      SharedPreferences? prefs;
      try {
        prefs = await SharedPreferences.getInstance();
      } on FileSystemException {
        // Asked again below, once the file answers.
      }
      io.outage = false;
      prefs ??= await SharedPreferences.getInstance();

      expect(
          prefs.getString('playlists_v1'), '[{"id":"p1","name":"Road Trip"}]');
      await prefs.setString('theme', 'dark');
    }, io);

    expect(
        onDisk()['flutter.playlists_v1'], '[{"id":"p1","name":"Road Trip"}]');
    expect(
        onDisk()['flutter.selected_music_folders'], <String>['/home/me/Music']);
  });
}
