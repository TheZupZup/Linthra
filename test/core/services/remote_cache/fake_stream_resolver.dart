import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';

/// A **provider-neutral** fake [PlayableUriResolver] for the remote-cache
/// foundation tests.
///
/// It stands in for the Jellyfin/Subsonic/Plex routing resolver without any
/// provider client: it claims every known remote scheme (`jellyfin:`,
/// `subsonic:`, `plex:`) plus on-device tracks, and mints a **fresh, tokenized**
/// `https` URL per call so a served-from-cache result is provably the warmed one
/// rather than a re-resolve. It records every `resolve` call (by track id) so a
/// test can assert when the cache short-circuited the inner resolver, and can be
/// told to fail or to report a non-stream ([PlaybackSource.localFile]) source.
class FakeStreamResolver implements PlayableUriResolver {
  FakeStreamResolver({
    this.source = PlaybackSource.streamingDirect,
    this.fail = false,
    this.token = 'SECRET-TOKEN',
  });

  /// What every successful resolution reports as its source.
  PlaybackSource source;

  /// When true, every resolve throws a typed, secret-free playback error.
  bool fail;

  /// The secret woven into every minted URL's query — tests assert it never
  /// reaches a cache key, filename, metadata, or diagnostics string.
  final String token;

  /// Track ids passed to [resolve], in order.
  final List<String> resolved = <String>[];
  int _counter = 0;

  static const Set<String> _remoteSchemes = <String>{
    'jellyfin',
    'subsonic',
    'plex',
  };

  @override
  bool handles(Track track) {
    final String scheme = Uri.tryParse(track.uri)?.scheme.toLowerCase() ?? '';
    // Remote schemes, plus on-device tracks (a path with no scheme, or a
    // file:///content:// document) — mirroring the real catch-all router.
    return _remoteSchemes.contains(scheme) ||
        scheme.isEmpty ||
        scheme == 'file' ||
        scheme == 'content';
  }

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    resolved.add(track.id);
    if (fail) {
      throw const PlaybackResolutionException(
        "Couldn't reach your server.",
        kind: PlaybackResolutionErrorKind.serverUnreachable,
      );
    }
    _counter++;
    if (source == PlaybackSource.localFile) {
      return ResolvedPlayable(Uri.parse('file:///music/${track.id}'), source);
    }
    // A fresh, unique tokenized URL each time.
    return ResolvedPlayable(
      Uri.parse('https://server.example/stream/${track.id}'
          '?n=$_counter&api_key=$token'),
      source,
    );
  }
}
