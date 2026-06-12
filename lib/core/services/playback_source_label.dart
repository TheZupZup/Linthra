import '../models/playback_source.dart';
import '../sources/music_provider.dart';

/// Safe, human-readable names for *where playback is actually coming from*, for
/// the now-playing source indicator.
///
/// A logical track can have several source candidates, so the indicator must
/// reflect the copy the resolver actually played — not the active/default
/// provider. The value is derived from the resolved track's opaque URI (which
/// provider owns it) and the [PlaybackSource] the resolver reported (a cache hit
/// vs a live stream vs an on-device file).
///
/// Security: only fixed, non-identifying display names are ever returned —
/// "Navidrome", "Jellyfin", "Plex", "Local music", "Cache", or "Unknown
/// source". A server URL, IP, username, token, or file path is never exposed.
abstract final class PlaybackSourceLabel {
  static const String navidrome = 'Navidrome';
  static const String jellyfin = 'Jellyfin';
  static const String plex = 'Plex';
  static const String local = 'Local music';
  static const String cache = 'Cache';
  static const String unknown = 'Unknown source';

  /// The safe display name for audio resolved from [trackUri] via [source].
  ///
  /// A cached copy reads as "Cache" regardless of which server it came from
  /// (that is what the listener is hearing); an on-device file reads as "Local
  /// music"; a live stream reads as the owning server's safe name.
  static String of(
      {required String? trackUri, required PlaybackSource? source}) {
    if (source == null) return unknown;
    switch (source) {
      case PlaybackSource.offlineCache:
        return cache;
      case PlaybackSource.localFile:
        return local;
      case PlaybackSource.streamingDirect:
        return _serverName(trackUri);
    }
  }

  /// The safe name of the server that owns [trackUri], for a live stream.
  static String _serverName(String? trackUri) {
    if (trackUri == null) return unknown;
    switch (MusicProviders.forTrackUri(trackUri).sourceId) {
      case 'jellyfin':
        return jellyfin;
      case 'subsonic':
        return navidrome;
      case 'plex':
        return plex;
      case 'local':
        // An on-device file should resolve as localFile, not streamingDirect;
        // reaching here means an unexpected pairing, so stay vague but safe.
        return local;
      default:
        return unknown;
    }
  }

  /// "Playing from X" — the full phrase the indicator shows.
  static String phrase(
          {required String? trackUri, required PlaybackSource? source}) =>
      'Playing from ${of(trackUri: trackUri, source: source)}';
}
