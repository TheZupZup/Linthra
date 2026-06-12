import '../models/lyrics.dart';
import '../models/subsonic_session.dart';
import '../models/track.dart';
import '../sources/music_provider.dart';
import '../sources/subsonic/subsonic_client.dart';
import '../sources/subsonic/subsonic_track_mapper.dart';
import 'lyrics_provider.dart';

/// The [LyricsProvider] backed by a signed-in Subsonic/Navidrome server.
///
/// The [LyricsResolver] only routes Subsonic-owned tracks here; the scheme
/// check below is the parse guard for extracting the song id from a
/// `subsonic:<id>` URI, and doubles as a safety net if the class is ever used
/// outside the resolver. A non-Subsonic track, or being signed out, returns
/// `null` so the UI shows "no lyrics". The session (with its salt+token) is
/// read lazily through [_session] so signing in/out is picked up without a
/// rebuild, mirroring [JellyfinLyricsProvider] and the streaming/download
/// path.
///
/// The track's title and artist are forwarded so the client can fall back to
/// the legacy `getLyrics` (artist + title) lookup on servers that don't
/// implement the OpenSubsonic `getLyricsBySongId` extension.
class SubsonicLyricsProvider implements LyricsProvider {
  SubsonicLyricsProvider({
    required SubsonicClient client,
    required SubsonicSession? Function() session,
  })  : _client = client,
        _session = session;

  final SubsonicClient _client;
  final SubsonicSession? Function() _session;

  @override
  String get sourceId => MusicProviders.subsonic.sourceId;

  @override
  Future<Lyrics?> lyricsFor(Track track) async {
    if (!track.uri.startsWith(SubsonicTrackMapper.uriScheme)) return null;
    final SubsonicSession? session = _session();
    if (session == null) return null;
    final String songId =
        track.uri.substring(SubsonicTrackMapper.uriScheme.length);
    return _client.fetchLyrics(
      session,
      songId,
      artist: track.artistName,
      title: track.title,
    );
  }
}
