import 'dart:io';

import '../models/playback_source.dart';
import '../models/track.dart';
import 'playable_uri_resolver.dart';
import 'playback_diagnostics.dart';

/// Answers whether an on-device file is still where the catalog says it is.
///
/// A seam, so the "the file vanished" behaviour can be tested without a disk.
/// [IoLocalFilePresence] is the production one.
abstract interface class LocalFilePresence {
  /// Whether a regular file exists at [path]. Must never throw: an unreadable
  /// parent directory, a broken symlink or a stale mount all answer `false`.
  bool existsAt(String path);
}

/// The production [LocalFilePresence]: one `stat`, straight through `dart:io`.
class IoLocalFilePresence implements LocalFilePresence {
  const IoLocalFilePresence();

  @override
  bool existsAt(String path) {
    try {
      return File(path).existsSync();
    } catch (_) {
      // A path the OS refuses to stat at all (a dead NFS/SMB mount, a revoked
      // portal document) is, for playback purposes, not there.
      return false;
    }
  }
}

/// Resolves on-device tracks — local file paths and Android SAF `content://`
/// document URIs — to a URI the audio engine can open.
///
/// This is the default resolver and the only one needed when no remote source
/// is connected. A filesystem path becomes a `file://` URI, and a `content://`
/// URI is passed through unchanged for the platform to open. Keeping local file
/// playback on this simple path means it is unaffected by remote-source
/// resolution.
///
/// **The one thing it checks.** For a filesystem path it first asks whether the
/// file is still there, and raises
/// [PlaybackResolutionErrorKind.localFileMissing] when it is not. The engine
/// would fail on its own a moment later, but only with a generic "couldn't
/// play this track", which is the wrong thing to tell someone whose drive is
/// unplugged or who moved an album an hour ago. Failing here, before the engine
/// is handed anything, also keeps the queue exactly as it was: the transition
/// ends in an error state on a track that is still in its place, and skipping
/// past it works normally.
///
/// `content://` documents are deliberately *not* probed: answering "does this
/// document exist" means a content-resolver round trip through the platform
/// channel on every single track load, and Android already reports a revoked or
/// deleted document clearly through the open itself.
class LocalPlayableUriResolver implements PlayableUriResolver {
  const LocalPlayableUriResolver({
    LocalFilePresence presence = const IoLocalFilePresence(),
  }) : _presence = presence;

  final LocalFilePresence _presence;

  /// Remote schemes this on-device resolver must NOT claim, so their own
  /// resolvers (composed ahead of this one) handle them. Anything else is
  /// treated as an on-device file path or `content://` document.
  static const Set<String> _remoteSchemes = <String>{'jellyfin', 'subsonic'};

  @override
  bool handles(Track track) {
    final Uri? uri = Uri.tryParse(track.uri);
    return !_remoteSchemes.contains(uri?.scheme.toLowerCase() ?? '');
  }

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    final Uri playable = playableUriFor(track.uri);
    if (playable.isScheme('file') &&
        !_presence.existsAt(playable.toFilePath())) {
      throw const PlaybackResolutionException(
        "This file isn't where Linthra last saw it. It may have been moved or "
        'deleted, or the drive it lives on may not be connected. Rescan your '
        'music folders to update the library.',
        kind: PlaybackResolutionErrorKind.localFileMissing,
      );
    }
    PlaybackDiagnostics.resolved(
      source: 'local',
      resolver: 'LocalPlayableUriResolver',
      itemId: track.id,
    );
    return ResolvedPlayable(playable, PlaybackSource.localFile);
  }

  /// Maps a stored on-device [trackUri] to a playable URI: a `content://` URI
  /// (an Android SAF document) is opened as-is; everything else is treated as a
  /// filesystem path and wrapped as a `file://` URI.
  static Uri playableUriFor(String trackUri) {
    final Uri? parsed = Uri.tryParse(trackUri);
    if (parsed != null && parsed.scheme.toLowerCase() == 'content') {
      return parsed;
    }
    return Uri.file(trackUri);
  }
}
