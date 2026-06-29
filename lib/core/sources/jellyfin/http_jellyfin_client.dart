import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/jellyfin_session.dart';
import '../../models/lyrics.dart';
import 'jellyfin_api.dart';
import 'jellyfin_auth_header.dart';
import 'jellyfin_client.dart';
import 'jellyfin_endpoints.dart';
import 'jellyfin_exception.dart';
import 'jellyfin_sync_diagnostics.dart';

/// The real [JellyfinClient], backed by `package:http`.
///
/// This is the only file in the app that constructs Jellyfin URLs, sets the
/// auth header, and parses JSON. Standard HTTPS requests already work through a
/// Cloudflare proxy/tunnel, so there's nothing Cloudflare-specific here beyond
/// turning its error pages (HTML / 5xx) into a friendly
/// [JellyfinErrorKind.notJellyfin] / [JellyfinErrorKind.serverError].
///
/// Every failure becomes a [JellyfinException]; the password and token are
/// never written to an exception, so a leaked error string can't expose them.
class HttpJellyfinClient implements JellyfinClient {
  HttpJellyfinClient({
    http.Client? httpClient,
    int maxItemFetchAttempts = 3,
    Duration retryBackoff = const Duration(milliseconds: 400),
    int itemPageSize = 500,
    Duration pageGap = const Duration(milliseconds: 30),
    int maxItemPages = 10000,
  })  : assert(maxItemFetchAttempts >= 1),
        assert(itemPageSize >= 1),
        assert(maxItemPages >= 1),
        _client = httpClient ?? http.Client(),
        _maxItemFetchAttempts = maxItemFetchAttempts,
        _retryBackoff = retryBackoff,
        _itemPageSize = itemPageSize,
        _pageGap = pageGap,
        _maxItemPages = maxItemPages;

  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 20);

  /// How many times a single library page is attempted before its transient
  /// failure surfaces — bounded, so a flaky network/server is ridden out but a
  /// genuinely down one fails in finite time rather than retrying forever.
  final int _maxItemFetchAttempts;

  /// Base backoff between page retries; the wait grows exponentially per
  /// attempt. Injectable (and `Duration.zero` in tests) so the retry path is
  /// covered without slowing the suite.
  final Duration _retryBackoff;

  /// How many items a single library page requests. Bounds each request so a
  /// large/slow server can't time out one unbounded fetch of the whole library.
  final int _itemPageSize;

  /// A brief yield between library pages, to keep playback/UI responsive and
  /// avoid hammering the server with back-to-back requests. Injectable (zero in
  /// tests) so pagination is covered without real delays.
  final Duration _pageGap;

  /// An absolute backstop on how many pages one listing will fetch. A real
  /// server always advances `StartIndex` (or reports a `TotalRecordCount`), so
  /// this only ever bites a broken server that ignores paging and would
  /// otherwise loop forever; at the default page size it still allows millions
  /// of items — far beyond any real music library. Injectable so a test can
  /// drive the backstop without 10,000 pages.
  final int _maxItemPages;

  @override
  Future<JellyfinServerInfo> fetchServerInfo(String baseUrl) async {
    final Uri uri = JellyfinEndpoints.serverInfo(baseUrl);
    final http.Response response = await _send(
      () => _client.get(uri, headers: const <String, String>{
        'Accept': 'application/json',
      }),
    );
    _checkStatus(response);
    final JellyfinServerInfo? info =
        JellyfinServerInfo.fromJson(_decodeObject(response));
    if (info == null) {
      throw JellyfinException.notJellyfin();
    }
    return info;
  }

  @override
  Future<JellyfinAuthResult> authenticateByName({
    required String baseUrl,
    required String username,
    required String password,
    required String deviceId,
  }) async {
    final Uri uri = JellyfinEndpoints.authenticateByName(baseUrl);
    final http.Response response = await _send(
      () => _client.post(
        uri,
        headers: <String, String>{
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Authorization': JellyfinAuthHeader.forClient(deviceId),
        },
        // Jellyfin's auth body. The password lives only in this request and is
        // never logged or echoed into an error.
        body: jsonEncode(<String, String>{
          'Username': username,
          'Pw': password,
        }),
      ),
    );
    _checkStatus(response);
    final JellyfinAuthResult? result =
        JellyfinAuthResult.fromJson(_decodeObject(response));
    if (result == null) {
      throw JellyfinException.notJellyfin();
    }
    return result;
  }

  @override
  Future<JellyfinItemListing> fetchItems(
    JellyfinSession session, {
    required JellyfinItemKind kind,
  }) async {
    final List<JellyfinItemDto> items = <JellyfinItemDto>[];
    int skipped = 0;
    int startIndex = 0;
    int page = 0;

    // Page through the whole library in bounded chunks. A page-level transient
    // failure is retried inside `_sendRetrying`; if it ultimately fails it
    // *throws* here — so the caller keeps the previous catalog rather than
    // committing a truncated one — while a single unparseable *item* is skipped
    // (counted, never thrown) so one bad track can't fail the whole sync.
    while (true) {
      // Absolute backstop: stop (and flag the truncation) if a broken server
      // ignores paging and would otherwise loop forever. A real server always
      // advances or reports a total, so this never fires in practice.
      if (page >= _maxItemPages) {
        JellyfinSyncDiagnostics.capped(kind: kind, pages: page);
        break;
      }
      page++;

      final Uri uri = JellyfinEndpoints.items(
        session.baseUrl,
        userId: session.userId,
        kind: kind,
        startIndex: startIndex,
        limit: _itemPageSize,
      );
      final http.Response response = await _sendRetrying(
        () => _client.get(uri, headers: <String, String>{
          'Accept': 'application/json',
          'Authorization': JellyfinAuthHeader.forToken(
              session.deviceId, session.accessToken),
        }),
        kind: kind,
      );
      _checkStatus(response);

      final Map<String, dynamic> json = _decodeObject(response);
      final Object? rawItems = json['Items'];
      if (rawItems is! List) {
        // A valid but empty library, or a shape we don't recognize — stop here
        // rather than treating it as an error.
        break;
      }

      for (final Object? entry in rawItems) {
        if (entry is! Map<String, dynamic>) {
          skipped++;
          continue;
        }
        final JellyfinItemDto? dto = _parseItem(entry);
        if (dto == null) {
          skipped++;
          continue;
        }
        items.add(dto);
      }

      final int received = rawItems.length;
      startIndex += received;

      final Object? rawTotal = json['TotalRecordCount'];
      final int? total = rawTotal is num ? rawTotal.toInt() : null;
      final bool reachedTotal = total != null && startIndex >= total;

      // Stop on the server's own total, on a short (final) page, or on an empty
      // page. (A server that returns a *full* page forever is caught by the
      // page-count backstop at the top of the loop instead.)
      if (received == 0 || received < _itemPageSize || reachedTotal) {
        break;
      }

      await _pageDelay();
    }

    JellyfinSyncDiagnostics.skipped(
      kind: kind,
      skipped: skipped,
      kept: items.length,
    );
    return JellyfinItemListing(items: items, skippedCount: skipped);
  }

  /// Parses one wire entry into a DTO, or `null` when it is unusable.
  ///
  /// Defence-in-depth: [JellyfinItemDto.fromJson] already coerces every field
  /// so it shouldn't throw, but guarding here guarantees one malformed entry is
  /// skipped — never propagated — even if a future field is added without a
  /// coercing read.
  static JellyfinItemDto? _parseItem(Map<String, dynamic> entry) {
    try {
      return JellyfinItemDto.fromJson(entry);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> verifySession(JellyfinSession session) async {
    // `/Users/Me` is a tiny authenticated call: a 401 means the token is no
    // longer valid, a transport failure means the server is unreachable. The
    // body is irrelevant, so it is not parsed.
    final Uri uri = JellyfinEndpoints.currentUser(session.baseUrl);
    final http.Response response = await _send(
      () => _client.get(uri, headers: <String, String>{
        'Accept': 'application/json',
        'Authorization':
            JellyfinAuthHeader.forToken(session.deviceId, session.accessToken),
      }),
    );
    _checkStatus(response);
  }

  @override
  Future<JellyfinStreamProbe> probeStream(Uri url) async {
    // A one-byte ranged GET: enough to see the real status and content type the
    // engine will get, without downloading the track. Jellyfin honours Range on
    // its media endpoints (it powers seeking), so this returns `206` with two
    // bytes rather than the whole file.
    //
    // Auth rides in the URL's `api_key` query — exactly how the engine will
    // fetch it — so no `Authorization` header is added here: the probe must
    // mirror what `just_audio`/ExoPlayer actually sends, and query auth also
    // survives the redirects (e.g. Cloudflare) a stripped header would not. The
    // status is returned, not checked, so the caller can tell auth / web-page /
    // non-audio apart; only a transport failure throws.
    final http.Response response = await _send(
      () => _client.get(url, headers: const <String, String>{
        'Accept': '*/*',
        'Range': 'bytes=0-1',
      }),
    );
    return JellyfinStreamProbe(
      statusCode: response.statusCode,
      contentType: response.headers['content-type'],
    );
  }

  @override
  Future<Lyrics?> fetchLyrics(JellyfinSession session, String itemId) async {
    final Uri uri = JellyfinEndpoints.lyrics(session.baseUrl, itemId: itemId);
    final http.Response response = await _send(
      () => _client.get(uri, headers: _authHeaders(session)),
    );
    // No lyrics on the server is a normal outcome, not an error.
    if (response.statusCode == 404) return null;
    _checkStatus(response);
    return _parseLyrics(_decodeObject(response));
  }

  @override
  Future<void> reportPlayback(
    JellyfinSession session, {
    required String itemId,
    required JellyfinPlaybackEvent event,
    required Duration position,
  }) async {
    final Uri uri = switch (event) {
      JellyfinPlaybackEvent.started =>
        JellyfinEndpoints.playbackStarted(session.baseUrl),
      JellyfinPlaybackEvent.progress ||
      JellyfinPlaybackEvent.paused ||
      JellyfinPlaybackEvent.resumed =>
        JellyfinEndpoints.playbackProgress(session.baseUrl),
      JellyfinPlaybackEvent.stopped =>
        JellyfinEndpoints.playbackStopped(session.baseUrl),
    };
    // PositionTicks is Jellyfin's 100-nanosecond unit (10 ticks per
    // microsecond) — the same unit the item listings report RunTimeTicks in.
    final Map<String, Object> body = <String, Object>{
      'ItemId': itemId,
      'PositionTicks': position.inMicroseconds * 10,
    };
    if (event != JellyfinPlaybackEvent.stopped) {
      // `static=true` streams (and offline copies) play the original file
      // bytes, so DirectPlay is the honest label for the dashboard.
      body['CanSeek'] = true;
      body['IsPaused'] = event == JellyfinPlaybackEvent.paused;
      body['PlayMethod'] = 'DirectPlay';
    }
    final http.Response response = await _send(
      () => _client.post(
        uri,
        headers: <String, String>{
          ..._authHeaders(session),
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      ),
    );
    // The body is deliberately not parsed: Jellyfin answers these with
    // `204 No Content` — a 2xx alone means the report landed.
    _checkStatus(response);
  }

  @override
  Future<void> registerRemoteControlCapabilities(
    JellyfinSession session,
  ) async {
    final Uri uri = JellyfinEndpoints.capabilitiesFull(session.baseUrl);
    final http.Response response = await _send(
      () => _client.post(
        uri,
        headers: <String, String>{
          ..._authHeaders(session),
          'Content-Type': 'application/json',
        },
        // Declare audio playback + media control so the server lists this
        // session as controllable and pushes Playstate commands to it. No
        // GeneralCommands are claimed (Linthra has no volume transport), and
        // no persistent identifier is offered.
        body: jsonEncode(<String, Object>{
          'PlayableMediaTypes': <String>['Audio'],
          'SupportedCommands': <String>[],
          'SupportsMediaControl': true,
          'SupportsPersistentIdentifier': false,
        }),
      ),
    );
    // Jellyfin answers `204 No Content`; a 2xx alone means it landed.
    _checkStatus(response);
  }

  @override
  Future<Set<String>> fetchFavoriteIds(JellyfinSession session) async {
    final Uri uri = JellyfinEndpoints.favoriteAudioItems(
      session.baseUrl,
      userId: session.userId,
    );
    final http.Response response = await _send(
      () => _client.get(uri, headers: _authHeaders(session)),
    );
    _checkStatus(response);
    final Map<String, dynamic> json = _decodeObject(response);
    final Object? rawItems = json['Items'];
    if (rawItems is! List) return <String>{};
    final Set<String> ids = <String>{};
    for (final Object? entry in rawItems) {
      if (entry is Map<String, dynamic>) {
        final Object? id = entry['Id'];
        if (id is String && id.isNotEmpty) ids.add(id);
      }
    }
    return ids;
  }

  @override
  Future<void> setFavorite(
    JellyfinSession session,
    String itemId, {
    required bool favorite,
  }) async {
    final Uri uri = JellyfinEndpoints.favoriteItem(
      session.baseUrl,
      userId: session.userId,
      itemId: itemId,
    );
    final Map<String, String> headers = _authHeaders(session);
    final http.Response response = await _send(
      () => favorite
          ? _client.post(uri, headers: headers)
          : _client.delete(uri, headers: headers),
    );
    _checkStatus(response);
  }

  @override
  Future<List<JellyfinPlaylistDto>> fetchPlaylists(
    JellyfinSession session,
  ) async {
    final Uri uri = JellyfinEndpoints.playlists(
      session.baseUrl,
      userId: session.userId,
    );
    final http.Response response = await _send(
      () => _client.get(uri, headers: _authHeaders(session)),
    );
    _checkStatus(response);
    final Map<String, dynamic> json = _decodeObject(response);
    final Object? rawItems = json['Items'];
    if (rawItems is! List) return const <JellyfinPlaylistDto>[];
    final List<JellyfinPlaylistDto> playlists = <JellyfinPlaylistDto>[];
    for (final Object? entry in rawItems) {
      if (entry is Map<String, dynamic>) {
        final JellyfinPlaylistDto? dto = JellyfinPlaylistDto.fromJson(entry);
        if (dto != null) playlists.add(dto);
      }
    }
    return playlists;
  }

  @override
  Future<List<JellyfinPlaylistEntry>> fetchPlaylistEntries(
    JellyfinSession session,
    String playlistId,
  ) async {
    final Uri uri = JellyfinEndpoints.playlistItems(
      session.baseUrl,
      playlistId: playlistId,
      userId: session.userId,
    );
    final http.Response response = await _send(
      () => _client.get(uri, headers: _authHeaders(session)),
    );
    _checkStatus(response);
    final Map<String, dynamic> json = _decodeObject(response);
    final Object? rawItems = json['Items'];
    if (rawItems is! List) return const <JellyfinPlaylistEntry>[];
    final List<JellyfinPlaylistEntry> entries = <JellyfinPlaylistEntry>[];
    for (final Object? entry in rawItems) {
      if (entry is Map<String, dynamic>) {
        final JellyfinPlaylistEntry? parsed =
            JellyfinPlaylistEntry.fromJson(entry);
        if (parsed != null) entries.add(parsed);
      }
    }
    return entries;
  }

  @override
  Future<String> createPlaylist(
    JellyfinSession session, {
    required String name,
    List<String> itemIds = const <String>[],
  }) async {
    final Uri uri = JellyfinEndpoints.createPlaylist(
      session.baseUrl,
      name: name,
      userId: session.userId,
      itemIds: itemIds,
    );
    final http.Response response = await _send(
      () => _client.post(uri, headers: _authHeaders(session)),
    );
    _checkStatus(response);
    final Map<String, dynamic> json = _decodeObject(response);
    final Object? id = json['Id'];
    if (id is! String || id.isEmpty) {
      throw JellyfinException.unsupportedResponse(response.statusCode);
    }
    return id;
  }

  @override
  Future<void> addItemsToPlaylist(
    JellyfinSession session,
    String playlistId,
    List<String> itemIds,
  ) async {
    if (itemIds.isEmpty) return;
    final Uri uri = JellyfinEndpoints.addPlaylistItems(
      session.baseUrl,
      playlistId: playlistId,
      userId: session.userId,
      itemIds: itemIds,
    );
    final http.Response response = await _send(
      () => _client.post(uri, headers: _authHeaders(session)),
    );
    _checkStatus(response);
  }

  @override
  Future<void> removeItemsFromPlaylist(
    JellyfinSession session,
    String playlistId,
    List<String> itemIds,
  ) async {
    if (itemIds.isEmpty) return;
    // Jellyfin removes by *entry* id (PlaylistItemId), not media id, so resolve
    // the entry ids for the requested media ids from the current playlist first.
    final List<JellyfinPlaylistEntry> entries =
        await fetchPlaylistEntries(session, playlistId);
    final Set<String> targets = itemIds.toSet();
    final List<String> entryIds = <String>[
      for (final JellyfinPlaylistEntry entry in entries)
        if (targets.contains(entry.itemId) && entry.playlistItemId != null)
          entry.playlistItemId!,
    ];
    if (entryIds.isEmpty) {
      // The server didn't expose entry ids (or the items are already gone):
      // surface an honest "couldn't use the response" rather than a silent ok.
      throw JellyfinException.unsupportedResponse();
    }
    final Uri uri = JellyfinEndpoints.removePlaylistEntries(
      session.baseUrl,
      playlistId: playlistId,
      entryIds: entryIds,
    );
    final http.Response response = await _send(
      () => _client.delete(uri, headers: _authHeaders(session)),
    );
    _checkStatus(response);
  }

  @override
  Future<void> deletePlaylist(
    JellyfinSession session,
    String playlistId,
  ) async {
    final Uri uri =
        JellyfinEndpoints.deleteItem(session.baseUrl, itemId: playlistId);
    final http.Response response = await _send(
      () => _client.delete(uri, headers: _authHeaders(session)),
    );
    _checkStatus(response);
  }

  /// The standard headers for an authenticated JSON call: the token rides in the
  /// `Authorization` header (built in one place, never logged).
  Map<String, String> _authHeaders(JellyfinSession session) {
    return <String, String>{
      'Accept': 'application/json',
      'Authorization':
          JellyfinAuthHeader.forToken(session.deviceId, session.accessToken),
    };
  }

  /// Parses Jellyfin's `/Audio/<id>/Lyrics` body into [Lyrics], or `null` when
  /// it carries no usable lines. Each entry is a `Text` string plus an optional
  /// `Start` in 100-nanosecond ticks (synced) — or no `Start` at all (plain).
  static Lyrics? _parseLyrics(Map<String, dynamic> json) {
    final Object? raw = json['Lyrics'];
    if (raw is! List) return null;
    final List<LyricLine> lines = <LyricLine>[];
    for (final Object? entry in raw) {
      if (entry is! Map<String, dynamic>) continue;
      final Object? text = entry['Text'];
      if (text is! String) continue;
      final int? ticks = (entry['Start'] as num?)?.toInt();
      lines.add(LyricLine(
        text: text,
        start: (ticks != null && ticks >= 0)
            ? Duration(microseconds: ticks ~/ 10)
            : null,
      ));
    }
    if (lines.isEmpty) return null;
    return Lyrics(lines: lines);
  }

  /// Runs a request with a timeout, turning any transport-level failure (DNS,
  /// refused connection, TLS handshake, timeout) into a single friendly
  /// "not reachable" error without leaking low-level details.
  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(_timeout);
    } on TimeoutException {
      throw JellyfinException.notReachable();
    } on http.ClientException {
      throw JellyfinException.notReachable();
    } on Exception {
      // SocketException / HandshakeException and friends: all "can't reach it".
      throw JellyfinException.notReachable();
    }
  }

  /// Like [_send] but bounded-retries *transient* failures — a timeout, a
  /// dropped connection, or a retryable server status (5xx / 408 / 429) — with
  /// exponential backoff, for the idempotent paged reads [fetchItems] makes.
  ///
  /// Auth (401/403) and other client errors are returned unretried for
  /// [_checkStatus] to map (retrying them is pointless and could lock an
  /// account out). Non-idempotent writes deliberately keep using single-shot
  /// [_send] so a retried POST can't double-apply. After the last attempt a
  /// retryable status is returned as-is so [_checkStatus] still maps it to a
  /// friendly error; a transient transport failure throws "not reachable".
  Future<http.Response> _sendRetrying(
    Future<http.Response> Function() request, {
    required JellyfinItemKind kind,
  }) async {
    JellyfinException lastTransport = JellyfinException.notReachable();
    for (int attempt = 1; attempt <= _maxItemFetchAttempts; attempt++) {
      if (attempt > 1) {
        JellyfinSyncDiagnostics.retry(
          kind: kind,
          attempt: attempt,
          maxAttempts: _maxItemFetchAttempts,
        );
        await _backoff(attempt);
      }
      final http.Response response;
      try {
        response = await request().timeout(_timeout);
      } on TimeoutException {
        lastTransport = JellyfinException.notReachable();
        continue;
      } on http.ClientException {
        lastTransport = JellyfinException.notReachable();
        continue;
      } on Exception {
        lastTransport = JellyfinException.notReachable();
        continue;
      }
      final bool canRetryAgain = attempt < _maxItemFetchAttempts;
      if (canRetryAgain && _isRetryableStatus(response.statusCode)) {
        continue;
      }
      return response;
    }
    throw lastTransport;
  }

  /// Whether an HTTP status is worth retrying: a server-side 5xx, a request
  /// timeout (408), or a rate-limit (429). A 4xx like 401/403/404 is the
  /// server's settled answer and is never retried.
  static bool _isRetryableStatus(int code) =>
      code >= 500 || code == 408 || code == 429;

  /// Exponential backoff before a page retry: base, 2×, 4× … per attempt. A
  /// `Duration.zero` base (tests) waits not at all, keeping the retry path fast
  /// to cover.
  Future<void> _backoff(int attempt) {
    if (_retryBackoff == Duration.zero) return Future<void>.value();
    // `attempt` is >= 2 here (attempt 1 never backs off), so the factor is
    // 1, 2, 4, … for attempts 2, 3, 4 …
    final int factor = 1 << (attempt - 2);
    return Future<void>.delayed(_retryBackoff * factor);
  }

  /// A brief yield between library pages (see [_pageGap]). Zero-cost when the
  /// gap is `Duration.zero` (tests).
  Future<void> _pageDelay() {
    if (_pageGap == Duration.zero) return Future<void>.value();
    return Future<void>.delayed(_pageGap);
  }

  /// Maps an HTTP status to a [JellyfinException]. 2xx passes; everything else
  /// throws before the body is parsed, so error handling never depends on
  /// response content (and never echoes it).
  void _checkStatus(http.Response response) {
    final int code = response.statusCode;
    if (code >= 200 && code < 300) {
      return;
    }
    if (code == 401 || code == 403) {
      throw JellyfinException.unauthorized();
    }
    if (code >= 500) {
      throw JellyfinException.serverError(code);
    }
    if (code == 408 || code == 429) {
      // A request timeout or a rate-limit (often a Cloudflare/reverse-proxy
      // 429) is *transient*, not a wrong address — surface it as a server error
      // so the sync's calm "try again in a moment" path is taken rather than the
      // misleading "doesn't look like a Jellyfin server". Matches the retryable
      // set in `_isRetryableStatus`, so a persistent one that outlived its
      // retries still reads honestly.
      throw JellyfinException.serverError(code);
    }
    // Other 4xx (wrong path, Cloudflare 4xx, …) usually mean the address isn't
    // really a Jellyfin API root.
    throw JellyfinException.notJellyfin();
  }

  /// Decodes a JSON object body, or throws [JellyfinErrorKind.notJellyfin] when
  /// the body isn't JSON (e.g. a Cloudflare/HTML error page) or isn't an object.
  Map<String, dynamic> _decodeObject(http.Response response) {
    Object? decoded;
    try {
      // Decode the raw bytes as UTF-8 rather than using `response.body`, which
      // falls back to latin1 when the server omits a charset and would mangle
      // non-ASCII titles and artist names.
      final String text = utf8.decode(response.bodyBytes, allowMalformed: true);
      decoded = jsonDecode(text);
    } on FormatException {
      throw JellyfinException.notJellyfin();
    }
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw JellyfinException.notJellyfin();
  }
}
