import '../models/jellyfin_session.dart';
import '../models/lyrics.dart';
import '../models/track.dart';
import '../sources/jellyfin/jellyfin_client.dart';
import '../sources/jellyfin/jellyfin_track_mapper.dart';
import '../sources/music_provider.dart';
import 'lyrics_provider.dart';

/// The [LyricsProvider] backed by a signed-in Jellyfin server.
///
/// The [LyricsResolver] only routes Jellyfin-owned tracks here; the scheme
/// check below is the parse guard for extracting the item id from a
/// `jellyfin:<id>` URI, and doubles as a safety net if the class is ever used
/// outside the resolver. A non-Jellyfin track, or being signed out, returns
/// `null` so the UI shows "no lyrics". The session (with its token) is read
/// lazily through [_session] so signing in/out is picked up without a rebuild,
/// mirroring the streaming/download path.
class JellyfinLyricsProvider implements LyricsProvider {
  JellyfinLyricsProvider({
    required JellyfinClient client,
    required JellyfinSession? Function() session,
  })  : _client = client,
        _session = session;

  final JellyfinClient _client;
  final JellyfinSession? Function() _session;

  @override
  String get sourceId => MusicProviders.jellyfin.sourceId;

  @override
  Future<Lyrics?> lyricsFor(Track track) async {
    if (!track.uri.startsWith(JellyfinTrackMapper.uriScheme)) return null;
    final JellyfinSession? session = _session();
    if (session == null) return null;
    final String itemId =
        track.uri.substring(JellyfinTrackMapper.uriScheme.length);
    return _client.fetchLyrics(session, itemId);
  }
}
