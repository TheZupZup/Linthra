import '../../app_info.dart';
import 'subsonic_auth.dart';

/// Every Subsonic REST path and URL Linthra builds, in one place.
///
/// Centralizing the endpoints means the HTTP client, the source, and the mapper
/// never embed raw path strings, and — crucially — the token-bearing URLs are
/// built by the same pure helpers, so the "weave the salt+token into the query,
/// on demand, never store it" rule lives in a single, auditable spot.
///
/// All builders are pure: they take a clean base URL (no trailing slash, as
/// produced by [SubsonicServerUrl.normalize]) plus the username, credentials,
/// and ids they need, and return a [Uri]. Nothing here performs I/O, logs, or
/// holds state.
///
/// Auth: Subsonic carries credentials in the query string of *every* request
/// (`u`, `t`, `s`, `v`, `c`, `f`), including the binary stream/download URLs the
/// audio engine and the offline downloader fetch — which is exactly why those
/// URLs must be minted on demand here and never persisted on a [Track].
abstract final class SubsonicEndpoints {
  /// The Subsonic API version Linthra targets. 1.16.1 covers the token+salt
  /// auth and the ID3 browsing endpoints used here.
  static const String apiVersion = '1.16.1';

  // --- Query-parameter keys, named once so a typo can't split a request. ---
  static const String userParam = 'u';
  static const String tokenParam = 't';
  static const String saltParam = 's';
  static const String versionParam = 'v';
  static const String clientParam = 'c';
  static const String formatParam = 'f';
  static const String idParam = 'id';

  /// `GET /rest/ping.view` — confirms the address is a reachable
  /// Subsonic-compatible server and that the credentials are accepted.
  static Uri ping(
    String baseUrl, {
    required String username,
    required SubsonicCredentials credentials,
  }) =>
      _build(baseUrl, 'ping', username, credentials);

  /// `GET /rest/getArtists.view` — the ID3 artist index.
  static Uri getArtists(
    String baseUrl, {
    required String username,
    required SubsonicCredentials credentials,
  }) =>
      _build(baseUrl, 'getArtists', username, credentials);

  /// `GET /rest/getAlbumList2.view` — one page of the ID3 album list, sorted
  /// alphabetically. Paginated by [size]/[offset] so the source can walk the
  /// whole library.
  static Uri getAlbumList2(
    String baseUrl, {
    required String username,
    required SubsonicCredentials credentials,
    required int size,
    required int offset,
  }) =>
      _build(baseUrl, 'getAlbumList2', username, credentials, extra: {
        'type': 'alphabeticalByName',
        'size': '$size',
        'offset': '$offset',
      });

  /// `GET /rest/getAlbum.view?id=` — one album with its child songs.
  static Uri getAlbum(
    String baseUrl, {
    required String username,
    required SubsonicCredentials credentials,
    required String albumId,
  }) =>
      _build(baseUrl, 'getAlbum', username, credentials,
          extra: {idParam: albumId});

  /// `GET /rest/getLyricsBySongId.view?id=` — the OpenSubsonic `songLyrics`
  /// extension: a song's synced or plain lyrics, keyed by its id (which Linthra
  /// already holds in the track URI). Navidrome and other OpenSubsonic servers
  /// expose tagged/sidecar lyrics here, so this is the primary lyrics lookup. A
  /// server without the extension answers with a Subsonic error, which the
  /// client treats as "no lyrics" rather than surfacing it.
  static Uri getLyricsBySongId(
    String baseUrl, {
    required String username,
    required SubsonicCredentials credentials,
    required String songId,
  }) =>
      _build(baseUrl, 'getLyricsBySongId', username, credentials,
          extra: {idParam: songId});

  /// `GET /rest/getLyrics.view?artist=&title=` — the legacy Subsonic lyrics
  /// lookup (plain text only, matched by artist + title). Used as a fallback for
  /// servers that don't implement the OpenSubsonic `getLyricsBySongId`
  /// extension.
  static Uri getLyrics(
    String baseUrl, {
    required String username,
    required SubsonicCredentials credentials,
    required String artist,
    required String title,
  }) =>
      _build(baseUrl, 'getLyrics', username, credentials,
          extra: <String, String>{'artist': artist, 'title': title});

  /// The audio stream URL for a song: `/rest/stream.view?id=…` plus auth.
  ///
  /// The server serves a playable stream (transcoding to a broadly compatible
  /// format when its policy says so). The salt+token ride in the query; they
  /// are woven in here, on demand, and never stored on the track or in the
  /// catalog.
  static Uri stream(
    String baseUrl, {
    required String username,
    required SubsonicCredentials credentials,
    required String songId,
  }) =>
      _build(baseUrl, 'stream', username, credentials,
          extra: {idParam: songId});

  /// The original-file download URL: `/rest/download.view?id=…` plus auth, so
  /// the offline copy is the real source file rather than a transcode. Like
  /// [stream], the credential is woven in on demand and never stored.
  static Uri download(
    String baseUrl, {
    required String username,
    required SubsonicCredentials credentials,
    required String songId,
  }) =>
      _build(baseUrl, 'download', username, credentials,
          extra: {idParam: songId});

  /// The cover-art image URL: `/rest/getCoverArt.view?id=…` plus auth.
  ///
  /// [coverArtId] is the opaque handle a song/album/artist reports as its
  /// `coverArt` (e.g. `al-123`). Like [stream] and [download], `getCoverArt`
  /// requires the salt+token on every request, so this URL carries the
  /// credential in its query — it is therefore woven in here, on demand at
  /// render time, and never persisted on a track or in the catalog (the catalog
  /// stores only a credential-free `subsonic-cover:` reference; see
  /// `SubsonicArtwork`).
  ///
  /// [size] asks the server to scale the cover to that many pixels (Subsonic's
  /// `getCoverArt` `size` parameter). It is omitted for the in-app full-size
  /// render (matching how Jellyfin's primary image loads full-size), and set for
  /// the platform media session, which wants a small, fast-to-decode cover.
  static Uri coverArt(
    String baseUrl, {
    required String username,
    required SubsonicCredentials credentials,
    required String coverArtId,
    int? size,
  }) =>
      _build(baseUrl, 'getCoverArt', username, credentials, extra: {
        idParam: coverArtId,
        if (size != null) 'size': '$size',
      });

  /// Builds `/rest/<method>.view` with the standard auth + format query and any
  /// method-specific [extra] parameters. The single place the salt+token are
  /// woven into a URL.
  static Uri _build(
    String baseUrl,
    String method,
    String username,
    SubsonicCredentials credentials, {
    Map<String, String> extra = const <String, String>{},
  }) {
    return Uri.parse('$baseUrl/rest/$method.view').replace(
      queryParameters: <String, String>{
        userParam: username,
        tokenParam: credentials.token,
        saltParam: credentials.salt,
        versionParam: apiVersion,
        clientParam: AppInfo.name,
        formatParam: 'json',
        ...extra,
      },
    );
  }
}
