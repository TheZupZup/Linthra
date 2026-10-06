// A saved queue whose store can't be read at launch is kept for later.
//
// Restore clears a record it can't use, so a bad record can't fail every
// launch. But it cleared on any failure, including the store itself failing
// to read: the Linux preferences file answering one read with an I/O error
// (a network or FUSE home directory, a flaky disk). The clear asks the store
// again, that read went through, and the user's saved queue was deleted from
// a file that held it whole.
//
// Staged with the real Linux preferences store over a temp folder, and
// IOOverrides failing the first read of its file with EIO.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/services/playback_session_persistence.dart';
import 'package:linthra/data/repositories/linux_shared_preferences_store.dart';
import 'package:linthra/data/repositories/shared_preferences_playback_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../../features/player/fake_playback_controller.dart';

const String _session = '{"v":1,"i":0,"p":42000,"t":['
    '{"id":"/music/Holocene.flac","title":"Holocene",'
    '"uri":"/music/Holocene.flac","durationMs":336000}]}';

final class _FirstReadFails extends IOOverrides {
  _FirstReadFails(this.path);

  final String path;
  int failures = 1;

  @override
  File createFile(String path) {
    final File real = super.createFile(path);
    return path == this.path ? _FlakyRead(real, this) : real;
  }
}

class _FlakyRead implements File {
  _FlakyRead(this._real, this._io);

  final File _real;
  final _FirstReadFails _io;

  @override
  String get path => _real.path;

  @override
  Directory get parent => _real.parent;

  @override
  bool existsSync() => _real.existsSync();

  @override
  Uint8List readAsBytesSync() {
    if (_io.failures > 0) {
      _io.failures--;
      throw FileSystemException(
        'Cannot read file',
        path,
        const OSError('Input/output error', 5),
      );
    }
    return _real.readAsBytesSync();
  }

  @override
  File renameSync(String newPath) => _real.renameSync(newPath);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late File file;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('linthra_session_eio_');
    file = File('${directory.path}/${LinuxSharedPreferencesStore.fileName}')
      ..writeAsStringSync(json.encode(<String, Object>{
        'flutter.${SharedPreferencesPlaybackSessionStore.key}': _session,
      }));
    useLinuxSharedPreferencesStore(
      LinuxSharedPreferencesStore(directory: () async => directory.path),
    );
    SharedPreferences.resetStatic();
  });

  tearDown(() {
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    SharedPreferences.resetStatic();
    directory.deleteSync(recursive: true);
  });

  test('a read that fails at launch leaves the saved queue in place', () async {
    final FakePlaybackController controller = FakePlaybackController();
    addTearDown(controller.dispose);

    await IOOverrides.runWithIOOverrides(() async {
      final PlaybackSessionPersistence persistence = PlaybackSessionPersistence(
        store: const SharedPreferencesPlaybackSessionStore(),
        controller: controller,
        playbackStates: const Stream<PlaybackState>.empty(),
        localFileExists: (_) => true,
      );
      await persistence.restore();
      await persistence.dispose();
    }, _FirstReadFails(file.path));

    final Map<String, Object?> onDisk =
        (json.decode(file.readAsStringSync()) as Map).cast<String, Object?>();
    expect(
      onDisk['flutter.${SharedPreferencesPlaybackSessionStore.key}'],
      _session,
      reason: 'the saved queue was deleted',
    );
  });
}
