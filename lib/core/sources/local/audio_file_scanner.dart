import 'dart:async';
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
  ///
  /// A subfolder that cannot be listed is skipped instead of failing the whole
  /// walk, and [onUnreadableDirectory] is called with its absolute path. The
  /// result is then only part of the folder, and the caller has to know which
  /// part is missing: a file under a skipped subfolder was not found, which is
  /// not the same as not being there.
  ///
  /// A file or folder whose name the platform can't hand over as a path that
  /// opens it (a name that isn't valid UTF-8, see [IoAudioFileScanner]) is
  /// left out of the result, and [onUnopenableName] is called for it, so it is
  /// never indexed as a song that can't play.
  Future<List<String>> listFiles(
    String folder, {
    void Function(String directory)? onUnreadableDirectory,
    void Function(String path)? onUnopenableName,
  });
}

/// An [AudioFileScanner] backed by `dart:io` for real filesystem paths.
///
/// This is the desktop/Linux scanner and the final hop for any Android folder
/// that resolves to a path. It does not understand `content://` URIs — routing
/// is [PlatformAudioFileScanner]'s job.
class IoAudioFileScanner implements AudioFileScanner {
  const IoAudioFileScanner({
    DirectoryReadability presence = const IoDirectoryReadability(),
    Duration stallLimit = storageStallLimit,
  })  : _presence = presence,
        _stallLimit = stallLimit;

  /// Asks whether the selected folder is still readable once the walk is done.
  /// Injected so "the drive was pulled mid-scan" can be reproduced in a test
  /// without a drive to pull.
  final DirectoryReadability _presence;

  /// How long a directory listing may go without its next entry before that
  /// directory counts as not answering. See [storageStallLimit].
  final Duration _stallLimit;

  @override
  Future<List<String>> listFiles(
    String folder, {
    void Function(String directory)? onUnreadableDirectory,
    void Function(String path)? onUnopenableName,
  }) async {
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
        await for (final FileSystemEntity entity
            in directory.list(followLinks: false).timeout(_stallLimit)) {
          if (await _namesNothing(entity)) {
            onUnopenableName?.call(entity.path);
            continue;
          }
          if (entity is File) {
            paths.add(entity.absolute.path);
          } else if (entity is Directory) {
            pending.add(entity);
          }
        }
      } on TimeoutException {
        // The storage stopped answering mid-listing: a share whose server went
        // away blocks it for as long as the mount retries (#778). The listing
        // stays blocked on its I/O thread; the walk doesn't wait for it.
        if (wasRoot) {
          throw rootFaultException(folder, LocalRootFault.unavailable);
        }
        // Deeper down, it can be a share mounted inside the music folder that
        // went away on its own, skipped like any unreadable subfolder. Or it
        // is the whole folder, and every directory still pending would stall
        // the same way, one limit at a time: the folder itself says which.
        onUnreadableDirectory?.call(directory.absolute.path);
        final LocalRootFault? gone = await _inspect(folder);
        if (gone != null) throw interruptedScanException(folder, gone);
        continue;
      } on FileSystemException catch (error) {
        if (wasRoot) {
          throw rootFaultException(folder, classifyFilesystemFault(error));
        }
        // Unreadable subtree: skip it and keep scanning the rest, but say
        // which one. Every file under it is missing from the result, and a
        // caller that cannot tell "not listed" from "not there" would conclude
        // they were all deleted. It may be a subfolder whose permissions
        // changed, a network mount inside the music folder that went stale,
        // or one deleted while the walk was running; only a later walk that
        // lists its parent can tell the last case apart.
        onUnreadableDirectory?.call(directory.absolute.path);
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
    final LocalRootFault? interrupted = await _inspect(folder);
    if (interrupted != null) {
      throw interruptedScanException(folder, interrupted);
    }
    return paths;
  }

  /// Whether [entity]'s path names nothing on disk, though the listing just
  /// found it there (#817).
  ///
  /// A name that isn't valid UTF-8 (Latin-1 bytes from an old Windows rip
  /// copied with tar, a share mounted without a UTF-8 charset) reaches Dart
  /// with U+FFFD in place of each byte it couldn't decode, and that string
  /// names no file: it can't be stat'ed, read, played or listed. Carrying the
  /// raw bytes instead would have to reach the catalog, the queue, playlists,
  /// downloads, the saved session and the audio engine, which all hold paths
  /// as text. So such an entry is left out and reported rather than indexed
  /// as a song that can never play, or walked as a folder that can never be
  /// listed. A name that really contains U+FFFD opens fine and is kept.
  Future<bool> _namesNothing(FileSystemEntity entity) async {
    if (!entity.path.contains('\uFFFD')) return false;
    final FileSystemEntityType type = await FileSystemEntity.type(
      entity.path,
      followLinks: false,
    ).timeout(_stallLimit, onTimeout: () => FileSystemEntityType.notFound);
    return type == FileSystemEntityType.notFound;
  }

  /// Why [folder] can't be listed now, a folder that doesn't answer within
  /// [_stallLimit] being [LocalRootFault.unavailable].
  Future<LocalRootFault?> _inspect(String folder) => _presence
      .inspect(folder)
      .timeout(_stallLimit, onTimeout: () => LocalRootFault.unavailable);
}

/// The recoverable failure to raise for a selected folder that went away, or
/// stopped answering, while it was being scanned.
FolderScanException interruptedScanException(
  String folder,
  LocalRootFault fault,
) =>
    FolderScanException(
      "Linthra couldn't finish reading the selected folder. The drive may "
      'have been disconnected while it was being scanned. Reconnect it, or '
      'try selecting the folder again.',
      folder: folder,
      code: fault.code,
    );

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
    case LocalRootFault.empty:
      message = 'The selected folder is empty, though your library has music '
          "from it. If it's a drive or network share, it may not be mounted. "
          'Its music was kept.';
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
  Future<List<String>> listFiles(
    String folder, {
    void Function(String directory)? onUnreadableDirectory,
    void Function(String path)? onUnopenableName,
  }) async {
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
    return _filesystemScanner.listFiles(
      path,
      onUnreadableDirectory: onUnreadableDirectory,
      onUnopenableName: onUnopenableName,
    );
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
  Future<List<String>> listFiles(
    String folder, {
    void Function(String directory)? onUnreadableDirectory,
    void Function(String path)? onUnopenableName,
  }) {
    final FolderLocation location = FolderLocation.parse(folder);
    switch (location.kind) {
      case FolderLocationKind.filesystemPath:
        return _filesystemScanner.listFiles(
          folder,
          onUnreadableDirectory: onUnreadableDirectory,
          onUnopenableName: onUnopenableName,
        );
      case FolderLocationKind.contentUri:
        return _contentUriScanner.listFiles(
          folder,
          onUnreadableDirectory: onUnreadableDirectory,
          onUnopenableName: onUnopenableName,
        );
      case FolderLocationKind.androidMediaStore:
        throw FolderScanException(
          'Android MediaStore must be scanned through the media library bridge.',
          folder: folder,
          code: 'media_store_wrong_scanner',
        );
    }
  }
}
