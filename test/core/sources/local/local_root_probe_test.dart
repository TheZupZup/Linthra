// The one seam availability tracking touches storage through (#415): can this
// configured folder be reached right now?
//
// Each kind of selection is answered by the probe that already existed for it,
// so there is one rule set for "can Linthra read this folder?" rather than one
// for the Settings card and another for the removable-drive state.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/android_media_library.dart';
import 'package:linthra/core/sources/local/directory_readability.dart';
import 'package:linthra/core/sources/local/folder_location.dart';
import 'package:linthra/core/sources/local/local_root_fault.dart';
import 'package:linthra/core/sources/local/local_root_probe.dart';
import 'package:linthra/core/sources/local/saf_permission_probe.dart';

class _FakeReadability implements DirectoryReadability {
  _FakeReadability(this.readable, {this.fault = LocalRootFault.missing});

  bool readable;

  /// What a folder that cannot be listed reports. Staged per test, because
  /// telling the three kinds of failure apart is the whole point of the probe.
  final LocalRootFault fault;
  final List<String> asked = <String>[];

  @override
  Future<LocalRootFault?> inspect(String path) async {
    asked.add(path);
    return readable ? null : fault;
  }
}

class _ThrowingReadability implements DirectoryReadability {
  @override
  Future<LocalRootFault?> inspect(String path) async =>
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
  Future<bool> Function(String path)? holdsNoFiles,
}) {
  return PlatformLocalRootProbe(
    readability: readability ?? _FakeReadability(true),
    safPermissions: _FakeSafPermissions(safGranted),
    mediaLibrary: _FakeMediaLibrary(mediaPermission),
    probesFilesystemPaths: probesFilesystemPaths,
    holdsNoFiles: holdsNoFiles ?? (String _) async => false,
  );
}

void main() {
  group('PlatformLocalRootProbe', () {
    test('a filesystem folder that can be listed is available', () async {
      expect(
        await _probe().inspect('/media/usb/Music'),
        const LocalRootReading.available(),
      );
    });

    test('a filesystem folder that cannot be listed carries why', () async {
      // The error-UX half of #414: a folder that is gone, one this process may
      // not read, and one whose drive stopped answering are three different
      // problems with three different fixes, so the probe passes the kind
      // through rather than flattening it to "not usable".
      for (final LocalRootFault fault in LocalRootFault.values) {
        final probe = _probe(
          readability: _FakeReadability(false, fault: fault),
        );

        expect(
          await probe.inspect('/media/usb/Music'),
          LocalRootReading.blocked(fault),
          reason: '$fault should survive the probe',
        );
      }
    });

    test('it asks about the configured path and nothing else', () async {
      final readability = _FakeReadability(true);

      await _probe(readability: readability).inspect('/media/usb/Music');

      expect(readability.asked, <String>['/media/usb/Music']);
    });

    test('a path is not a question on a platform that does not read paths',
        () async {
      final probe = _probe(probesFilesystemPaths: false);

      expect(await probe.inspect('/storage/emulated/0/Music'), isNull);
    });

    test('a SAF tree is answered by its persisted grant', () async {
      const String tree = 'content://com.android.externalstorage.'
          'documents/tree/primary%3AMusic';

      expect(
        await _probe(safGranted: true).inspect(tree),
        const LocalRootReading.available(),
      );
      // A grant that is gone is a permission problem, never a missing folder:
      // the tree is still exactly where it was.
      expect(
        await _probe(safGranted: false).inspect(tree),
        const LocalRootReading.blocked(LocalRootFault.permissionDenied),
      );
      // Off Android nothing can see the grant, so nothing is claimed about it.
      expect(await _probe().inspect(tree), isNull);
    });

    test('the device library is answered by its permission', () async {
      expect(
        await _probe().inspect(FolderLocation.androidMediaStoreAudio),
        const LocalRootReading.available(),
      );
      expect(
        await _probe(mediaPermission: AndroidMusicPermissionStatus.denied)
            .inspect(FolderLocation.androidMediaStoreAudio),
        const LocalRootReading.blocked(LocalRootFault.permissionDenied),
      );
    });

    test('a blank selection is not a folder to answer for', () async {
      expect(await _probe().inspect(''), isNull);
      expect(await _probe().inspect('   '), isNull);
    });

    test('a probe that faults answers nothing rather than "gone"', () async {
      // A platform-channel hiccup or a dart:io fault learned nothing about the
      // drive. Reporting it as unavailable would make a library look
      // disconnected because a syscall misbehaved. It is also deliberately
      // distinct from a LocalRootFault.unknown reading, which is a failure the
      // platform really did see.
      final probe = _probe(readability: _ThrowingReadability());

      expect(await probe.inspect('/media/usb/Music'), isNull);
    });
  });

  group('whether a readable folder holds any files (#737)', () {
    test('is part of what a filesystem folder answers', () async {
      final List<String> asked = <String>[];
      final PlatformLocalRootProbe probe = _probe(
        holdsNoFiles: (String path) async {
          asked.add(path);
          return true;
        },
      );

      expect(
        await probe.inspect('/mnt/nas', askHoldsNothing: true),
        const LocalRootReading.available(holdsNothing: true),
      );
      expect(asked, <String>['/mnt/nas']);
    });

    test('is only asked when the caller wants it', () async {
      bool asked = false;
      final PlatformLocalRootProbe probe = _probe(
        holdsNoFiles: (String _) async => asked = true,
      );

      expect(
        await probe.inspect('/mnt/nas'),
        const LocalRootReading.available(),
      );
      expect(asked, isFalse);
    });

    test('is not asked of a folder that cannot be listed', () async {
      bool asked = false;
      final PlatformLocalRootProbe probe = _probe(
        readability: _FakeReadability(false),
        holdsNoFiles: (String _) async => asked = true,
      );

      expect(
        await probe.inspect('/mnt/nas', askHoldsNothing: true),
        const LocalRootReading.blocked(LocalRootFault.missing),
      );
      expect(asked, isFalse);
    });

    group('on disk', () {
      late Directory base;

      setUp(() async {
        base = await Directory.systemTemp.createTemp('linthra_holds_nothing');
      });

      tearDown(() async {
        if (await base.exists()) await base.delete(recursive: true);
      });

      test('an empty folder holds nothing', () async {
        expect(await holdsNoFilesOnDisk(base.path), isTrue);
      });

      test('nor does one with only empty folders in it', () async {
        await Directory('${base.path}/nas/Albums').create(recursive: true);
        await Directory('${base.path}/usb').create();

        expect(await holdsNoFilesOnDisk(base.path), isTrue);
      });

      test('a file anywhere under it is something', () async {
        await Directory('${base.path}/Artist/Album').create(recursive: true);
        await File('${base.path}/Artist/Album/cover.jpg').writeAsBytes(
          const <int>[1],
        );

        expect(await holdsNoFilesOnDisk(base.path), isFalse);
      });

      test('a folder it cannot look into is not called empty', () async {
        expect(await holdsNoFilesOnDisk('${base.path}/missing'), isFalse);
      });
    });
  });
}
