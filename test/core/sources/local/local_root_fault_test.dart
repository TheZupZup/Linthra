// Telling apart the three ways a local music folder stops being readable
// (#414).
//
// The distinction is the whole feature: "the folder is gone", "you may not read
// it" and "the drive isn't answering" have three different fixes, and a user
// looking at a library that went quiet deserves the right one. This is the one
// place an errno is looked at, so it is also the one place that can get it
// wrong.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/local_root_fault.dart';

FileSystemException _failure(int errorCode) {
  return FileSystemException(
    'Directory listing failed',
    '/media/usb/Music',
    OSError('something the OS said', errorCode),
  );
}

void main() {
  group('classifyFilesystemFault', () {
    test('a folder that is not there is missing', () {
      // ENOENT: the drive was unmounted, the folder was deleted, or the Flatpak
      // portal document that exposed it was revoked.
      expect(classifyFilesystemFault(_failure(2)), LocalRootFault.missing);
      // ENOTDIR: something on the way stopped being a directory, which from
      // here is the same "this path no longer names your music folder".
      expect(classifyFilesystemFault(_failure(20)), LocalRootFault.missing);
    });

    test('a folder this process may not read is a permission problem', () {
      expect(
        classifyFilesystemFault(_failure(13)), // EACCES
        LocalRootFault.permissionDenied,
      );
      expect(
        classifyFilesystemFault(_failure(1)), // EPERM
        LocalRootFault.permissionDenied,
      );
    });

    test('storage that stopped answering is its own kind', () {
      // A network share that went down, a stale mount, a device returning I/O
      // errors. Not the user's doing and usually not the user's to fix, which
      // is exactly why it must not be reported as a missing folder.
      for (final int errno in <int>[
        5, // EIO
        19, // ENODEV
        100, // ENETDOWN
        107, // ENOTCONN
        110, // ETIMEDOUT
        116, // ESTALE
      ]) {
        expect(
          classifyFilesystemFault(_failure(errno)),
          LocalRootFault.unavailable,
          reason: 'errno $errno should read as unresponsive storage',
        );
      }
    });

    test('a code nothing here recognises is honestly unknown', () {
      // Guessing would be worse than admitting it: the UI has a wording for
      // "the system did not say why", and it does not send anyone to reconnect
      // a drive that is sitting right there.
      expect(classifyFilesystemFault(_failure(9999)), LocalRootFault.unknown);
      expect(
        classifyFilesystemFault(
          const FileSystemException('no OSError at all'),
        ),
        LocalRootFault.unknown,
      );
      expect(
        classifyFilesystemFault(StateError('not a filesystem failure')),
        LocalRootFault.unknown,
      );
    });
  });

  group('fault codes', () {
    test('every fault has a stable code that round-trips', () {
      // The code is how the scanner hands a diagnosis to availability tracking
      // without either importing the other's error type, so a fault that lost
      // its code would silently become "unknown" in the UI.
      for (final LocalRootFault fault in LocalRootFault.values) {
        expect(LocalRootFault.fromCode(fault.code), fault);
      }
    });

    test('codes are distinct', () {
      expect(
        LocalRootFault.values.map((LocalRootFault f) => f.code).toSet(),
        hasLength(LocalRootFault.values.length),
      );
    });

    test('a code from somewhere else is not adopted', () {
      expect(LocalRootFault.fromCode(null), isNull);
      expect(LocalRootFault.fromCode('media_store_wrong_scanner'), isNull);
    });

    test('a fault carries no message, path or errno', () {
      // Nothing from the OS may ride into the UI on this. The enum has no field
      // for it, and its code is a fixed word. This is the assertion that keeps
      // someone from adding one later.
      for (final LocalRootFault fault in LocalRootFault.values) {
        expect(fault.code, matches(RegExp(r'^[a-z_]+$')));
      }
    });
  });
}
