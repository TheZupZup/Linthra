import 'dart:async';

import 'directory_readability.dart';
import 'folder_location.dart';
import 'folder_scan_exception.dart';
import 'local_root_fault.dart';
import 'native_audio_file_scanner.dart';
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
  /// opens it (a name that isn't valid UTF-8, see [NativeAudioFileScanner]) is
  /// left out of the result, and [onUnopenableName] is called for it, so it is
  /// never indexed as a song that can't play.
  Future<List<String>> listFiles(
    String folder, {
    void Function(String directory)? onUnreadableDirectory,
    void Function(String path)? onUnopenableName,
  });
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
/// an injected [AudioFileScanner] (the real one is [NativeAudioFileScanner]).
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
    AudioFileScanner filesystemScanner = const NativeAudioFileScanner(),
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
/// [NativeAudioFileScanner], preserving existing behavior exactly. Android SAF
/// selections are `content://` URIs and go to [ContentUriAudioFileScanner].
/// MediaStore is handled before this scanner by [LocalMusicSource]; seeing that
/// sentinel here is a programming error and fails closed rather than treating it
/// as a filesystem path.
class PlatformAudioFileScanner implements AudioFileScanner {
  const PlatformAudioFileScanner({
    AudioFileScanner filesystemScanner = const NativeAudioFileScanner(),
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
