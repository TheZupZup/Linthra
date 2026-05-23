import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/jellyfin_session.dart';
import '../../models/track.dart';
import '../../services/music_source.dart';
import 'jellyfin_api.dart';
import 'jellyfin_client.dart';
import 'jellyfin_track_mapper.dart';

/// A [MusicSource] backed by a signed-in Jellyfin server.
///
/// The Jellyfin counterpart to `LocalMusicSource`: it implements the exact same
/// contract, so the rest of the app treats a remote library identically to the
/// on-device one. Discovery (listing items) is delegated to a [JellyfinClient]
/// and mapping to [JellyfinTrackMapper], keeping this class a thin orchestrator.
///
/// Like the local source, it does not persist anything itself — the
/// `MusicLibraryRepository` is what syncs these results into the offline cache
/// the UI reads from. Wiring that sync (and actual streaming playback) is the
/// next step; this foundation makes both small to add.
class JellyfinMusicSource implements MusicSource {
  const JellyfinMusicSource({
    required this.session,
    required JellyfinClient client,
  }) : _client = client;

  /// The session this source reads on behalf of (server URL, user, token).
  final JellyfinSession session;

  final JellyfinClient _client;

  @override
  String get id => 'jellyfin';

  @override
  String get displayName {
    final String? name = session.serverName;
    return (name != null && name.isNotEmpty) ? 'Jellyfin · $name' : 'Jellyfin';
  }

  @override
  Future<List<Track>> fetchTracks() async {
    final List<JellyfinItemDto> items =
        await _client.fetchItems(session, kind: JellyfinItemKind.audio);
    return <Track>[
      for (final JellyfinItemDto item in items)
        JellyfinTrackMapper.toTrack(item, baseUrl: session.baseUrl),
    ];
  }

  @override
  Future<List<Album>> fetchAlbums() async {
    final List<JellyfinItemDto> items =
        await _client.fetchItems(session, kind: JellyfinItemKind.album);
    return <Album>[
      for (final JellyfinItemDto item in items)
        JellyfinTrackMapper.toAlbum(item, baseUrl: session.baseUrl),
    ];
  }

  @override
  Future<List<Artist>> fetchArtists() async {
    final List<JellyfinItemDto> items =
        await _client.fetchItems(session, kind: JellyfinItemKind.artist);
    return <Artist>[
      for (final JellyfinItemDto item in items)
        JellyfinTrackMapper.toArtist(item, baseUrl: session.baseUrl),
    ];
  }

  /// Mints the authenticated streaming URL for [track] on demand.
  ///
  /// The token is woven in here, at play time, rather than stored on the track,
  /// so it never reaches the persisted catalog. Kept intentionally minimal
  /// (direct play / server-chosen container); richer transcoding parameters are
  /// a later refinement.
  @override
  Future<Uri?> resolvePlayableUri(Track track) async {
    final String itemId = track.uri.startsWith(JellyfinTrackMapper.uriScheme)
        ? track.uri.substring(JellyfinTrackMapper.uriScheme.length)
        : track.id;
    return Uri.parse('${session.baseUrl}/Audio/$itemId/universal').replace(
      queryParameters: <String, String>{
        'api_key': session.accessToken,
        'UserId': session.userId,
        'DeviceId': session.deviceId,
      },
    );
  }
}
