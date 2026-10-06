/// The response shape of `GET /status` — confirms an address is a reachable
/// Audiobookshelf server before any credentials are sent.
class AudiobookshelfServerStatus {
  const AudiobookshelfServerStatus({this.serverVersion, this.isInitialized});

  /// `null` on servers older than v2.6.0, which don't report a version at
  /// all: confirmed directly against `/status`'s real handler across
  /// release tags back to v2.2.0, not just the current server source.
  final String? serverVersion;

  /// Whether the server has completed initial setup (a root user exists).
  final bool? isInitialized;

  /// Parses `GET /status`'s response, or returns `null` when nothing about
  /// it confirms this is genuinely an Audiobookshelf server (a different
  /// server, or a Cloudflare/reverse-proxy error page that happens to be
  /// valid JSON).
  ///
  /// `app: "audiobookshelf"` was only added in v2.6.0 (confirmed against the
  /// real `/status` handler at v2.2.0, v2.5.0, v2.6.0, and the current tag),
  /// so it's checked only when present. A server old enough not to send it
  /// still identifies itself well enough via `isInit`, the one field every
  /// version examined has always sent.
  static AudiobookshelfServerStatus? fromJson(Map<String, dynamic> json) {
    final Object? app = json['app'];
    if (app != null && app != 'audiobookshelf') return null;
    final Object? isInit = json['isInit'];
    if (app == null && isInit is! bool) return null;
    return AudiobookshelfServerStatus(
      serverVersion: _coerceString(json['serverVersion']),
      isInitialized: isInit is bool ? isInit : null,
    );
  }
}

/// The response shape of `POST /login` — the subset Linthra needs to build an
/// [AudiobookshelfSession]. The server returns considerably more (media
/// progress, bookmarks, server settings, …); later PRs read those as that
/// data becomes relevant, this one only needs enough to authenticate.
class AudiobookshelfAuthResult {
  const AudiobookshelfAuthResult({
    required this.userId,
    required this.accessToken,
    this.refreshToken,
    this.userName,
    this.defaultLibraryId,
  });

  final String userId;
  final String accessToken;

  /// Present only when the request sent `x-return-tokens: true` — otherwise
  /// the server sets it as an httpOnly cookie instead, which this client
  /// intentionally never relies on (a cookie jar is a browser assumption,
  /// not something to build into a mobile HTTP client's request flow).
  final String? refreshToken;
  final String? userName;
  final String? defaultLibraryId;

  /// Parses the login response, or returns `null` if the user id or access
  /// token are absent or the wrong type (an unexpected body), so the client
  /// can fail clearly with a sign-in error rather than throw a `TypeError`.
  ///
  /// `accessToken` and `refreshToken` arrived in Audiobookshelf 2.26.0. Older
  /// servers only send `token`, which never expires and is what they expect
  /// as the bearer token, so it stands in for the access token there (with no
  /// refresh token). Newer servers still send it beside the new pair, and the
  /// new access token wins.
  static AudiobookshelfAuthResult? fromJson(Map<String, dynamic> json) {
    final Object? user = json['user'];
    if (user is! Map<String, dynamic>) return null;
    final String? userId = _coerceString(user['id']);
    final String? accessToken =
        _coerceString(user['accessToken']) ?? _coerceString(user['token']);
    if (userId == null || accessToken == null) return null;
    return AudiobookshelfAuthResult(
      userId: userId,
      accessToken: accessToken,
      refreshToken: _coerceString(user['refreshToken']),
      userName: _coerceString(user['username']),
      defaultLibraryId: _coerceString(json['userDefaultLibraryId']),
    );
  }
}

/// One entry from `GET /api/libraries` — enough to let a user pick which
/// library to browse. The items inside one are fetched separately, as
/// [AudiobookshelfLibraryItemDto]s.
class AudiobookshelfLibraryDto {
  const AudiobookshelfLibraryDto({
    required this.id,
    required this.name,
    this.mediaType,
  });

  final String id;
  final String name;

  /// The library's configured media type (e.g. `book`, `podcast`), when
  /// reported. The audiobook browser shows the `book` libraries; a library
  /// that doesn't report a type is treated as one rather than hidden.
  final String? mediaType;

  /// Parses one library entry, or returns `null` when the id or name are
  /// absent/wrong-typed, so a single malformed entry can be skipped rather
  /// than failing the whole listing.
  static AudiobookshelfLibraryDto? fromJson(Map<String, dynamic> json) {
    final String? id = _coerceString(json['id']);
    final String? name = _coerceString(json['name']);
    if (id == null || name == null) return null;
    return AudiobookshelfLibraryDto(
      id: id,
      name: name,
      mediaType: _coerceString(json['mediaType']),
    );
  }
}

/// One book from `GET /api/libraries/{id}/items`, reduced to what a listing
/// needs. Deliberately not the whole item: Audiobookshelf sends the audio
/// files, the chapter list, the library-file records and the user's progress
/// with every entry, and none of that belongs in a browse list. The domain
/// model that does carry chapters and playback data comes with milestone 2.
class AudiobookshelfLibraryItemDto {
  const AudiobookshelfLibraryItemDto({
    required this.id,
    required this.title,
    this.subtitle,
    this.authorName,
    this.narratorName,
    this.seriesName,
    this.duration,
  });

  /// The library item's id: the handle every later call (cover, playback,
  /// progress) uses.
  final String id;

  final String title;
  final String? subtitle;

  /// The author(s), already joined into one display string by the server on a
  /// minified response, or joined here from `authors[]` when a server sends
  /// the full shape instead.
  final String? authorName;

  /// The narrator(s), same two shapes as [authorName]. Worth showing for an
  /// audiobook: the same title read by a different narrator is a different
  /// listen.
  final String? narratorName;

  /// The series this book belongs to, when the server reports one.
  final String? seriesName;

  /// Total running time, when reported. `null` on a book the server hasn't
  /// finished scanning, which the UI renders as no duration rather than 0:00.
  final Duration? duration;

  /// Parses one library item, or returns `null` when there is no id or no
  /// title (the two things a row can't be drawn without), so a single
  /// unscanned or malformed entry is skipped instead of failing the page.
  static AudiobookshelfLibraryItemDto? fromJson(Map<String, dynamic> json) {
    final String? id = _coerceString(json['id']);
    if (id == null) return null;

    final Object? media = json['media'];
    final Map<String, dynamic> mediaMap =
        media is Map<String, dynamic> ? media : const <String, dynamic>{};
    final Object? metadata = mediaMap['metadata'];
    final Map<String, dynamic> meta =
        metadata is Map<String, dynamic> ? metadata : const <String, dynamic>{};

    final String? title = _coerceString(meta['title']);
    if (title == null) return null;

    return AudiobookshelfLibraryItemDto(
      id: id,
      title: title,
      subtitle: _coerceString(meta['subtitle']),
      // `authorName`/`narratorName` are what a minified listing sends (the
      // shape this client asks for); the `authors`/`narrators` fallbacks keep
      // a full response readable too, so the parser doesn't depend on the
      // query string staying exactly as it is.
      authorName: _coerceString(meta['authorName']) ??
          _joinNames(meta['authors'], key: 'name'),
      narratorName:
          _coerceString(meta['narratorName']) ?? _joinNames(meta['narrators']),
      seriesName: _coerceString(meta['seriesName']) ??
          _joinNames(meta['series'], key: 'name'),
      duration: _coerceDuration(mediaMap['duration']),
    );
  }
}

/// One page of `GET /api/libraries/{id}/items`: the items plus enough of the
/// envelope to know whether more of the library is still waiting.
class AudiobookshelfLibraryItemsPage {
  const AudiobookshelfLibraryItemsPage({
    required this.items,
    required this.rawCount,
    required this.total,
    required this.page,
  });

  /// The books that could be read. Shorter than [rawCount] when the server
  /// sent a record this parser had to skip.
  final List<AudiobookshelfLibraryItemDto> items;

  /// How many entries the server actually sent on this page, before any were
  /// skipped. This, not [items], is what says how far through the library a
  /// caller has read: a page whose every record was unreadable still consumed
  /// its slice of the library, and counting the parsed books instead would
  /// strand everything after it.
  final int rawCount;

  /// How many items the whole (filtered) library has, per the server. Falls
  /// back to this page's [rawCount] when the server omits it, so "have we got
  /// everything?" never reads as "there are more" forever.
  final int total;

  /// The zero-based page index this response answered.
  final int page;

  static AudiobookshelfLibraryItemsPage fromJson(
    Map<String, dynamic> json, {
    required int requestedPage,
  }) {
    final Object? results = json['results'];
    final List<AudiobookshelfLibraryItemDto> items =
        <AudiobookshelfLibraryItemDto>[];
    int rawCount = 0;
    if (results is List) {
      for (final Object? entry in results) {
        rawCount++;
        if (entry is! Map<String, dynamic>) continue;
        final AudiobookshelfLibraryItemDto? item =
            AudiobookshelfLibraryItemDto.fromJson(entry);
        // One bad record is skipped, never thrown: a half-scanned book can't
        // cost the user the rest of the page.
        if (item != null) items.add(item);
      }
    }
    final Object? total = json['total'];
    final Object? page = json['page'];
    return AudiobookshelfLibraryItemsPage(
      items: items,
      rawCount: rawCount,
      total: total is int && total >= 0 ? total : rawCount,
      page: page is int && page >= 0 ? page : requestedPage,
    );
  }
}

/// Joins a list of names into one display string.
///
/// Handles both shapes Audiobookshelf uses for these fields: a list of plain
/// strings (`narrators`) and a list of objects with a name (`authors`,
/// `series`). Returns `null` when nothing usable is in there.
String? _joinNames(Object? value, {String? key}) {
  if (value is! List) return null;
  final List<String> names = <String>[];
  for (final Object? entry in value) {
    final String? name = key == null
        ? _coerceString(entry)
        : (entry is Map<String, dynamic> ? _coerceString(entry[key]) : null);
    if (name != null) names.add(name);
  }
  return names.isEmpty ? null : names.join(', ');
}

/// Reads a duration in (possibly fractional) seconds, or `null` when it is
/// absent, the wrong type, or not a positive length.
Duration? _coerceDuration(Object? value) {
  if (value is! num || !value.isFinite || value <= 0) return null;
  return Duration(milliseconds: (value * 1000).round());
}

/// Reads [value] as a non-blank [String], or `null` for anything else
/// (absent, wrong type, or empty/whitespace-only) — the shared rule every DTO
/// in this file applies to every field it reads, so a blank or malformed
/// value is treated the same as an absent one.
String? _coerceString(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
