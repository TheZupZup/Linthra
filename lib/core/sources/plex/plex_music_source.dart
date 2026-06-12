import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/plex_session.dart';
import '../../models/track.dart';
import '../../services/music_source.dart';
import '../../services/playback_diagnostics.dart';
import 'plex_api.dart';
import 'plex_client.dart';
import 'plex_endpoints.dart';
import 'plex_stream_source.dart';
import 'plex_track_mapper.dart';

/// A [MusicSource] backed by a signed-in Plex Media Server.
///
/// The Plex counterpart to `JellyfinMusicSource` / `SubsonicMusicSource`: it
/// implements the same contract, so the rest of the app treats a Plex library
/// identically to any other. Discovery (listing items) is delegated to a
/// [PlexClient] and mapping to [PlexTrackMapper], keeping this class a thin
/// orchestrator. Like the other sources, it persists nothing itself — the
/// `MusicLibraryRepository` syncs these results into the offline cache the UI
/// reads from.
///
/// Unlike Jellyfin/Subsonic (which sync the whole server), Plex scopes every
/// listing to the music sections the user **selected**
/// ([PlexSession.selectedSectionKeys]): each fetch lists one Plex metadata
/// type (artist 8 / album 9 / track 10) per selected section and concatenates
/// the results. No selection yet — the state every sign-in starts in until the
/// library picker (a later PR) fills it — simply yields empty lists, never an
/// error.
///
/// Playback is two-step by design (see docs/plex.md → MusicSource mapping): a
/// track's opaque `plex:<ratingKey>` URI is resolved at play time via a
/// `GET /library/metadata/{ratingKey}` lookup, because the playable `Part` key
/// differs from the `ratingKey`. That live lookup doubles as the reachability/
/// auth check Jellyfin and Subsonic get from probing their stream URL: an
/// expired token, an offline server, or a vanished item surfaces as a typed,
/// token-free `PlexException` before the audio engine ever touches a URL. Only
/// then is the tokenized stream URL minted — the token never reaches a
/// [Track], the catalog, or an error message.
class PlexMusicSource implements MusicSource, PlexStreamSource {
  const PlexMusicSource({required this.session, required PlexClient client})
      : _client = client;

  /// The session this source reads on behalf of (server URL, token, selected
  /// library sections).
  final PlexSession session;

  final PlexClient _client;

  /// The stable source id under which Plex tracks are stored.
  static const String sourceId = 'plex';

  @override
  String get id => sourceId;

  @override
  String get displayName {
    final String? name = session.serverName;
    return (name != null && name.isNotEmpty) ? 'Plex · $name' : 'Plex';
  }

  @override
  Future<List<Track>> fetchTracks() async {
    final List<PlexMetadata> items =
        await _fetchSelectedSections(PlexMetadataType.track);
    return <Track>[
      for (final PlexMetadata item in items) PlexTrackMapper.toTrack(item),
    ];
  }

  @override
  Future<List<Album>> fetchAlbums() async {
    final List<PlexMetadata> items =
        await _fetchSelectedSections(PlexMetadataType.album);
    return <Album>[
      for (final PlexMetadata item in items) PlexTrackMapper.toAlbum(item),
    ];
  }

  @override
  Future<List<Artist>> fetchArtists() async {
    final List<PlexMetadata> items =
        await _fetchSelectedSections(PlexMetadataType.artist);
    return <Artist>[
      for (final PlexMetadata item in items) PlexTrackMapper.toArtist(item),
    ];
  }

  /// Every item of [itemType] across the user's selected music sections, in
  /// selection order. An empty selection returns an empty list without
  /// touching the server: "nothing chosen yet" is an empty library, not an
  /// error.
  Future<List<PlexMetadata>> _fetchSelectedSections(
    PlexMetadataType itemType,
  ) async {
    final List<PlexMetadata> items = <PlexMetadata>[];
    for (final String sectionKey in session.selectedSectionKeys) {
      items.addAll(await _client.fetchSectionItems(
        baseUrl: session.baseUrl,
        token: session.token,
        sectionKey: sectionKey,
        itemType: itemType,
      ));
    }
    return items;
  }

  /// Confirms the token is still accepted and the server reachable, via
  /// `GET /identity`, so the player can surface a precise error before
  /// attempting to stream. Throws a `PlexException` on failure; the token
  /// never appears in it.
  @override
  Future<void> verifyReachable() async {
    await _client.fetchIdentity(baseUrl: session.baseUrl, token: session.token);
  }

  /// Resolves a `plex:<ratingKey>` track to its direct-play stream URL on
  /// demand: fetch `GET /library/metadata/{ratingKey}`, read the first `Part`
  /// key, and mint `{baseUrl}{partKey}?X-Plex-Token=…` — the only moment the
  /// token is woven into a URL, which is handed to the audio engine and never
  /// persisted. Returns `null` when the item carries no playable part.
  ///
  /// Throws a token-free `PlexException` when the lookup fails (item gone,
  /// token rejected, server unreachable).
  @override
  Future<Uri?> resolvePlayableUri(Track track) async {
    final String ratingKey = _ratingKey(track);
    final PlexMetadata item = await _client.fetchMetadata(
      baseUrl: session.baseUrl,
      token: session.token,
      ratingKey: ratingKey,
    );
    // Log the (non-secret) resolution before minting any tokenized URL, so a
    // track that resolves to no playable part is still diagnosable.
    PlaybackDiagnostics.resolved(
      source: sourceId,
      resolver: 'PlexMusicSource',
      itemId: ratingKey,
    );
    final String? partKey = item.firstPartKey;
    if (partKey == null) return null;
    return PlexEndpoints.streamUrl(
      session.baseUrl,
      partKey: partKey,
      token: session.token,
    );
  }

  /// The Plex `ratingKey` behind [track]: the part after the `plex:` scheme,
  /// falling back to the track id for an unprefixed value.
  String _ratingKey(Track track) =>
      track.uri.startsWith(PlexTrackMapper.uriScheme)
          ? track.uri.substring(PlexTrackMapper.uriScheme.length)
          : track.id;
}
