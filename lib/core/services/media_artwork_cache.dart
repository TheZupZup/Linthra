import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'media_artwork_content_uri.dart';
import 'media_artwork_source.dart';

/// Turns a credential-free artwork *reference* (e.g. Subsonic's
/// `subsonic-cover:<id>`) into a **safe, local** media-session artwork URI: a
/// `content://` URI (served by the app's FileProvider) over a private cached
/// cover the platform media session (lock screen / Android Auto now-playing card)
/// can read.
///
/// Why a separate cache from the in-app render seam (`artworkImageProvider`):
/// the in-app UI can hand Flutter a credential-bearing `getCoverArt`
/// `NetworkImage` and load it itself, but the platform media session loads
/// `MediaItem.artUri` in a place Linthra can't authenticate — so an authenticated
/// URL must never be put there. Instead Linthra fetches the cover *itself* (with
/// the live session's salt+token, used once and discarded), writes the bytes to a
/// private file, and hands the session a `content://` URI for it (see
/// [mediaArtworkContentUri]). `content://` rather than `file:` because the
/// session loads the URI in its **own process** (e.g. Android Auto), which can't
/// read an app-private `file:` path.
///
/// Privacy / security invariants:
/// - the cache *key* — and therefore the file name and the `content://` path —
///   is a hash of the credential-free reference, never the username, salt, token,
///   server URL, or the authenticated `getCoverArt` URL;
/// - the authenticated URL exists only as a local inside [resolve], is used once
///   to fetch, and is never returned, persisted, or logged;
/// - any failure (signed out, network error, a non-image body, a write error)
///   yields `null` so the caller falls back to *no* artwork — it never throws and
///   never blocks playback.
class MediaArtworkCache implements MediaArtworkSource {
  MediaArtworkCache({
    required Uri? Function(Uri reference) resolveUrl,
    Future<List<int>?> Function(Uri url)? fetch,
    Future<Directory> Function()? directory,
  })  : _resolveUrl = resolveUrl,
        _fetch = fetch ?? _httpFetch,
        _directory = directory ?? _defaultDirectory;

  /// Turns a credential-free [reference] into the authenticated fetch URL for the
  /// live session, or `null` when it isn't a reference this cache can resolve
  /// (e.g. signed out, or a Jellyfin/local URL). The returned URL carries the
  /// credential and is used only inside [resolve].
  final Uri? Function(Uri reference) _resolveUrl;

  /// Fetches the raw image bytes for an (authenticated) `url`, or `null` on any
  /// failure / a non-image response. Must never log the URL.
  final Future<List<int>?> Function(Uri url) _fetch;

  /// The private directory cached artwork files live in.
  final Future<Directory> Function() _directory;

  /// Successful resolutions: cache key -> local `file:` URI. Skips a repeat
  /// disk/network round-trip for a cover already fetched this session.
  final Map<String, Uri> _memo = <String, Uri>{};

  /// In-flight resolutions, so concurrent requests for the same reference share
  /// one fetch instead of racing to write the same file. The completer is
  /// removed when the fetch settles (success or failure), so a failed cover can
  /// be retried on a later request.
  final Map<String, Completer<Uri?>> _inFlight = <String, Completer<Uri?>>{};

  static const Duration _timeout = Duration(seconds: 20);

  /// The safe `content://` URI for [reference] if it has already been fetched
  /// and cached this session, else `null`. Synchronous and side-effect-free, so
  /// the media handler can attach it while building a `MediaItem` without
  /// awaiting — covers are warmed ahead of time by `MediaArtworkPrewarmService`.
  @override
  Uri? cached(Uri reference) => _memo[_cacheKey(reference)];

  /// Resolves [reference] to a safe `content://` artwork URI, fetching and
  /// caching the image on a miss. Returns `null` (never throws) when the artwork
  /// can't be produced safely — the caller then shows no artwork.
  Future<Uri?> resolve(Uri reference) {
    final String key = _cacheKey(reference);
    final Uri? memoized = _memo[key];
    if (memoized != null) return Future<Uri?>.value(memoized);
    final Completer<Uri?>? pending = _inFlight[key];
    if (pending != null) return pending.future;

    final Completer<Uri?> completer = Completer<Uri?>();
    _inFlight[key] = completer;
    unawaited(_resolveUncached(reference, key).then<void>(
      (Uri? result) {
        _inFlight.remove(key);
        completer.complete(result);
      },
      onError: (Object _, StackTrace __) {
        // _resolveUncached is written not to throw; guard anyway so a stray
        // failure resolves to "no artwork" rather than an unhandled error.
        _inFlight.remove(key);
        completer.complete(null);
      },
    ));
    return completer.future;
  }

  Future<Uri?> _resolveUncached(Uri reference, String key) async {
    final Directory dir = await _directory();
    final File file = File(p.join(dir.path, '$key.img'));

    // Disk hit from an earlier run: reuse it without re-fetching (and without
    // ever touching the credential again).
    if (await file.exists() && await file.length() > 0) {
      final Uri uri = mediaArtworkContentUri(file);
      _memo[key] = uri;
      return uri;
    }

    // Mint the authenticated URL on demand, fetch, and discard it. A null URL
    // means "not a resolvable reference / signed out" -> no artwork.
    final Uri? url = _resolveUrl(reference);
    if (url == null) return null;
    final List<int>? bytes = await _fetch(url);
    if (bytes == null || bytes.isEmpty) return null;

    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      // Write to a temp sibling then rename, so a crash mid-write can't leave a
      // truncated image that would render broken until evicted.
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // A write failure must not leak or throw: fall back to no artwork.
      return null;
    }
    final Uri uri = mediaArtworkContentUri(file);
    _memo[key] = uri;
    return uri;
  }

  /// A credential-free, filename-safe cache key: the SHA-256 of the
  /// *credential-free* reference string (e.g. `subsonic-cover:al-123`). The
  /// reference carries no username, salt, token, server URL, or auth query, so
  /// neither does the key — and hashing also keeps an odd id from escaping the
  /// cache directory.
  static String _cacheKey(Uri reference) =>
      sha256.convert(utf8.encode(reference.toString())).toString();

  static Future<Directory> _defaultDirectory() async {
    final Directory base = await getTemporaryDirectory();
    return Directory(p.join(base.path, 'media_session_artwork'));
  }

  /// The default fetcher: a plain GET that returns the body bytes only for a 2xx
  /// image response. Any transport error, non-2xx status, or non-image body
  /// (e.g. a Subsonic error envelope) yields `null`. The URL — which carries the
  /// credential — is never logged, even on error.
  static Future<List<int>?> _httpFetch(Uri url) async {
    final http.Client client = http.Client();
    try {
      final http.Response response = await client.get(url).timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final String contentType =
          (response.headers['content-type'] ?? '').toLowerCase();
      if (!contentType.startsWith('image/')) return null;
      final List<int> bytes = response.bodyBytes;
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      // Swallow every failure (and never log the credentialed URL).
      return null;
    } finally {
      client.close();
    }
  }
}
