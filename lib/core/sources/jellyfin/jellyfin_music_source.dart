import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/jellyfin_session.dart';
import '../../models/track.dart';
import '../../services/music_source.dart';
import '../../services/playback_diagnostics.dart';
import 'jellyfin_api.dart';
import 'jellyfin_client.dart';
import 'jellyfin_download_source.dart';
import 'jellyfin_endpoints.dart';
import 'jellyfin_exception.dart';
import 'jellyfin_stream_source.dart';
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
/// the UI reads from. Streaming playback is wired through
/// `JellyfinPlayableUriResolver`, which calls [verifyReachable] then
/// [resolvePlayableUri] at play time so the token is only ever woven into a URL
/// on demand.
class JellyfinMusicSource
    implements MusicSource, JellyfinStreamSource, JellyfinDownloadSource {
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
    final JellyfinItemListing listing =
        await _client.fetchItems(session, kind: JellyfinItemKind.audio);
    return <Track>[
      for (final JellyfinItemDto item in listing.items)
        JellyfinTrackMapper.toTrack(item, baseUrl: session.baseUrl),
    ];
  }

  @override
  Future<List<Album>> fetchAlbums() async {
    final JellyfinItemListing listing =
        await _client.fetchItems(session, kind: JellyfinItemKind.album);
    return <Album>[
      for (final JellyfinItemDto item in listing.items)
        JellyfinTrackMapper.toAlbum(item, baseUrl: session.baseUrl),
    ];
  }

  @override
  Future<List<Artist>> fetchArtists() async {
    final JellyfinItemListing listing =
        await _client.fetchItems(session, kind: JellyfinItemKind.artist);
    return <Artist>[
      for (final JellyfinItemDto item in listing.items)
        JellyfinTrackMapper.toArtist(item, baseUrl: session.baseUrl),
    ];
  }

  /// Pulls the whole library for a sync in one call: [Track]s — the only slice
  /// the catalog persists and the part a sync exists to deliver — plus albums
  /// and artists as **best-effort** extras, and a count of track entries the
  /// server returned that were too malformed to map.
  ///
  /// Tracks are fetched first, so any *global* failure (an expired session, an
  /// unreachable server, a 5xx that outlived its retries) throws here and aborts
  /// the sync — leaving the previous catalog untouched. Albums and artists are
  /// then fetched independently and a [JellyfinException] in either is swallowed
  /// to an empty list: they are secondary (the Library derives them from tracks
  /// and the durable catalog doesn't store them), so a hiccup reading them must
  /// never sink an otherwise-good track sync.
  Future<JellyfinLibrarySync> fetchLibraryForSync() async {
    final JellyfinItemListing trackListing =
        await _client.fetchItems(session, kind: JellyfinItemKind.audio);
    final List<Track> tracks = <Track>[
      for (final JellyfinItemDto item in trackListing.items)
        JellyfinTrackMapper.toTrack(item, baseUrl: session.baseUrl),
    ];
    return JellyfinLibrarySync(
      tracks: tracks,
      albums: await _bestEffort(fetchAlbums, const <Album>[]),
      artists: await _bestEffort(fetchArtists, const <Artist>[]),
      skippedCount: trackListing.skippedCount,
    );
  }

  /// Runs [fetch] and returns its result, or [fallback] if it raises a
  /// [JellyfinException] — the best-effort wrapper for the secondary
  /// albums/artists reads. Only the typed Jellyfin failure is swallowed; an
  /// unexpected error still propagates so it isn't masked.
  Future<List<T>> _bestEffort<T>(
    Future<List<T>> Function() fetch,
    List<T> fallback,
  ) async {
    try {
      return await fetch();
    } on JellyfinException {
      return fallback;
    }
  }

  /// Confirms the session is still valid and the server reachable, so the
  /// player can surface a precise error before attempting to stream. Throws a
  /// [JellyfinException] on failure; the password and token never appear in it.
  @override
  Future<void> verifyReachable() => _client.verifySession(session);

  /// Mints the authenticated streaming URL for [track] on demand, then probes
  /// it so a Cloudflare page, an expired token, or a non-audio response becomes
  /// a precise error instead of an opaque engine failure.
  ///
  /// The token is woven in here, at play time, rather than stored on the track,
  /// so it never reaches the persisted catalog. The URL targets the direct-play
  /// stream endpoint (`/Audio/<id>/stream` with `static=true`) so the server
  /// returns the original file bytes — what `just_audio`/ExoPlayer can open
  /// directly — rather than negotiating a transcode/HLS variant the engine may
  /// reject. Auth rides in the `ApiKey` query (not a header) because that is
  /// what the engine fetches with, and query auth survives the redirects a
  /// stripped header would not.
  @override
  Future<Uri?> resolvePlayableUri(Track track) async {
    final Uri url = _streamUri(track);
    final JellyfinStreamProbe probe = await _client.probeStream(url);
    // Log the (non-secret) probe outcome before classifying, so a rejected
    // stream is still diagnosable from a debug log.
    PlaybackDiagnostics.resolved(
      source: 'jellyfin',
      resolver: 'JellyfinPlayableUriResolver',
      itemId: _itemId(track),
      statusCode: probe.statusCode,
      contentType: probe.contentType,
    );
    _ensurePlayableAudio(probe);
    return url;
  }

  /// The direct-play stream URL for [track], built by the single
  /// [JellyfinEndpoints.audioStream] helper so the streaming, download, and
  /// probe paths can never drift apart. `static=true` asks Jellyfin to serve the
  /// original file as-is (no transcode) — the reliable "stream directly" path
  /// for an audio engine that already decodes the common containers.
  Uri _streamUri(Track track) => JellyfinEndpoints.audioStream(
        session.baseUrl,
        itemId: _itemId(track),
        accessToken: session.accessToken,
        userId: session.userId,
        deviceId: session.deviceId,
      );

  /// Turns a stream [probe] into a typed [JellyfinException] when the response
  /// isn't playable audio, so the resolver can map it to a friendly message.
  ///
  /// Order matters: HTML is checked first (a Cloudflare/login/error page is
  /// never audio, whatever its status, and Jellyfin's own auth responses aren't
  /// HTML), then auth, then a missing item (404), then server errors, then any
  /// other non-2xx, and finally a 2xx whose body isn't audio.
  void _ensurePlayableAudio(JellyfinStreamProbe probe) {
    if (probe.isHtml) {
      throw JellyfinException.webPage();
    }
    final int code = probe.statusCode;
    if (code == 401 || code == 403) {
      throw JellyfinException.unauthorized();
    }
    if (code == 404) {
      // The stream endpoint answered but the item isn't there — moved, removed,
      // or a library the token can't see.
      throw JellyfinException.streamUnavailable();
    }
    if (code >= 500) {
      throw JellyfinException.serverError(code);
    }
    if (!probe.isSuccess) {
      // Any other non-2xx (a 400/429/redirect-that-didn't-resolve): a response
      // Linthra can't turn into a playable stream.
      throw JellyfinException.unsupportedResponse(code);
    }
    if (!probe.isAudio) {
      throw JellyfinException.notAudioStream();
    }
  }

  /// Mints the authenticated URL to download [track]'s original file on demand.
  ///
  /// Uses Jellyfin's `/Items/<id>/Download` endpoint so the cached copy is the
  /// real source file rather than a transcode. Like [resolvePlayableUri], the
  /// token is woven in here, at download time, and never stored on the track.
  @override
  Future<Uri?> resolveDownloadUri(Track track) async {
    return JellyfinEndpoints.download(
      session.baseUrl,
      itemId: _itemId(track),
      accessToken: session.accessToken,
    );
  }

  /// The Jellyfin item id behind [track]: the part after the `jellyfin:` scheme,
  /// falling back to the track id for an unprefixed value.
  String _itemId(Track track) =>
      track.uri.startsWith(JellyfinTrackMapper.uriScheme)
          ? track.uri.substring(JellyfinTrackMapper.uriScheme.length)
          : track.id;
}

/// The result of [JellyfinMusicSource.fetchLibraryForSync]: the mapped catalog
/// plus the number of track entries dropped as unparseable, so the sync can
/// commit the good data and report skips calmly ("some items could not be
/// synced") instead of failing outright.
class JellyfinLibrarySync {
  const JellyfinLibrarySync({
    required this.tracks,
    required this.albums,
    required this.artists,
    required this.skippedCount,
  });

  final List<Track> tracks;
  final List<Album> albums;
  final List<Artist> artists;

  /// How many track entries the server returned that were too malformed to map
  /// (missing id/name, or not an object). Zero on a clean sync.
  final int skippedCount;
}
