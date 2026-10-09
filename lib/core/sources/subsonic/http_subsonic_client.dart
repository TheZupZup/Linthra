import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/lyrics.dart';
import '../../models/subsonic_session.dart';
import '../../services/lyrics_text_parser.dart';
import 'subsonic_api.dart';
import 'subsonic_auth.dart';
import 'subsonic_client.dart';
import 'subsonic_endpoints.dart';
import 'subsonic_exception.dart';

/// The real [SubsonicClient], backed by `package:http`.
///
/// The only file in the app that constructs Subsonic URLs and parses the
/// `subsonic-response` envelope. Standard HTTPS already works through a reverse
/// proxy/Cloudflare, so there's nothing proxy-specific here beyond turning an
/// HTML/5xx error page into a friendly [SubsonicErrorKind.notSubsonic] /
/// [SubsonicErrorKind.serverError].
///
/// Every failure becomes a [SubsonicException]; the username/salt/token are
/// never written to an exception, so a leaked error string can't expose them.
class HttpSubsonicClient implements SubsonicClient {
  HttpSubsonicClient({http.Client? httpClient})
      : _client = httpClient ?? http.Client();

  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 20);

  /// Subsonic caps `getAlbumList2` page size at 500; a generous page-count cap
  /// stops a runaway loop if a server ever ignores the offset.
  static const int _albumPageSize = 500;
  static const int _maxAlbumPages = 200;

  /// The longest playlist-write URL sent as a plain GET without first asking
  /// whether the server takes form posts. Well under what any common proxy
  /// accepts (nginx and Apache stop at about 8 KB), so a small edit costs no
  /// extra request.
  static const int _shortUrlLength = 2000;

  /// Whether each server lists the OpenSubsonic `formPost` extension, by base
  /// URL and user: a lookup carries one user's credentials, so its failure
  /// must not fail another user's write. Only an answer is kept. A lookup
  /// that failed, or got no answer either way, is asked again by the next
  /// long write.
  final Map<(String, String), Future<bool?>> _formPostSupport =
      <(String, String), Future<bool?>>{};

  @override
  Future<SubsonicServerInfo> ping(
    String baseUrl, {
    required String username,
    required SubsonicCredentials credentials,
  }) async {
    final Uri uri = SubsonicEndpoints.ping(
      baseUrl,
      username: username,
      credentials: credentials,
    );
    final SubsonicEnvelope envelope = await _get(uri);
    return SubsonicServerInfo(
      apiVersion: envelope.version,
      type: envelope.type,
      serverVersion: envelope.serverVersion,
    );
  }

  @override
  Future<void> verifySession(SubsonicSession session) async {
    final Uri uri = SubsonicEndpoints.ping(
      session.baseUrl,
      username: session.username,
      credentials: _credentials(session),
    );
    await _get(uri);
  }

  @override
  Future<List<SubsonicArtistDto>> getArtists(SubsonicSession session) async {
    final Uri uri = SubsonicEndpoints.getArtists(
      session.baseUrl,
      username: session.username,
      credentials: _credentials(session),
    );
    final SubsonicEnvelope envelope = await _get(uri);

    // Shape: artists.index[].artist[]
    final List<SubsonicArtistDto> artists = <SubsonicArtistDto>[];
    final Object? root = envelope.data['artists'];
    final Object? indexes = root is Map<String, dynamic> ? root['index'] : null;
    if (indexes is List) {
      for (final Object? index in indexes) {
        if (index is! Map<String, dynamic>) continue;
        final Object? list = index['artist'];
        if (list is! List) continue;
        for (final Object? entry in list) {
          if (entry is Map<String, dynamic>) {
            final SubsonicArtistDto? dto = SubsonicArtistDto.fromJson(entry);
            if (dto != null) artists.add(dto);
          }
        }
      }
    }
    return artists;
  }

  @override
  Future<List<SubsonicAlbumDto>> getAlbums(SubsonicSession session) async {
    final List<SubsonicAlbumDto> albums = <SubsonicAlbumDto>[];
    // Walk pages until one comes back short of a full page (the last page).
    for (int page = 0; page < _maxAlbumPages; page++) {
      final SubsonicAlbumPage list = await getAlbumListPage(
        session,
        size: _albumPageSize,
        offset: page * _albumPageSize,
      );
      albums.addAll(list.albums);
      if (list.entryCount < _albumPageSize) break;
    }
    return albums;
  }

  @override
  Future<SubsonicAlbumPage> getAlbumListPage(
    SubsonicSession session, {
    required int size,
    required int offset,
  }) async {
    final Uri uri = SubsonicEndpoints.getAlbumList2(
      session.baseUrl,
      username: session.username,
      credentials: _credentials(session),
      size: size,
      offset: offset,
    );
    final SubsonicEnvelope envelope = await _get(uri);
    final Object? root = envelope.data['albumList2'];
    final Object? list = root is Map<String, dynamic> ? root['album'] : null;
    if (list is! List) {
      return const SubsonicAlbumPage(
          albums: <SubsonicAlbumDto>[], entryCount: 0);
    }
    final List<SubsonicAlbumDto> albums = <SubsonicAlbumDto>[];
    for (final Object? entry in list) {
      if (entry is Map<String, dynamic>) {
        final SubsonicAlbumDto? dto = SubsonicAlbumDto.fromJson(entry);
        if (dto != null) albums.add(dto);
      }
    }
    return SubsonicAlbumPage(albums: albums, entryCount: list.length);
  }

  @override
  Future<List<SubsonicSongDto>> getAlbumSongs(
    SubsonicSession session,
    String albumId,
  ) async {
    final Uri uri = SubsonicEndpoints.getAlbum(
      session.baseUrl,
      username: session.username,
      credentials: _credentials(session),
      albumId: albumId,
    );
    final SubsonicEnvelope envelope = await _get(uri);
    final Object? root = envelope.data['album'];
    final Object? list = root is Map<String, dynamic> ? root['song'] : null;
    if (list is! List) return const <SubsonicSongDto>[];
    final List<SubsonicSongDto> songs = <SubsonicSongDto>[];
    for (final Object? entry in list) {
      if (entry is Map<String, dynamic>) {
        final SubsonicSongDto? dto = SubsonicSongDto.fromJson(entry);
        if (dto != null) songs.add(dto);
      }
    }
    return songs;
  }

  @override
  Future<Lyrics?> fetchLyrics(
    SubsonicSession session,
    String songId, {
    String? artist,
    String? title,
  }) async {
    final SubsonicCredentials credentials = _credentials(session);
    // Primary: the OpenSubsonic `getLyricsBySongId` extension, keyed by the song
    // id we already hold. This is what Navidrome (and other OpenSubsonic
    // servers) answer with embedded/sidecar lyrics, synced or plain.
    final Lyrics? structured = await _tryLyrics(
      SubsonicEndpoints.getLyricsBySongId(
        session.baseUrl,
        username: session.username,
        credentials: credentials,
        songId: songId,
      ),
      _parseStructuredLyrics,
    );
    if (structured != null) return structured;
    // Fallback: the legacy `getLyrics` (matched by artist + title) for servers
    // without the extension. Skipped when we lack both fields.
    if (artist != null &&
        artist.isNotEmpty &&
        title != null &&
        title.isNotEmpty) {
      return _tryLyrics(
        SubsonicEndpoints.getLyrics(
          session.baseUrl,
          username: session.username,
          credentials: credentials,
          artist: artist,
          title: title,
        ),
        _parseLegacyLyrics,
      );
    }
    return null;
  }

  @override
  Future<SubsonicStreamProbe> probeStream(Uri url) async {
    // A one-byte ranged GET: enough to see the real status and content type the
    // engine will get, without downloading the track. The credential rides in
    // the URL's query — exactly how the engine will fetch — so no extra header
    // is added. The status is returned, not checked, so the caller can tell
    // auth / web-page / non-audio apart; only a transport failure throws.
    //
    // Only the status line and the headers are read. A server that ignores the
    // range (a Subsonic transcode streams the whole track; so can a proxy that
    // drops Range) would otherwise send the entire file here, before the engine
    // fetches it again, and on a slow link that wait runs into the timeout and
    // reads as a server that can't be reached. The body is let go of instead.
    final http.StreamedResponse response = await _send(
      () => _client.send(
        http.Request('GET', url)
          ..headers.addAll(const <String, String>{
            'Accept': '*/*',
            'Range': 'bytes=0-1',
          }),
      ),
    );
    await _release(response);
    return SubsonicStreamProbe(
      statusCode: response.statusCode,
      contentType: response.headers['content-type'],
    );
  }

  /// Lets go of [response]'s body without reading it. A transport error while
  /// releasing it says nothing about the headers already in hand.
  static Future<void> _release(http.StreamedResponse response) async {
    try {
      await response.stream.listen(null, onError: (Object _) {}).cancel();
    } on Exception {
      // Already closed or failed: nothing left to let go of.
    }
  }

  @override
  Future<void> scrobble(
    SubsonicSession session,
    String songId, {
    required bool submission,
  }) async {
    final Uri uri = SubsonicEndpoints.scrobble(
      session.baseUrl,
      username: session.username,
      credentials: _credentials(session),
      songId: songId,
      submission: submission,
    );
    // Only the envelope's ok/failed status matters; a server that rejects or
    // doesn't support scrobbling throws the usual typed, secret-free error.
    await _get(uri);
  }

  @override
  Future<Set<String>> getStarredSongIds(SubsonicSession session) async {
    final Uri uri = SubsonicEndpoints.getStarred2(
      session.baseUrl,
      username: session.username,
      credentials: _credentials(session),
    );
    final SubsonicEnvelope envelope = await _get(uri);
    // Shape: starred2.song[].id
    final Object? root = envelope.data['starred2'];
    final Object? songs = root is Map<String, dynamic> ? root['song'] : null;
    if (songs is! List) return <String>{};
    final Set<String> ids = <String>{};
    for (final Object? entry in songs) {
      if (entry is Map<String, dynamic>) {
        final Object? id = entry['id'];
        if (id is String && id.isNotEmpty) ids.add(id);
      }
    }
    return ids;
  }

  @override
  Future<void> star(SubsonicSession session, String songId) async {
    await _get(SubsonicEndpoints.star(
      session.baseUrl,
      username: session.username,
      credentials: _credentials(session),
      id: songId,
    ));
  }

  @override
  Future<void> unstar(SubsonicSession session, String songId) async {
    await _get(SubsonicEndpoints.unstar(
      session.baseUrl,
      username: session.username,
      credentials: _credentials(session),
      id: songId,
    ));
  }

  @override
  Future<List<SubsonicPlaylistDto>> getPlaylists(
    SubsonicSession session,
  ) async {
    final Uri uri = SubsonicEndpoints.getPlaylists(
      session.baseUrl,
      username: session.username,
      credentials: _credentials(session),
    );
    final SubsonicEnvelope envelope = await _get(uri);
    // Shape: playlists.playlist[]
    final Object? root = envelope.data['playlists'];
    final Object? list = root is Map<String, dynamic> ? root['playlist'] : null;
    if (list is! List) return const <SubsonicPlaylistDto>[];
    final List<SubsonicPlaylistDto> playlists = <SubsonicPlaylistDto>[];
    for (final Object? entry in list) {
      if (entry is Map<String, dynamic>) {
        final SubsonicPlaylistDto? dto = SubsonicPlaylistDto.fromJson(entry);
        if (dto != null) playlists.add(dto);
      }
    }
    return playlists;
  }

  @override
  Future<List<String>> getPlaylistSongIds(
    SubsonicSession session,
    String playlistId,
  ) async {
    final Uri uri = SubsonicEndpoints.getPlaylist(
      session.baseUrl,
      username: session.username,
      credentials: _credentials(session),
      playlistId: playlistId,
    );
    final SubsonicEnvelope envelope = await _get(uri);
    // Shape: playlist.entry[].id, in server order.
    return _entrySongIds(envelope.data['playlist']);
  }

  @override
  Future<String> createPlaylist(
    SubsonicSession session, {
    required String name,
    List<String> songIds = const <String>[],
  }) async {
    final Uri uri = SubsonicEndpoints.createPlaylist(
      session.baseUrl,
      username: session.username,
      credentials: _credentials(session),
      name: name,
      songIds: songIds,
    );
    final SubsonicEnvelope envelope = await _sendSongList(session, uri);
    // Most servers (Navidrome) return the created playlist with its id.
    final Object? root = envelope.data['playlist'];
    if (root is Map<String, dynamic>) {
      final Object? id = root['id'];
      if (id is String && id.isNotEmpty) return id;
    }
    // Fallback for a server that returns an empty ok: find it by name (newest
    // match wins, since a fresh create is appended). Never leaks a credential.
    final List<SubsonicPlaylistDto> playlists = await getPlaylists(session);
    for (final SubsonicPlaylistDto dto in playlists.reversed) {
      if (dto.name == name) return dto.id;
    }
    throw SubsonicException.unsupportedResponse();
  }

  @override
  Future<void> setPlaylistSongs(
    SubsonicSession session,
    String playlistId,
    List<String> songIds,
  ) async {
    // The `createPlaylist`-with-`playlistId` replace form: one idempotent call
    // that sets the exact membership and order, covering add/remove/reorder.
    // Never split into several calls: a later one failing would leave the
    // server playlist cut short, and the next refresh would bring that back.
    await _sendSongList(
      session,
      SubsonicEndpoints.createPlaylist(
        session.baseUrl,
        username: session.username,
        credentials: _credentials(session),
        playlistId: playlistId,
        songIds: songIds,
      ),
    );
  }

  /// Sends a playlist write whose query carries a whole song list, one
  /// `songId` per song, which grows past what a proxy accepts in a URL once a
  /// playlist has a few hundred songs.
  ///
  /// A short one goes as the usual GET. A long one goes as a form POST when
  /// the server lists `formPost`, and otherwise still as a GET (a server with
  /// no proxy in front takes it), with a URL that turns out too long reported
  /// as exactly that rather than as "not a Subsonic server".
  Future<SubsonicEnvelope> _sendSongList(
    SubsonicSession session,
    Uri request,
  ) async {
    if (request.toString().length > _shortUrlLength &&
        await _supportsFormPost(session)) {
      return _postForm(request);
    }
    return _get(request, onRejectedStatus: (int code) {
      if (code == 414 || code == 431) {
        throw SubsonicException.playlistTooLong(code);
      }
    });
  }

  /// Whether to send [session]'s long playlist writes as form posts. Writes
  /// that start while a lookup is out wait on that one rather than asking
  /// again. A server that didn't say either way gets a GET, as it did before
  /// form posts.
  Future<bool> _supportsFormPost(SubsonicSession session) async {
    final (String, String) key = (session.baseUrl, session.username);
    Future<bool?>? lookup = _formPostSupport[key];
    if (lookup == null) {
      final Future<bool?> asked = _lookUpFormPost(session);
      _formPostSupport[key] = asked;
      lookup = asked;
      void forget() {
        if (identical(_formPostSupport[key], asked)) {
          _formPostSupport.remove(key);
        }
      }

      unawaited(asked.then<void>(
        (bool? answer) {
          if (answer == null) forget();
        },
        onError: (Object _) => forget(),
      ));
    }
    return await lookup ?? false;
  }

  /// Asks [session]'s server whether it takes form posts: `true` or `false`
  /// when it answered, `null` when it said nothing either way.
  ///
  /// Throws, and the write is not sent, only when the server can't be reached
  /// or turns these credentials down. The write would fail the same way (same
  /// server, same connection, same credentials), and that is the error worth
  /// showing. Anything else says nothing about the write.
  Future<bool?> _lookUpFormPost(SubsonicSession session) async {
    bool noSuchEndpoint = false;
    final SubsonicEnvelope envelope;
    try {
      envelope = await _get(
        SubsonicEndpoints.getOpenSubsonicExtensions(
          session.baseUrl,
          username: session.username,
          credentials: _credentials(session),
        ),
        onRejectedStatus: (int code) {
          noSuchEndpoint = code == 404;
        },
        // Asked at the configured address itself, where the form would go. A
        // POST isn't sent on through a redirect the way a GET is, so an
        // address that redirects gets no answer here, and its write goes as
        // a GET that follows the redirect, as it did before form posts.
        followRedirects: false,
      );
    } on SubsonicException catch (error) {
      switch (error.kind) {
        case SubsonicErrorKind.notReachable:
        case SubsonicErrorKind.cleartextBlocked:
        case SubsonicErrorKind.insecureConnection:
        case SubsonicErrorKind.unauthorized:
          rethrow;
        // A server without OpenSubsonic saying it has no such data
        // (Subsonic error 70).
        case SubsonicErrorKind.streamUnavailable:
          return false;
        // A 404 is one with no such endpoint. Anything else is not an answer:
        // a server error or a rate limit (5xx, 429), a generic Subsonic
        // error, a page that isn't Subsonic, a redirect. Some servers answer an endpoint
        // they don't have with a 500, and a passing failure on one that does
        // take forms must not shut it out for the session.
        default:
          return noSuchEndpoint ? false : null;
      }
    }
    final Object? extensions = envelope.data['openSubsonicExtensions'];
    if (extensions is! List) return false;
    for (final Object? extension in extensions) {
      if (extension is! Map<String, dynamic>) continue;
      final Object? versions = extension['versions'];
      if (extension['name'] == 'formPost' &&
          versions is List &&
          versions.contains(1)) {
        return true;
      }
    }
    return false;
  }

  /// [request] as an OpenSubsonic form POST: same endpoint, its parameters
  /// (credentials included) in the body instead of the URL.
  Future<SubsonicEnvelope> _postForm(Uri request) async {
    final ({Uri target, String body}) form =
        SubsonicEndpoints.asFormPost(request);
    final http.Response response = await _send(
      () => _client.post(
        form.target,
        headers: const <String, String>{
          'Accept': 'application/json',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: form.body,
      ),
    );
    // A body over a proxy's size limit: too many songs for one request, not
    // a wrong address.
    if (response.statusCode == 413) {
      throw SubsonicException.playlistTooLong(413);
    }
    return _readEnvelope(response);
  }

  @override
  Future<void> renamePlaylist(
    SubsonicSession session,
    String playlistId,
    String name,
  ) async {
    await _get(SubsonicEndpoints.updatePlaylist(
      session.baseUrl,
      username: session.username,
      credentials: _credentials(session),
      playlistId: playlistId,
      name: name,
    ));
  }

  @override
  Future<void> deletePlaylist(
    SubsonicSession session,
    String playlistId,
  ) async {
    await _get(SubsonicEndpoints.deletePlaylist(
      session.baseUrl,
      username: session.username,
      credentials: _credentials(session),
      playlistId: playlistId,
    ));
  }

  /// The ordered song ids of a `playlist` object's `entry` list, skipping any
  /// entry without a usable id.
  static List<String> _entrySongIds(Object? playlist) {
    final Object? entries =
        playlist is Map<String, dynamic> ? playlist['entry'] : null;
    if (entries is! List) return const <String>[];
    final List<String> ids = <String>[];
    for (final Object? entry in entries) {
      if (entry is Map<String, dynamic>) {
        final Object? id = entry['id'];
        if (id is String && id.isNotEmpty) ids.add(id);
      }
    }
    return ids;
  }

  SubsonicCredentials _credentials(SubsonicSession session) =>
      SubsonicCredentials(salt: session.salt, token: session.token);

  /// GETs a lyrics endpoint and runs [parse] on a successful envelope.
  ///
  /// Lyrics are best-effort: only a transport failure (from [_send]) propagates
  /// — surfacing the UI's "couldn't load lyrics" hint when offline. Every other
  /// outcome (an HTTP error status, a non-Subsonic body, or a Subsonic error
  /// inside a 200: no match, unsupported method, an old server) means "no lyrics
  /// here" and yields `null`, so the UI keeps its calm empty state rather than a
  /// scary error. The credential-bearing URL is never logged or thrown.
  Future<Lyrics?> _tryLyrics(
    Uri uri,
    Lyrics? Function(SubsonicEnvelope envelope) parse,
  ) async {
    final http.Response response = await _send(
      () => _client.get(uri, headers: const <String, String>{
        'Accept': 'application/json',
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final Map<String, dynamic> body;
    try {
      body = _decodeObject(response);
    } on SubsonicException {
      // A 2xx body that isn't JSON — treat as "no lyrics here", not an error.
      return null;
    }
    final SubsonicEnvelope? envelope = SubsonicEnvelope.fromJson(body);
    if (envelope == null || !envelope.isOk) return null;
    return parse(envelope);
  }

  /// Performs a JSON `GET`, then decodes and validates the `subsonic-response`
  /// envelope — throwing a friendly [SubsonicException] for a transport failure,
  /// a non-2xx status, a non-Subsonic body, or a Subsonic error code.
  ///
  /// [onRejectedStatus] sees a non-2xx status first, so a caller that knows
  /// what a status means for its request can throw something more precise.
  ///
  /// [followRedirects] off answers a redirect with its own 3xx, which then
  /// fails like any other unexpected status.
  Future<SubsonicEnvelope> _get(
    Uri uri, {
    void Function(int statusCode)? onRejectedStatus,
    bool followRedirects = true,
  }) async {
    final http.Response response = await _send(() async {
      if (followRedirects) {
        return _client.get(uri, headers: const <String, String>{
          'Accept': 'application/json',
        });
      }
      final http.Request request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers['Accept'] = 'application/json';
      return http.Response.fromStream(await _client.send(request));
    });
    final int code = response.statusCode;
    if (onRejectedStatus != null && (code < 200 || code >= 300)) {
      onRejectedStatus(code);
    }
    return _readEnvelope(response);
  }

  /// Checks [response]'s status and decodes its `subsonic-response` envelope.
  SubsonicEnvelope _readEnvelope(http.Response response) {
    _checkStatus(response);
    final SubsonicEnvelope? envelope =
        SubsonicEnvelope.fromJson(_decodeObject(response));
    if (envelope == null) {
      throw SubsonicException.notSubsonic();
    }
    if (!envelope.isOk) {
      throw _mapErrorCode(envelope.errorCode);
    }
    return envelope;
  }

  /// Runs a request with a timeout, turning any transport-level failure into a
  /// friendly [SubsonicException] without leaking low-level details (which could
  /// include the credential-bearing URL). A blocked cleartext request and a
  /// failed TLS handshake get their own precise kinds; everything else (DNS,
  /// refused connection, timeout) is "not reachable".
  Future<T> _send<T>(Future<T> Function() request) async {
    try {
      return await request().timeout(_timeout);
    } on TimeoutException {
      throw SubsonicException.notReachable();
    } on Exception catch (error) {
      throw _classifyTransportError(error);
    }
  }

  /// Infers the *kind* of a transport failure from [error] and returns the
  /// matching friendly exception.
  ///
  /// Security: the error text can contain the request URL (and thus the
  /// salt+token), so it is only inspected here to classify — it is NEVER placed
  /// into the thrown message, which is always one of the static, secret-free
  /// factories. A platform cleartext block surfaces with "Cleartext HTTP
  /// traffic … not permitted"; a self-signed/untrusted certificate surfaces as
  /// a `HandshakeException`/TLS error.
  SubsonicException _classifyTransportError(Object error) {
    final String text = '${error.runtimeType} $error'.toLowerCase();
    if (text.contains('cleartext')) {
      return SubsonicException.cleartextBlocked();
    }
    if (text.contains('handshake') ||
        text.contains('certificate') ||
        text.contains('tlsexception')) {
      return SubsonicException.insecureConnection();
    }
    // SocketException (DNS / refused) and any other transport error: all "can't
    // reach it".
    return SubsonicException.notReachable();
  }

  /// Maps an HTTP status to a [SubsonicException]. 2xx passes (the envelope is
  /// inspected next); everything else throws before the body is parsed, so error
  /// handling never depends on — or echoes — response content.
  void _checkStatus(http.Response response) {
    final int code = response.statusCode;
    if (code >= 200 && code < 300) return;
    if (code == 401 || code == 403) {
      throw SubsonicException.unauthorized();
    }
    // 429 Too Many Requests: a server or reverse proxy rate-limiting the
    // thousands of requests a large library sync makes. That is transient,
    // so it maps to the retryable server-error kind rather than "not
    // Subsonic".
    if (code >= 500 || code == 429) {
      throw SubsonicException.serverError(code);
    }
    // Other 4xx (wrong path, proxy 4xx, …): the address probably isn't a
    // Subsonic API root.
    throw SubsonicException.notSubsonic();
  }

  /// Maps a Subsonic error [code] (returned inside a 200 response) to a typed,
  /// friendly exception. Credentials errors re-prompt; "not found" is a
  /// stream-unavailable; an incompatible version is unsupported.
  SubsonicException _mapErrorCode(int? code) {
    switch (code) {
      case 40: // wrong username or password
      case 41: // token auth not supported for LDAP
      case 44: // invalid API key
      case 45: // API key not authorized
      case 50: // user not authorized for the operation
        return SubsonicException.unauthorized();
      case 70: // requested data not found
        return SubsonicException.streamUnavailable();
      case 20: // incompatible client version
      case 30: // incompatible server version
        return SubsonicException.unsupportedResponse();
      default:
        return SubsonicException.serverError();
    }
  }

  /// Parses an OpenSubsonic `getLyricsBySongId` envelope
  /// (`lyricsList.structuredLyrics[]`) into [Lyrics], or `null` when it carries
  /// no usable lines.
  ///
  /// Each line has a `value` (text) and, for synced lyrics, a `start` in
  /// **milliseconds**; an entry-level `offset` (ms, default 0) shifts every
  /// timestamp. A line with no `start` (or a set explicitly flagged
  /// `synced: false`) maps to a plain, untimed [LyricLine], so [Lyrics.isSynced]
  /// then reports plain — exactly what the UI needs to pick the static vs. the
  /// timed view. The first structured set with lines is used (servers list
  /// multiple only for alternate languages).
  static Lyrics? _parseStructuredLyrics(SubsonicEnvelope envelope) {
    final Object? root = envelope.data['lyricsList'];
    if (root is! Map<String, dynamic>) return null;
    final Object? sets = root['structuredLyrics'];
    if (sets is! List) return null;
    for (final Object? set in sets) {
      if (set is! Map<String, dynamic>) continue;
      final Object? rawLines = set['line'];
      if (rawLines is! List || rawLines.isEmpty) continue;
      // Honor an explicit unsynced flag so a server that tags plain lyrics with
      // stray zero timestamps isn't mistaken for a (mis)timed track; otherwise
      // per-line `start` presence decides plain vs. synced.
      final bool unsynced = set['synced'] == false;
      final int offsetMs = _asInt(set['offset']) ?? 0;
      final List<LyricLine> lines = <LyricLine>[];
      for (final Object? raw in rawLines) {
        if (raw is! Map<String, dynamic>) continue;
        final Object? value = raw['value'];
        if (value is! String) continue;
        final int? startMs = unsynced ? null : _asInt(raw['start']);
        lines.add(LyricLine(
          text: value,
          start: startMs == null ? null : _durationFromMs(startMs + offsetMs),
        ));
      }
      if (lines.isNotEmpty) return Lyrics(lines: lines);
    }
    return null;
  }

  /// Parses a legacy `getLyrics` envelope (`lyrics.value`, plain text or LRC)
  /// into [Lyrics], or `null` when there is no usable text.
  static Lyrics? _parseLegacyLyrics(SubsonicEnvelope envelope) {
    final Object? root = envelope.data['lyrics'];
    if (root is! Map<String, dynamic>) return null;
    final Object? value = root['value'];
    if (value is! String) return null;
    final Lyrics? parsed = LyricsTextParser.parseLrc(value);
    if (parsed?.isSynced ?? false) return parsed;
    if (value.trim().isEmpty) return null;
    final List<LyricLine> lines = value
        .replaceAll("\r\n", "\n")
        .replaceAll("\r", "\n")
        .split("\n")
        .map((String line) => LyricLine(text: line))
        .toList();
    return lines.isEmpty ? null : Lyrics(lines: lines);
  }

  /// A non-negative [Duration] from milliseconds; clamps a negative result (an
  /// offset can push an early line below zero) to zero.
  static Duration _durationFromMs(int milliseconds) =>
      Duration(milliseconds: milliseconds < 0 ? 0 : milliseconds);

  /// Reads a numeric JSON field as an `int`, or `null` when it's absent, not a
  /// number or too large to be finite, so a malformed `start`/`offset` can't
  /// throw or mistime a line.
  static int? _asInt(Object? value) =>
      value is num && value.isFinite ? value.toInt() : null;

  /// Decodes a JSON object body, or throws [SubsonicErrorKind.notSubsonic] when
  /// the body isn't JSON (e.g. an HTML error page) or isn't an object.
  Map<String, dynamic> _decodeObject(http.Response response) {
    Object? decoded;
    try {
      // Decode the raw bytes as UTF-8 rather than `response.body` (which falls
      // back to latin1 without a charset and would mangle non-ASCII titles).
      final String text = utf8.decode(response.bodyBytes, allowMalformed: true);
      decoded = jsonDecode(text);
    } on FormatException {
      throw SubsonicException.notSubsonic();
    }
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw SubsonicException.notSubsonic();
  }
}
