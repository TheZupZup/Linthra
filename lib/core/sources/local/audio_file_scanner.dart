import 'dart:io';

import 'directory_readability.dart';
import 'folder_location.dart';
import 'folder_scan_exception.dart';
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
  /// recursively. Returns an empty list when the folder is missing.
  Future<List<String>> listFiles(String folder);
}

/// An [AudioFileScanner] backed by `dart:io` for real filesystem paths.
///
/// This is the desktop/Linux scanner and the final hop for any Android folder
/// that resolves to a path. It does not understand `content://` URIs — routing
/// is [PlatformAudioFileScanner]'s job.
class IoAudioFileScanner implements AudioFileScanner {
  const IoAudioFileScanner();

  @override
  Future<List<String>> listFiles(String folder) async {
    final Directory directory = Directory(folder);
    if (!await directory.exists()) {
      return const <String>[];
    }

    final List<String> paths = <String>[];
    final Stream<FileSystemEntity> entities = directory.list(
      recursive: true,
      followLinks: false,
    );
    await for (final FileSystemEntity entity in entities) {
      if (entity is File) {
        paths.add(entity.absolute.path);
      }
    }
    return paths;
  }
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
    if (!await _readability.canList(path)) {
      throw FolderScanException(
        'Linthra resolved this folder to "$path", but Android is not letting '
        'it read that location. Picking a folder through the system chooser '
        'does not by itself grant read access on Android 11+, where shared '
        'storage is sandboxed. Choose a folder the app can already read, or '
        'wait for the upcoming Storage Access Framework support.',
        folder: folder,
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
/// This is the only place that knows about the platform split.
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
    }
  }
}
