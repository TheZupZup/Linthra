import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/linux_shared_preferences_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

// Every playlist, favourite, music folder, setting and the saved queue live in
// one preferences file on Linux. These hold the store that writes it to two
// promises: it reads exactly what shared_preferences_linux wrote, and no save,
// finished or not, ever leaves that file empty or cut off.

/// What shared_preferences_linux writes: `json.encode` of the whole map, keys
/// carrying SharedPreferences' `flutter.` prefix.
const Map<String, Object> _pluginWritten = <String, Object>{
  'flutter.playlists': '[{"id":"p1","name":"Road Trip"}]',
  'flutter.selected_music_folders': <String>['/home/me/Music', '/media/usb'],
  'flutter.normalize_volume': true,
  'flutter.max_cache_bytes': 4294967296,
  'flutter.playback_speed': 1.25,
  'other.not_ours': 'kept',
};

void main() {
  late Directory directory;
  late File file;

  LinuxSharedPreferencesStore store() =>
      LinuxSharedPreferencesStore(directory: () async => directory.path);

  setUp(() {
    directory = Directory.systemTemp.createTempSync('linthra_prefs_');
    file = File('${directory.path}/${LinuxSharedPreferencesStore.fileName}');
  });

  tearDown(() => directory.deleteSync(recursive: true));

  Map<String, Object?> onDisk() =>
      (json.decode(file.readAsStringSync()) as Map).cast<String, Object?>();

  group('the same file shared_preferences_linux keeps', () {
    test('reads everything the plugin wrote', () async {
      file.writeAsStringSync(json.encode(_pluginWritten));

      final Map<String, Object> read = await store().getAll();

      expect(read['flutter.playlists'], '[{"id":"p1","name":"Road Trip"}]');
      expect(
        read['flutter.selected_music_folders'],
        <String>['/home/me/Music', '/media/usb'],
      );
      expect(read['flutter.normalize_volume'], isTrue);
      expect(read['flutter.max_cache_bytes'], 4294967296);
      expect(read['flutter.playback_speed'], 1.25);
      // Only SharedPreferences' own keys, as the plugin answers.
      expect(read.containsKey('other.not_ours'), isFalse);
    });

    test('writes the format the plugin reads, other keys untouched', () async {
      file.writeAsStringSync(json.encode(_pluginWritten));

      await store().setValue('String', 'flutter.theme', 'dark');

      expect(onDisk(), <String, Object?>{
        ..._pluginWritten,
        'flutter.theme': 'dark',
      });
    });

    test('remove and clear keep to their filter, as the plugin does', () async {
      file.writeAsStringSync(json.encode(_pluginWritten));
      final LinuxSharedPreferencesStore prefs = store();

      await prefs.remove('flutter.playback_speed');
      expect(onDisk().containsKey('flutter.playback_speed'), isFalse);

      await prefs.clear();
      expect(onDisk(), <String, Object?>{'other.not_ours': 'kept'});
    });

    test('a first save creates the directory and the file', () async {
      directory.deleteSync(recursive: true);

      expect(await store().setValue('Bool', 'flutter.onboarded', true), isTrue);

      expect(onDisk(), <String, Object?>{'flutter.onboarded': true});
    });
  });

  group('a save that cannot finish', () {
    test('leaves the previous file whole', () async {
      file.writeAsStringSync(json.encode(_pluginWritten));
      final String before = file.readAsStringSync();
      // The temporary file can't be written (here: a directory is in its
      // way), as when the disk is full.
      Directory('${file.path}.$pid.tmp').createSync();

      final bool saved =
          await store().setValue('String', 'flutter.theme', 'dark');

      expect(saved, isFalse);
      expect(file.readAsStringSync(), before);
      expect(
        (await store().getAll())['flutter.playlists'],
        '[{"id":"p1","name":"Road Trip"}]',
      );
    });

    test('never leaves a temporary file in place of the real one', () async {
      await store().setValue('String', 'flutter.theme', 'dark');

      expect(
        directory.listSync().where((e) => e.path.endsWith('.tmp')),
        isEmpty,
      );
      expect(onDisk(), <String, Object?>{'flutter.theme': 'dark'});
    });
  });

  group('a file an earlier save damaged', () {
    test('cut off partway: set aside, and the app carries on', () async {
      final String whole = json.encode(_pluginWritten);
      final String cutOff = whole.substring(0, whole.length ~/ 2);
      file.writeAsStringSync(cutOff);

      final LinuxSharedPreferencesStore prefs = store();
      expect(await prefs.getAll(), isEmpty);
      expect(await prefs.setValue('String', 'flutter.theme', 'dark'), isTrue);

      expect(onDisk(), <String, Object?>{'flutter.theme': 'dark'});
      final List<File> setAside = directory
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.contains('.damaged-'))
          .toList();
      expect(setAside, hasLength(1));
      expect(setAside.single.readAsStringSync(), cutOff);
    });

    // The plugin's save stops at whatever byte it had reached. Text that
    // isn't plain ASCII (an accented folder, a playlist in Japanese) is
    // several bytes a character, so the cut can land inside one, which is no
    // longer text at all rather than text that stops early.
    List<int> cutInsideACharacter() {
      final List<int> whole = utf8.encode(json.encode(<String, Object>{
        'flutter.selected_music_folders': <String>['/home/zoë/Música/日本の音楽'],
        'flutter.playlists': '[{"id":"p1","name":"Café del Mar"}]',
      }));
      final int cut = utf8
              .encode('{"flutter.selected_music_folders":["/home/zoë/Música/')
              .length +
          1;
      return whole.sublist(0, cut);
    }

    test('cut off inside a character: set aside, and the app carries on',
        () async {
      final List<int> cutOff = cutInsideACharacter();
      file.writeAsBytesSync(cutOff);

      final LinuxSharedPreferencesStore prefs = store();
      expect(await prefs.getAll(), isEmpty);
      expect(await prefs.setValue('String', 'flutter.theme', 'dark'), isTrue);

      expect(onDisk(), <String, Object?>{'flutter.theme': 'dark'});
      final List<File> setAside = directory
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.contains('.damaged-'))
          .toList();
      expect(setAside, hasLength(1));
      expect(setAside.single.readAsBytesSync(), cutOff);
    });

    test('cut off inside a character: the app can still save its playlists',
        () async {
      file.writeAsBytesSync(cutInsideACharacter());
      useLinuxSharedPreferencesStore(store());
      SharedPreferences.resetStatic();
      addTearDown(() {
        SharedPreferencesStorePlatform.instance =
            InMemorySharedPreferencesStore.empty();
        SharedPreferences.resetStatic();
      });

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('playlists', '[{"id":"p2","name":"New"}]');

      expect(onDisk()['flutter.playlists'], '[{"id":"p2","name":"New"}]');
    });

    test('empty: read as nothing saved, without failing', () async {
      file.writeAsStringSync('');

      expect(await store().getAll(), isEmpty);
    });
  });

  test('SharedPreferences reads and writes through it', () async {
    file.writeAsStringSync(json.encode(_pluginWritten));
    useLinuxSharedPreferencesStore(store());
    SharedPreferences.resetStatic();
    addTearDown(() {
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.empty();
      SharedPreferences.resetStatic();
    });

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('selected_music_folders'), <String>[
      '/home/me/Music',
      '/media/usb',
    ]);
    await prefs.setString('theme', 'dark');

    expect(onDisk()['flutter.theme'], 'dark');
  });
}
