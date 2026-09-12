// The one seam availability tracking touches storage through (#415): can this
// configured folder be reached right now?
//
// Each kind of selection is answered by the probe that already existed for it,
// so there is one rule set for "can Linthra read this folder?" rather than one
// for the Settings card and another for the removable-drive state.
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/android_media_library.dart';
import 'package:linthra/core/sources/local/directory_readability.dart';
import 'package:linthra/core/sources/local/folder_location.dart';
import 'package:linthra/core/sources/local/local_root_probe.dart';
import 'package:linthra/core/sources/local/saf_permission_probe.dart';

class _FakeReadability implements DirectoryReadability {
  _FakeReadability(this.readable);

  bool readable;
  final List<String> asked = <String>[];

  @override
  Future<bool> canList(String path) async {
    asked.add(path);
    return readable;
  }
}

class _ThrowingReadability implements DirectoryReadability {
  @override
  Future<bool> canList(String path) async =>
      throw StateError('the probe itself broke');
}

class _FakeSafPermissions implements SafPermissionProbe {
  _FakeSafPermissions(this.granted);

  bool? granted;

  @override
  Future<bool?> hasPersistedPermission(String treeUri) async => granted;
}

class _FakeMediaLibrary extends UnsupportedAndroidMediaLibrary {
  _FakeMediaLibrary(this.status);

  final AndroidMusicPermissionStatus status;

  @override
  Future<AndroidMusicPermissionStatus> permissionStatus() async => status;
}

PlatformLocalRootProbe _probe({
  DirectoryReadability? readability,
  bool? safGranted,
  AndroidMusicPermissionStatus mediaPermission =
      AndroidMusicPermissionStatus.allowed,
  bool probesFilesystemPaths = true,
}) {
  return PlatformLocalRootProbe(
    readability: readability ?? _FakeReadability(true),
    safPermissions: _FakeSafPermissions(safGranted),
    mediaLibrary: _FakeMediaLibrary(mediaPermission),
    probesFilesystemPaths: probesFilesystemPaths,
  );
}

void main() {
  group('PlatformLocalRootProbe', () {
    test('a filesystem folder that can be listed is available', () async {
      expect(await _probe().isAvailable('/media/usb/Music'), isTrue);
    });

    test('a filesystem folder that cannot be listed is unavailable', () async {
      // Missing and unreadable are the same answer here: not usable right now.
      // Which of the two it was is the error-UX question (#414), and it is the
      // scan report that carries it.
      final probe = _probe(readability: _FakeReadability(false));

      expect(await probe.isAvailable('/media/usb/Music'), isFalse);
    });

    test('it asks about the configured path and nothing else', () async {
      final readability = _FakeReadability(true);

      await _probe(readability: readability).isAvailable('/media/usb/Music');

      expect(readability.asked, <String>['/media/usb/Music']);
    });

    test('a path is not a question on a platform that does not read paths',
        () async {
      final probe = _probe(probesFilesystemPaths: false);

      expect(await probe.isAvailable('/storage/emulated/0/Music'), isNull);
    });

    test('a SAF tree is answered by its persisted grant', () async {
      const String tree = 'content://com.android.externalstorage.'
          'documents/tree/primary%3AMusic';

      expect(await _probe(safGranted: true).isAvailable(tree), isTrue);
      expect(await _probe(safGranted: false).isAvailable(tree), isFalse);
      // Off Android nothing can see the grant, so nothing is claimed about it.
      expect(await _probe().isAvailable(tree), isNull);
    });

    test('the device library is answered by its permission', () async {
      expect(
        await _probe().isAvailable(FolderLocation.androidMediaStoreAudio),
        isTrue,
      );
      expect(
        await _probe(mediaPermission: AndroidMusicPermissionStatus.denied)
            .isAvailable(FolderLocation.androidMediaStoreAudio),
        isFalse,
      );
    });

    test('a blank selection is not a folder to answer for', () async {
      expect(await _probe().isAvailable(''), isNull);
      expect(await _probe().isAvailable('   '), isNull);
    });

    test('a probe that faults answers nothing rather than "gone"', () async {
      // A platform-channel hiccup or a dart:io fault learned nothing about the
      // drive. Reporting it as unavailable would make a library look
      // disconnected because a syscall misbehaved.
      final probe = _probe(readability: _ThrowingReadability());

      expect(await probe.isAvailable('/media/usb/Music'), isNull);
    });
  });
}
