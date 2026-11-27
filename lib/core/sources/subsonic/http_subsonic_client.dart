import 'dart:async';

import 'package:http/http.dart' as http;

import '../../models/lyrics.dart';
import '../../models/subsonic_session.dart';
import '../../services/lyrics_text_parser.dart';
import 'subsonic_api.dart';
import 'subsonic_auth.dart';
import 'subsonic_client.dart';
import 'subsonic_endpoints.dart';
import 'subsonic_exception.dart';
import 'subsonic_reply.dart';

/// The real [SubsonicClient], backed by `package:http`.
///
/// The only file in the app that constructs Subsonic URLs and sends Subsonic
/// requests. What a server answers is read in the Rust core
/// (`subsonic_reply.dart`). Standard HTTPS already works through a reverse
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
  /// URL and user. Only an answer is kept: a lookup that failed, or got no
  /// answer either way, is asked again by the next long write.
  final Map<(String, String), bool> _formPostAnswers =
      <(String, String), bool>{};

  /// The lookups still out, by the credentials they carry. Writes with the
  /// same credentials wait on one; any others (another user, or the same one
  /// signed in again) ask for themselves, so a refusal of one session's
  /// credentials can't fail another's write. Dropped as each one ends, so no
  /// credentials are kept once it has.
  final Map<(String, String, String), Future<bool?>> _formPostLookups =
      <(String, String, String), Future<bool?>>{};

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
    return serverInfoOf(await _get(uri, SubsonicRead.envelope));
  }

  @override
  Future<void> verifySession(SubsonicSession session) async {
    final Uri uri = SubsonicEndpoints.ping(
      session.baseUrl,
      username: session.username,
      credentials: _credentials(session),
    );
    await _getOk(uri);
  }

  @override
  Future<List<SubsonicArtistDto>> getArtists(SubsonicSession session) async {
    final Uri uri = SubsonicEndpoints.getArtists(
      session.baseUrl,
      username: session.username,
      credentials: _credentials(session),
    );
    // Shape: artists.index[].artist[]
    final SubsonicReply reply = await _get(uri, SubsonicRead.artists);
    return <SubsonicArtistDto>[for (final a in reply.artists) artistDto(a)];
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
    final SubsonicReply reply = await _get(uri, SubsonicRead.albumPage);
    return SubsonicAlbumPage(
      albums: <SubsonicAlbumDto>[for (final a in reply.albums) albumDto(a)],
      entryCount: reply.entryCount,
    );
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
    final SubsonicReply reply = await _get(uri, SubsonicRead.albumSongs);
    return <SubsonicSongDto>[for (final song in reply.songs) songDto(song)];
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
      SubsonicRead.structuredLyrics,
      _structuredLyrics,
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
        SubsonicRead.legacyLyrics,
        _legacyLyrics,
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
    //
    // The engine opens the same URL right after and follows redirects on its
    // own, so a legacy password URL this probe sees redirected is refused here,
    // before the engine ever gets it.
    final http.StreamedResponse response = await _send(
      () => _client.send(
        http.Request('GET', url)
          ..followRedirects = _mayFollowRedirects(url)
          ..headers.addAll(const <String, String>{
            'Accept': '*/*',
            'Range': 'bytes=0-1',
          }),
      ),
    );
    await _release(response);
    _refusePasswordRedirect(url, response.statusCode);
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
    await _getOk(uri);
  }

  @override
  Future<Set<String>> getStarredSongIds(SubsonicSession session) async {
    final Uri uri = SubsonicEndpoints.getStarred2(
      session.baseUrl,
      username: session.username,
      credentials: _credentials(session),
    );
    // Shape: starred2.song[].id
    final SubsonicReply reply = await _get(uri, SubsonicRead.starredSongIds);
    return reply.ids.toSet();
  }

  @override
  Future<void> star(SubsonicSession session, String songId) async {
    await _getOk(SubsonicEndpoints.star(
      session.baseUrl,
      username: session.username,
      credentials: _credentials(session),
      id: songId,
    ));
  }

  @override
  Future<void> unstar(SubsonicSession session, String songId) async {
    await _getOk(SubsonicEndpoints.unstar(
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
    // Shape: playlists.playlist[]
    final SubsonicReply reply = await _get(uri, SubsonicRead.playlists);
    return <SubsonicPlaylistDto>[for (final p in reply.named) playlistDto(p)];
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
    // Shape: playlist.entry[].id, in server order.
    return (await _get(uri, SubsonicRead.playlistSongIds)).ids;
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
    // Most servers (Navidrome) return the created playlist with its id.
    final String? id =
        (await _sendSongList(session, uri, SubsonicRead.createdPlaylistId)).id;
    if (id != null) return id;
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
      SubsonicRead.envelope,
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
  Future<SubsonicReply> _sendSongList(
    SubsonicSession session,
    Uri request,
    SubsonicRead what,
  ) async {
    if (request.toString().length > _shortUrlLength &&
        await _supportsFormPost(session)) {
      return _postForm(request, what);
    }
    return _get(request, what, onRejectedStatus: (int code) {
      if (code == 414 || code == 431) {
        throw SubsonicException.playlistTooLong(code);
      }
    });
  }

  /// Whether to send [session]'s long playlist writes as form posts. A server
  /// that didn't say either way gets a GET, as it did before form posts.
  Future<bool> _supportsFormPost(SubsonicSession session) async {
    final (String, String) server = (session.baseUrl, session.username);
    final bool? known = _formPostAnswers[server];
    if (known != null) return known;

    // Use token for standard sessions or password for legacy sessions
    final String credentialKey = session.token ?? session.password ?? '';
    final (String, String, String) asker =
        (session.baseUrl, session.username, credentialKey);
    final Future<bool?> lookup =
        _formPostLookups[asker] ??= _lookUpFormPost(session).whenComplete(() {
      // A block, not an arrow: the removed value is this very future, and
      // returning it would have whenComplete wait on itself.
      _formPostLookups.remove(asker);
    });
    final bool? answer = await lookup;
    if (answer != null) _formPostAnswers[server] = answer;
    return answer ?? false;
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
    final SubsonicReply reply;
    try {
      reply = await _get(
        SubsonicEndpoints.getOpenSubsonicExtensions(
          session.baseUrl,
          username: session.username,
          credentials: _credentials(session),
        ),
        SubsonicRead.formPost,
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
    return reply.takesFormPosts;
  }

  /// [request] as an OpenSubsonic form POST: same endpoint, its parameters
  /// (credentials included) in the body instead of the URL.
  ///
  /// One carrying the legacy password is not sent on through a redirect
  /// either. The HTTP client follows only a 303 for a POST, and as a GET
  /// without the body, but that is the client's choice, not this one's.
  Future<SubsonicReply> _postForm(Uri request, SubsonicRead what) async {
    final ({Uri target, String body}) form =
        SubsonicEndpoints.asFormPost(request);
    const Map<String, String> headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/x-www-form-urlencoded',
    };
    final http.Response response = await _send(() async {
      if (_mayFollowRedirects(request)) {
        return _client.post(form.target, headers: headers, body: form.body);
      }
      final http.Request post = http.Request('POST', form.target)
        ..followRedirects = false
        ..headers.addAll(headers)
        ..body = form.body;
      return http.Response.fromStream(await _client.send(post));
    });
    _refusePasswordRedirect(request, response.statusCode);
    // A body over a proxy's size limit: too many songs for one request, not
    // a wrong address.
    if (response.statusCode == 413) {
      throw SubsonicException.playlistTooLong(413);
    }
    return _readReply(response, what);
  }

  @override
  Future<void> renamePlaylist(
    SubsonicSession session,
    String playlistId,
    String name,
  ) async {
    await _getOk(SubsonicEndpoints.updatePlaylist(
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
    await _getOk(SubsonicEndpoints.deletePlaylist(
      session.baseUrl,
      username: session.username,
      credentials: _credentials(session),
      playlistId: playlistId,
    ));
  }

  SubsonicCredentials _credentials(SubsonicSession session) {
    if (session.isLegacy) {
      return SubsonicCredentials.legacy(session.password!);
    }
    return SubsonicCredentials(
      salt: session.salt,
      token: session.token,
    );
  }

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
    SubsonicRead what,
    Lyrics? Function(SubsonicReply reply) parse,
  ) async {
    final http.Response response = await _getJson(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    // A 2xx body that isn't a Subsonic answer, or one carrying an error:
    // "no lyrics here", not an error.
    final SubsonicReply reply =
        await readSubsonicAnswer(response.bodyBytes, what);
    if (reply.outcome != SubsonicOutcome.ok) return null;
    return parse(reply);
  }

  /// Performs a JSON `GET`, then decodes and validates the `subsonic-response`
  /// envelope — throwing a friendly [SubsonicException] for a transport failure,
  /// a non-2xx status, a non-Subsonic body, or a Subsonic error code.
  ///
  /// [onRejectedStatus] sees a non-2xx status first, so a caller that knows
  /// what a status means for its request can throw something more precise.
  ///
  /// [followRedirects] off answers a redirect with its own 3xx, which then
  /// fails like any other unexpected status. A redirect for a [uri] carrying
  /// the legacy password is never followed, and is refused as exactly that.
  Future<SubsonicReply> _get(
    Uri uri,
    SubsonicRead what, {
    void Function(int statusCode)? onRejectedStatus,
    bool followRedirects = true,
  }) async {
    final http.Response response =
        await _getJson(uri, followRedirects: followRedirects);
    final int code = response.statusCode;
    _refusePasswordRedirect(uri, code);
    if (onRejectedStatus != null && (code < 200 || code >= 300)) {
      onRejectedStatus(code);
    }
    return _readReply(response, what);
  }

  /// [_get] for a request whose answer only has to be ok.
  Future<void> _getOk(Uri uri) => _get(uri, SubsonicRead.envelope);

  /// GETs [uri] for a JSON answer. With [followRedirects] off, or for a [uri]
  /// carrying the legacy password, a redirect comes back as its own 3xx.
  Future<http.Response> _getJson(Uri uri, {bool followRedirects = true}) =>
      _send(() async {
        if (followRedirects && _mayFollowRedirects(uri)) {
          return _client.get(uri, headers: const <String, String>{
            'Accept': 'application/json',
          });
        }
        final http.Request request = http.Request('GET', uri)
          ..followRedirects = false
          ..headers['Accept'] = 'application/json';
        return http.Response.fromStream(await _client.send(request));
      });

  /// Whether a GET of [uri] may follow a redirect: not when it carries the
  /// legacy password, which goes only to the address the user entered. A
  /// redirect keeps the query when a proxy rewrites the address, so following
  /// one could send the password on to another host, or to plain http.
  static bool _mayFollowRedirects(Uri uri) =>
      !SubsonicEndpoints.carriesPassword(uri);

  /// Refuses the redirect a request carrying the legacy password was answered
  /// with. It was not followed (see [_mayFollowRedirects]); this says why.
  static void _refusePasswordRedirect(Uri uri, int statusCode) {
    if (statusCode >= 300 &&
        statusCode < 400 &&
        SubsonicEndpoints.carriesPassword(uri)) {
      throw SubsonicException.passwordRedirectRefused();
    }
  }

  /// Checks [response]'s status, then reads its `subsonic-response` envelope
  /// and [what] in the Rust core. A body that isn't a Subsonic answer (an
  /// HTML error page, say) is [SubsonicErrorKind.notSubsonic]; a Subsonic
  /// error inside it maps by its code.
  Future<SubsonicReply> _readReply(
    http.Response response,
    SubsonicRead what,
  ) async {
    _checkStatus(response);
    return okOrThrow(
      await readSubsonicAnswer(response.bodyBytes, what),
      _mapErrorCode,
    );
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

  /// [Lyrics] from an OpenSubsonic `getLyricsBySongId` answer
  /// (`lyricsList.structuredLyrics[]`), or `null` when it carries no usable
  /// lines.
  ///
  /// The Rust core reads the first set with lines (servers list several only
  /// for other languages), each line's `start` shifted by the set's `offset`.
  /// A line with no `start`, or in a set flagged `synced: false`, comes back
  /// untimed, so [Lyrics.isSynced] then reports plain: exactly what the UI
  /// needs to pick the static or the timed view.
  static Lyrics? _structuredLyrics(SubsonicReply reply) {
    final List<SubsonicLyricLine>? lines = reply.lyrics;
    if (lines == null || lines.isEmpty) return null;
    return Lyrics(lines: <LyricLine>[
      for (final SubsonicLyricLine line in lines)
        LyricLine(
          text: line.text,
          start: line.startMs == null
              ? null
              : Duration(milliseconds: line.startMs!),
        ),
    ]);
  }

  /// [Lyrics] from a legacy `getLyrics` answer's `lyrics.value` (plain text
  /// or LRC), or `null` when there is no usable text.
  static Lyrics? _legacyLyrics(SubsonicReply reply) {
    final String? value = reply.text;
    if (value == null) return null;
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
}
