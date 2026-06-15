import '../models/lyrics.dart';
import '../models/plex_session.dart';
import '../models/track.dart';
import '../sources/music_provider.dart';
import '../sources/plex/plex_client.dart';
import '../sources/plex/plex_track_mapper.dart';
import 'lyrics_provider.dart';

/// The [LyricsProvider] backed by a signed-in Plex Media Server.
///
/// The [LyricsResolver] only routes Plex-owned tracks here; the scheme check
/// below is the parse guard for extracting the `ratingKey` from a
/// `plex:<ratingKey>` URI, and doubles as a safety net if the class is ever used
/// outside the resolver. A non-Plex track, or being signed out, returns `null`
/// so the UI shows "no lyrics". The session (server URL + token) is read lazily
/// through [_session] so connecting/disconnecting is picked up without a
/// rebuild, mirroring [JellyfinLyricsProvider] / [SubsonicLyricsProvider] and
/// the streaming path.
///
/// Fetching is two steps off the playback path — locate the track's lyric
/// stream, then fetch and parse it — owned by the [PlexClient] along with the
/// token-safety rules: it returns `null` for "no lyrics" and throws a token-free
/// `PlexException` only for a real transport/auth failure, which the resolver
/// surfaces as the calm "couldn't load" state.
class PlexLyricsProvider implements LyricsProvider {
  PlexLyricsProvider({
    required PlexClient client,
    required PlexSession? Function() session,
  })  : _client = client,
        _session = session;

  final PlexClient _client;
  final PlexSession? Function() _session;

  @override
  String get sourceId => MusicProviders.plex.sourceId;

  @override
  Future<Lyrics?> lyricsFor(Track track) async {
    if (!track.uri.startsWith(PlexTrackMapper.uriScheme)) return null;
    final PlexSession? session = _session();
    if (session == null) return null;
    final String ratingKey =
        track.uri.substring(PlexTrackMapper.uriScheme.length);
    if (ratingKey.isEmpty) return null;
    return _client.fetchLyrics(
      baseUrl: session.baseUrl,
      token: session.token,
      ratingKey: ratingKey,
    );
  }
}
