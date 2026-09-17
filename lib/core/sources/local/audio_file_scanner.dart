import 'dart:io';

import 'directory_readability.dart';
import 'folder_location.dart';
import 'folder_scan_exception.dart';
import 'local_root_fault.dart';
import 'saf_tree_uri_resolver.dart';

/// Discovers files under a folder on the device.
///
/// This is the single seam through which the local source touches storage.
/// Isolating it keeps the source's discovery/mapping logic pure enough to
/// unit-test against a fake. Deciding which files are audio is the caller's
/// job, not the scanner's.
///
/// A [folder] is whatever the picker returned: a desktop filesystem path or an
/// Android SAF `content://` tree URI. [PlatformAudioFileScanner] routes each to
/// the implementation that can handle it, so [LocalMusicSource] stays unaware
/// of the platform split. Implementations throw [FolderScanException] when a
/// folder cannot be scanned.
abstract interface class AudioFileScanner {
  /// Returns the absolute paths of every regular file under [folder], searched
  /// recursively. Throws [FolderScanException] when the selected folder itself
  /// cannot be opened — it is missing, or access to it was revoked — so a lost
  /// folder surfaces as a recoverable error instead of an empty result that
  /// would be persisted as "this folder has no music".
  Future<List<String>> listFiles(String folder);
}

/// An [AudioFileScanner] backed by `dart:io` for real filesystem paths.
///
/// This is the desktop/Linux scanner and the final hop for any Android folder
/// that resolves to a path. It does not understand `content://` URIs — routing
/// is [PlatformAudioFileScanner]'s job.
class IoAudioFileScanner implements AudioFileScanner {
  const IoAudioFileScanner({
    DirectoryReadability presence = const IoDirectoryReadability(),
  }) : _presence = presence;

  /// Asks whether the selected folder is still readable once the walk is done.
  /// Injected so "the drive was pulled mid-scan" can be reproduced in a test
  /// without a drive to pull.
  final DirectoryReadability _presence;

  @override
  Future<List<String>> listFiles(String folder) async {
    // Walk one directory at a time (rather than `list(recursive: true)`) so a
    // single unreadable *subfolder* — common under scoped storage / on removable
    // SD cards — is skipped instead of aborting the whole scan and zeroing out
    // the library. `followLinks: false` keeps symlinked directories from being
    // descended, avoiding cycles.
    //
    // The selected *root* is different: if it cannot be listed at all (it is
    // gone, the mount went away, access was revoked), surface that as a failure
    // rather than returning an empty list. An empty result would be persisted
    // as a successful "no music" scan and wipe a catalog the user's files are
    // still behind.
    //
    // The root's own failure is classified rather than merely reported: a
    // folder that was deleted, one this process may not read, and one whose
    // storage stopped answering have three different fixes, and the errno the
    // walk already has is the only place that distinction exists. It travels
    // on the exception's [FolderScanException.code], never as raw OS text.
    final List<String> paths = <String>[];
    final List<Directory> pending = <Directory>[Directory(folder)];
    bool isRoot = true;
    while (pending.isNotEmpty) {
      final Directory directory = pending.removeLast();
      final bool wasRoot = isRoot;
      isRoot = false;
      try {
        await for (final FileSystemEntity entity in directory.list(
          followLinks: false,
        )) {
          if (entity is File) {
            paths.add(entity.absolute.path);
          } else if (entity is Directory) {
            pending.add(entity);
          }
        }
      } on FileSystemException catch (error) {
        if (wasRoot) {
          throw rootFaultException(folder, classifyFilesystemFault(error));
        }
        // Unreadable subtree: skip it and keep scanning the rest.
        continue;
      }
    }

    // The walk only means something if the folder was still there at the end of
    // it, and a drive unplugged *mid-scan* is exactly the case where it wasn't.
    // Every directory still pending when the mount went away fails, and the rule
    // just above deliberately skips those, because one unreadable subfolder must
    // not fail a whole scan. Without this check that half-walk would be reported as
    // a complete one, and every file it never reached would be concluded
    // deleted: a drive being unplugged would delete the user's index of it,
    // which is the one thing that must never happen. So a folder that has gone
    // away since the walk began is reported exactly like one that was already
    // gone: unavailable, keep what is indexed.
    final LocalRootFault? interrupted = await _presence.inspect(folder);
    if (interrupted != null) {
      throw FolderScanException(
        "Linthra couldn't finish reading the selected folder. The drive may "
        'have been disconnected while it was being scanned. Reconnect it, or '
        'try selecting the folder again.',
        folder: folder,
        code: interrupted.code,
      );
    }
    return paths;
  }
}

/// The recoverable failure to raise for a selected folder that could not be
/// read, worded for [fault].
///
/// One place, so the message a user reads and the [FolderScanException.code]
/// that availability and diagnostics branch on can never describe two different
/// problems. No path, no errno and no OS string goes into the message: the
/// folder travels separately in [FolderScanException.folder], which the UI does
/// not render.
FolderScanException rootFaultException(String folder, LocalRootFault fault) {
  final String message;
  switch (fault) {
    case LocalRootFault.missing:
      message = "Linthra couldn't find the selected folder. It may have been "
          'moved or removed, the drive may not be connected, or access to it '
          'was revoked. Try selecting the folder again.';
    case LocalRootFault.permissionDenied:
      message = "Linthra isn't allowed to read the selected folder. Its "
          'permissions may have changed, or access to it was revoked. Check '
          'the folder permissions, or select the folder again.';
    case LocalRootFault.unavailable:
      message = "Linthra couldn't reach the storage this folder is on. The "
          'drive or network share may be disconnected. Reconnect it and try '
          'again.';
    case LocalRootFault.unknown:
      message = "Linthra couldn't read the selected folder. Access to it may "
          'have been revoked, or the storage was removed. Try selecting the '
          'folder again.';
  }
  return FolderScanException(message, folder: folder, code: fault.code);
}

/// Scans an Android SAF `content://` tree URI by resolving it to a filesystem
/// path and delegating to a filesystem scanner.
///
/// This is the Android-capable scanner. It does not touch `dart:io` itself: it
/// resolves the URI with a [SafTreeUriResolver] and hands the resulting path to
/// an injected [AudioFileScanner] (the real one is [IoAudioFileScanner]).
///
/// Two cases throw [FolderScanException] so the user sees a clear message
/// instead of a silently empty library:
///
/// 1. The URI maps to no reachable path at all (cloud/document providers).
/// 2. The URI resolves to a path that this app is not allowed to read on this
///    device — the Android 11+ scoped-storage case, detected up front with a
///    [DirectoryReadability] probe. Without the probe a `dart:io` walk of an
///    unreadable directory just returns nothing, which looks like "no music
///    found" rather than the permission problem it is.
///
/// Walking SAF trees that scoped storage only exposes through the content
/// resolver is the documented native follow-up.
class ContentUriAudioFileScanner implements AudioFileScanner {
  const ContentUriAudioFileScanner({
    AudioFileScanner filesystemScanner = const IoAudioFileScanner(),
    SafTreeUriResolver resolver = const SafTreeUriResolver(),
    DirectoryReadability readability = const IoDirectoryReadability(),
  })  : _filesystemScanner = filesystemScanner,
        _resolver = resolver,
        _readability = readability;

  final AudioFileScanner _filesystemScanner;
  final SafTreeUriResolver _resolver;
  final DirectoryReadability _readability;

  @override
  Future<List<String>> listFiles(String folder) async {
    final String? path = _resolver.resolveToPath(folder);
    if (path == null) {
      throw FolderScanException(
        "This folder can't be scanned yet. It was shared through Android's "
        'Storage Access Framework, which Linthra cannot walk directly on this '
        'device. Try selecting a folder on your phone or SD card storage.',
        folder: folder,
      );
    }
    final LocalRootFault? fault = await _readability.inspect(path);
    if (fault != null) {
      throw FolderScanException(
        'Linthra resolved this folder to "$path", but Android is not letting '
        'it read that location. Picking a folder through the system chooser '
        'does not by itself grant read access on Android 11+, where shared '
        'storage is sandboxed. Choose a folder the app can already read, or '
        'wait for the upcoming Storage Access Framework support.',
        folder: folder,
        code: fault.code,
      );
    }
    return _filesystemScanner.listFiles(path);
  }
}

/// The default [AudioFileScanner]: routes each folder to the scanner that can
/// handle it based on whether it is a filesystem path or a `content://` URI.
///
/// Desktop/Linux selections are filesystem paths and go straight to
/// [IoAudioFileScanner], preserving existing behavior exactly. Android SAF
/// selections are `content://` URIs and go to [ContentUriAudioFileScanner].
/// MediaStore is handled before this scanner by [LocalMusicSource]; seeing that
/// sentinel here is a programming error and fails closed rather than treating it
/// as a filesystem path.
class PlatformAudioFileScanner implements AudioFileScanner {
  const PlatformAudioFileScanner({
    AudioFileScanner filesystemScanner = const IoAudioFileScanner(),
    AudioFileScanner contentUriScanner = const ContentUriAudioFileScanner(),
  })  : _filesystemScanner = filesystemScanner,
        _contentUriScanner = contentUriScanner;

  final AudioFileScanner _filesystemScanner;
  final AudioFileScanner _contentUriScanner;

  @override
  Future<List<String>> listFiles(String folder) {
    final FolderLocation location = FolderLocation.parse(folder);
    switch (location.kind) {
      case FolderLocationKind.filesystemPath:
        return _filesystemScanner.listFiles(folder);
      case FolderLocationKind.contentUri:
        return _contentUriScanner.listFiles(folder);
      case FolderLocationKind.androidMediaStore:
        throw FolderScanException(
          'Android MediaStore must be scanned through the media library bridge.',
          folder: folder,
          code: 'media_store_wrong_scanner',
        );
    }
  }
}
