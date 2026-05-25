import '../models/playback_source.dart';
import '../models/track.dart';
import 'playable_uri_resolver.dart';
import 'playback_diagnostics.dart';

/// Resolves on-device tracks — local file paths and Android SAF `content://`
/// document URIs — to a URI the audio engine can open.
///
/// This is the default resolver and the only one needed when no remote source
/// is connected. It does no I/O and never fails: a filesystem path becomes a
/// `file://` URI, and a `content://` URI is passed through unchanged for the
/// platform to open. Keeping local file playback on this simple path means it
/// is unaffected by remote-source resolution.
class LocalPlayableUriResolver implements PlayableUriResolver {
  const LocalPlayableUriResolver();

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
    PlaybackDiagnostics.resolved(
      source: 'local',
      resolver: 'LocalPlayableUriResolver',
      itemId: track.id,
    );
    return ResolvedPlayable(
      playableUriFor(track.uri),
      PlaybackSource.localFile,
    );
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
