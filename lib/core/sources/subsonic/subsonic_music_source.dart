import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/subsonic_session.dart';
import '../../models/track.dart';
import '../../services/music_source.dart';
import '../../services/playback_diagnostics.dart';
import 'subsonic_api.dart';
import 'subsonic_auth.dart';
import 'subsonic_client.dart';
import 'subsonic_endpoints.dart';
import 'subsonic_exception.dart';
import 'subsonic_stream_source.dart';
import 'subsonic_track_mapper.dart';

/// A [MusicSource] backed by a signed-in Subsonic-compatible server (Navidrome,
/// etc.).
///
/// The Subsonic counterpart to `JellyfinMusicSource`: it implements the same
/// `MusicSource` contract, so the rest of the app treats a Subsonic library
/// identically to a Jellyfin or on-device one. Discovery (listing items) is
/// delegated to a [SubsonicClient] and mapping to [SubsonicTrackMapper], keeping
/// this class a thin orchestrator.
///
/// Like the other sources, it does not persist anything itself — the
/// `MusicLibraryRepository` syncs these results into the offline cache the UI
/// reads from. Streaming/casting/downloading are wired through the narrow
/// [SubsonicStreamSource] seam, which mints a credential-bearing URL only on
/// demand at play/download time so the salt+token never reach the catalog.
///
/// Subsonic has no single "all songs" endpoint, so [fetchTracks] walks every
/// album (`getAlbumList2` then `getAlbum`) and flattens the songs — the standard
/// ID3 enumeration.
class SubsonicMusicSource implements MusicSource, SubsonicStreamSource {
  const SubsonicMusicSource({
    required this.session,
    required SubsonicClient client,
  }) : _client = client;

  /// The session this source reads on behalf of (server URL, user, credential).
  final SubsonicSession session;

  final SubsonicClient _client;

  /// The stable source id under which Subsonic tracks are stored. A single id
  /// covers any Subsonic-compatible server (the [displayName] reflects the
  /// specific product, e.g. Navidrome).
  static const String sourceId = 'subsonic';

  @override
  String get id => sourceId;

  @override
  String get displayName {
    final String? type = session.serverType;
    if (type != null && type.isNotEmpty) {
      return type[0].toUpperCase() + type.substring(1);
    }
    return 'Subsonic';
  }

  @override
  Future<List<Track>> fetchTracks() async {
    final List<SubsonicAlbumDto> albums = await _client.getAlbums(session);
    final List<Track> tracks = <Track>[];
    for (final SubsonicAlbumDto album in albums) {
      final List<SubsonicSongDto> songs =
          await _client.getAlbumSongs(session, album.id);
      for (final SubsonicSongDto song in songs) {
        tracks.add(SubsonicTrackMapper.toTrack(song));
      }
    }
    return tracks;
  }

  @override
  Future<List<Album>> fetchAlbums() async {
    final List<SubsonicAlbumDto> albums = await _client.getAlbums(session);
    return <Album>[
      for (final SubsonicAlbumDto album in albums)
        SubsonicTrackMapper.toAlbum(album),
    ];
  }

  @override
  Future<List<Artist>> fetchArtists() async {
    final List<SubsonicArtistDto> artists = await _client.getArtists(session);
    return <Artist>[
      for (final SubsonicArtistDto artist in artists)
        SubsonicTrackMapper.toArtist(artist),
    ];
  }

  @override
  Future<void> verifyReachable() => _client.verifySession(session);

  /// Mints the stream URL for [track] on demand, then probes it so a proxy page,
  /// a rejected credential, or a non-audio response becomes a precise error
  /// instead of an opaque engine failure. The credential is woven in here, at
  /// play time, never stored on the track.
  @override
  Future<Uri?> resolvePlayableUri(Track track) async {
    final Uri url = SubsonicEndpoints.stream(
      session.baseUrl,
      username: session.username,
      credentials: _credentials,
      songId: _songId(track),
    );
    final SubsonicStreamProbe probe = await _client.probeStream(url);
    PlaybackDiagnostics.resolved(
      source: 'subsonic',
      resolver: 'SubsonicPlayableUriResolver',
      itemId: _songId(track),
      statusCode: probe.statusCode,
      contentType: probe.contentType,
    );
    _ensurePlayableAudio(probe);
    return url;
  }

  /// Mints the original-file download URL for [track] on demand. No probe: the
  /// downloader reads the response status itself, mirroring Jellyfin.
  @override
  Future<Uri?> resolveDownloadUri(Track track) async {
    return SubsonicEndpoints.download(
      session.baseUrl,
      username: session.username,
      credentials: _credentials,
      songId: _songId(track),
    );
  }

  /// Turns a stream [probe] into a typed [SubsonicException] when the response
  /// isn't playable audio. Order mirrors Jellyfin: HTML first (a proxy/login
  /// page is never audio), then auth, then a missing item, then server errors,
  /// then any other non-2xx, and finally a 2xx whose body isn't audio.
  void _ensurePlayableAudio(SubsonicStreamProbe probe) {
    if (probe.isHtml) {
      throw SubsonicException.notSubsonic();
    }
    final int code = probe.statusCode;
    if (code == 401 || code == 403) {
      throw SubsonicException.unauthorized();
    }
    if (code == 404) {
      throw SubsonicException.streamUnavailable();
    }
    if (code >= 500) {
      throw SubsonicException.serverError(code);
    }
    if (!probe.isSuccess) {
      throw SubsonicException.unsupportedResponse(code);
    }
    if (!probe.isAudio) {
      throw SubsonicException.unsupportedResponse();
    }
  }

  SubsonicCredentials get _credentials =>
      SubsonicCredentials(salt: session.salt, token: session.token);

  /// The Subsonic song id behind [track]: the part after the `subsonic:` scheme,
  /// falling back to the track id for an unprefixed value.
  String _songId(Track track) =>
      track.uri.startsWith(SubsonicTrackMapper.uriScheme)
          ? track.uri.substring(SubsonicTrackMapper.uriScheme.length)
          : track.id;
}
