import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Persists remote artwork bytes to a small, Linthra-managed disk cache keyed
/// by the credential-free artwork identity ([artworkImageProvider]'s `Uri`
/// argument), so a cover fetched once survives an app restart.
///
/// Why this exists: Flutter's built-in `ImageCache` is in-memory only and is
/// dropped the moment the process ends, so every remote cover — Jellyfin's
/// token-free image URL, or a resolved Subsonic/Plex reference — was otherwise
/// re-fetched on *every* app launch (issue #356: "every time I open the app it
/// has to re-download all images for everything"). This cache sits in front of
/// the network fetch inside `artworkImageProvider`: a hit is read straight from
/// disk (no network at all); a miss still loads exactly as it did before this
/// cache existed and, in the background, fetches + writes the bytes so the
/// *next* launch is a hit.
///
/// Distinct from `MediaArtworkCache` (which caches a small platform-loadable
/// `content://` copy for the lock screen / Android Auto, in the OS-reclaimable
/// temp directory): this cache backs the in-app UI — `artworkImageProvider`,
/// the one seam every track row, album/artist tile, header, and mini-player
/// loads art through — lives in the app-support directory (durable, not
/// reclaimed under memory pressure), and is a plain, safe-to-delete folder of
/// image files with no manifest to go stale.
///
/// Security / privacy:
///  - The cache **key** — and therefore the on-disk file name — is a SHA-256
///    hash of the *credential-free* artwork identity: a Jellyfin cover URL is
///    already token-free by construction, and Subsonic/Plex covers are keyed by
///    their opaque reference (`subsonic-cover:<id>`, `plex-thumb:<path>`)
///    rather than any resolved, authenticated URL. Nothing that could carry a
///    token or server address is ever part of a file name, and there is no
///    index/manifest that could record one either.
///  - The *authenticated* fetch URL a provider's `ArtworkReferenceResolver`
///    produces exists only as a local inside [_warmNow], used once to fetch the
///    bytes, and is never written to disk or logged.
///  - A missing or corrupt (0-byte / unreadable) cache entry is always treated
///    as a miss, never surfaced as an error — the caller falls back to a fresh
///    fetch and, ultimately, its placeholder.
///
/// Per server, fresh and bounded (#739):
///  - A Subsonic or Plex reference (`subsonic-cover:al-12`) names a cover on
///    *a* server, not on which one, so it is cached under the server it
///    resolves against now ([serverOf]): another server's `al-12` is another
///    file. A plain URL (Jellyfin's) already names its server and keeps the
///    file name it always had.
///  - Bytes are saved only when they start like an image (JPEG, PNG, GIF,
///    WebP, BMP), so an error page served with an image content type is never
///    kept as a cover.
///  - A cover older than [refreshAfter] is still shown, and fetched again in
///    the background, so one changed on the server shows up eventually.
///  - The cache is capped at [maxBytes]. Past the cap, the files fetched
///    longest ago go first: a cover in use is fetched again every
///    [refreshAfter], so what goes is what hasn't been shown for a while.
class ArtworkDiskCache {
  ArtworkDiskCache({
    required Directory directory,
    Uri Function(Uri key)? resolveFetchUrl,
    String? Function(Uri key)? serverOf,
    Future<List<int>?> Function(Uri url)? fetch,
    http.Client? httpClient,
    this.maxBytes = defaultMaxBytes,
    this.refreshAfter = defaultRefreshAfter,
    DateTime Function()? now,
  })  : _directory = directory,
        _resolveFetchUrl = resolveFetchUrl ?? _identity,
        _serverOf = serverOf ?? _anyServer,
        _now = now ?? DateTime.now,
        _httpClient = httpClient ?? http.Client() {
    _fetch = fetch ?? _defaultFetch;
  }

  /// How much the cache may hold before the oldest covers are removed.
  static const int defaultMaxBytes = 256 * 1024 * 1024;

  /// How old a cover may get before it is fetched again in the background.
  static const Duration defaultRefreshAfter = Duration(days: 30);

  /// The cap; see [defaultMaxBytes].
  final int maxBytes;

  /// See [defaultRefreshAfter].
  final Duration refreshAfter;

  /// The app's persistent artwork-cache directory. Nothing is created yet —
  /// [_warmNow] creates it lazily on first write. Call once at startup and pass
  /// the result to the constructor; tests inject their own temp directory.
  static Future<Directory> defaultDirectory() async {
    final Directory base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, 'artwork_cache'));
  }

  final Directory _directory;

  /// Turns a credential-free key into the URL to fetch. Defaults to the
  /// identity function (an already-loadable Jellyfin URL needs no resolving);
  /// the app wires this to `artwork_image.dart`'s installed
  /// `ArtworkReferenceResolver` so a Subsonic/Plex reference resolves with the
  /// live session's credential at fetch time, never persisted.
  final Uri Function(Uri key) _resolveFetchUrl;

  /// The non-secret identity of the server [key] resolves against right now:
  /// a hash of a Subsonic server's address, a Plex `machineIdentifier`, or ''
  /// for a URL that names its own server. Null when nothing would resolve it
  /// (signed out): then nothing is read from or written to disk for it.
  final String? Function(Uri key) _serverOf;

  final DateTime Function() _now;

  final http.Client _httpClient;
  late final Future<List<int>?> Function(Uri url) _fetch;

  /// Covers written since the cap was last enforced.
  int _writesSinceTrim = 0;

  /// Whether this run enforced the cap at its first use yet. A cache filled
  /// before there was a cap (or under a bigger one) is brought under it then,
  /// not only after a write, which a cache of fresh hits never makes.
  bool _trimmedAtFirstUse = false;

  /// The cap enforcement running now, if any.
  Future<void>? _trimming;

  /// Enforce the cap after this many writes (and after the first one).
  static const int _trimEvery = 50;

  /// In-flight warms, keyed by the cache key's hash, so a burst of rebuilds for
  /// the same reference (e.g. a scrolling list) share one fetch instead of
  /// racing to write the same file — and so a caller (tests) can await the same
  /// result rather than firing a second one.
  final Map<String, Future<void>> _warming = <String, Future<void>>{};

  static const Duration _timeout = Duration(seconds: 20);

  File _fileFor(String hash) => File(p.join(_directory.path, '$hash.img'));

  /// The file name hash for [key] on [server], or null when nothing would
  /// resolve [key] now.
  String? _hashFor(Uri key) {
    final String? server;
    try {
      server = _serverOf(key);
    } catch (_) {
      return null;
    }
    if (server == null) return null;
    return _hash(key, server);
  }

  /// The cached file for [key] if a non-empty copy already exists on disk, or
  /// `null` on a miss or a corrupt (0-byte / unreadable) entry. A cheap
  /// synchronous stat, so `artworkImageProvider` can consult it while building
  /// an `ImageProvider` with no `await`.
  ///
  /// A hit older than [refreshAfter] is still returned, and fetched again in
  /// the background ([warm]), so a cover changed on the server replaces it.
  File? cachedFile(Uri key) {
    _trimAtFirstUse();
    final String? hash = _hashFor(key);
    if (hash == null) return null;
    final File file = _fileFor(hash);
    final FileStat stat;
    try {
      stat = file.statSync();
    } on FileSystemException {
      // An odd permissions error: not a usable hit.
      return null;
    }
    // Missing (notFound) or empty: not a usable hit either.
    if (stat.type != FileSystemEntityType.file || stat.size <= 0) return null;
    if (_now().difference(stat.modified) >= refreshAfter) {
      unawaited(warm(key));
    }
    return file;
  }

  /// Whether [file] holds a cover that is recent enough to keep as it is.
  Future<bool> _isFresh(File file) async {
    final FileStat stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size <= 0) return false;
    return _now().difference(stat.modified) < refreshAfter;
  }

  /// Fetches [key]'s bytes and writes them to the persistent cache, so the
  /// *next* [cachedFile] call is a hit. Safe to call on every render: it
  /// de-duplicates concurrent warms for the same key (returning the same
  /// in-flight future) and re-checks the disk before fetching, so a real cache
  /// hit never spends the network twice. Never throws — every failure (an
  /// unresolvable reference, a network error, a non-image response, a write
  /// failure) just leaves the entry to warm again on a later call.
  ///
  /// A cover older than [refreshAfter] is fetched again and replaced, and kept
  /// as it is when the new fetch fails.
  Future<void> warm(Uri key) {
    _trimAtFirstUse();
    final String? hash = _hashFor(key);
    if (hash == null) return Future<void>.value();
    final Future<void>? inFlight = _warming[hash];
    if (inFlight != null) return inFlight;
    final Future<void> future = _runWarm(key, hash);
    _warming[hash] = future;
    return future;
  }

  // A plain try/finally wrapper rather than `_warmNow(...).whenComplete(...)`:
  // chaining `whenComplete` onto a future whose last hop is a native file
  // completion (as `_warmNow`'s is, via `File.rename`) has been observed to
  // never resolve on some platforms/engines, silently stalling every future
  // caller awaiting [warm]. try/finally reaches the same "always clean up the
  // in-flight entry" guarantee without that combinator.
  Future<void> _runWarm(Uri key, String hash) async {
    try {
      await _warmNow(key, hash);
    } finally {
      // `Map.remove` would return the removed Future itself here (the map's
      // value type), which trips the unawaited-futures lint on a bare
      // expression statement; removeWhere discards it via a bool predicate
      // instead, with the exact same effect.
      _warming.removeWhere((String k, Future<void> _) => k == hash);
    }
  }

  Future<void> _warmNow(Uri key, String hash) async {
    try {
      final File file = _fileFor(hash);
      if (await file.exists() && await _isFresh(file)) return;
      final Uri url = _resolveFetchUrl(key);
      // [hash] named the server [key] was asked for under; the URL names the
      // one signed in now. Both are read from the live session with nothing
      // awaited between these two lines, so a switch while the disk was
      // checked above shows here, and the other server's cover is never filed
      // under this one. The URL carries its server, so what it fetches later
      // is still this one's.
      if (_hashFor(key) != hash) return;
      if (!url.isScheme('http') && !url.isScheme('https')) {
        // An unresolved reference (e.g. signed out) resolves to itself, which
        // is never fetchable — nothing to warm; a later render (signed back
        // in) retries.
        return;
      }
      final List<int>? bytes = await _fetch(url);
      if (bytes == null || bytes.isEmpty || !looksLikeImage(bytes)) return;
      if (!await _directory.exists()) {
        await _directory.create(recursive: true);
      }
      // Write to a temp sibling then rename, so a crash mid-write can't leave a
      // truncated image that would fail to decode until evicted.
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
      _wrote();
    } catch (_) {
      // Best-effort: leave it to retry on a later render.
    }
  }

  /// Enforces the cap once, in the background, the first time the cache is
  /// used in this run (see [_trimmedAtFirstUse]).
  void _trimAtFirstUse() {
    if (_trimmedAtFirstUse) return;
    _trimmedAtFirstUse = true;
    if (_trimming != null) return;
    unawaited(_runTrim());
  }

  /// Enforces the cap after the first write and every [_trimEvery] after it,
  /// in the background and one run at a time.
  void _wrote() {
    final bool first = _writesSinceTrim == 0 && _trimming == null;
    _writesSinceTrim++;
    if (!first && _writesSinceTrim < _trimEvery) return;
    if (_trimming != null) return;
    _writesSinceTrim = 0;
    unawaited(_runTrim());
  }

  Future<void> _runTrim() async {
    final Future<void> run = trim();
    _trimming = run;
    try {
      await run;
    } finally {
      _trimming = null;
    }
  }

  /// Removes the covers fetched longest ago until the cache is within
  /// [maxBytes] again, leaving some room so the next writes don't trim at
  /// once. Never throws.
  Future<void> trim() async {
    try {
      if (!await _directory.exists()) return;
      final List<(File, FileStat)> covers = <(File, FileStat)>[];
      int total = 0;
      await for (final FileSystemEntity entity in _directory.list()) {
        if (entity is! File || !entity.path.endsWith('.img')) continue;
        final FileStat stat = await entity.stat();
        if (stat.type != FileSystemEntityType.file) continue;
        covers.add((entity, stat));
        total += stat.size;
      }
      if (total <= maxBytes) return;
      covers.sort(
        ((File, FileStat) a, (File, FileStat) b) =>
            a.$2.modified.compareTo(b.$2.modified),
      );
      final int target = maxBytes - maxBytes ~/ 10;
      for (final (File file, FileStat stat) in covers) {
        if (total <= target) break;
        // One being fetched again right now is left to its warm.
        if (_warming.containsKey(p.basenameWithoutExtension(file.path))) {
          continue;
        }
        try {
          await file.delete();
          total -= stat.size;
        } on FileSystemException {
          // Gone already, or not ours to delete: leave it.
        }
      }
    } catch (_) {
      // Best-effort: the next write tries again.
    }
  }

  /// Whether [bytes] start the way a JPEG, PNG, GIF, WebP or BMP file does.
  ///
  /// Not a full decode (this runs where no image codec is available), but
  /// enough to keep a body that only claimed to be an image, such as an error
  /// page sent with `image/jpeg`, out of the cache.
  static bool looksLikeImage(List<int> bytes) {
    bool startsWith(List<int> prefix, [int offset = 0]) {
      if (bytes.length < offset + prefix.length) return false;
      for (int i = 0; i < prefix.length; i++) {
        if (bytes[offset + i] != prefix[i]) return false;
      }
      return true;
    }

    return startsWith(const <int>[0xFF, 0xD8, 0xFF]) || // JPEG
        startsWith(const <int>[0x89, 0x50, 0x4E, 0x47]) || // \x89PNG
        startsWith(const <int>[0x47, 0x49, 0x46, 0x38]) || // GIF8
        (startsWith(const <int>[0x52, 0x49, 0x46, 0x46]) && // RIFF....WEBP
            startsWith(const <int>[0x57, 0x45, 0x42, 0x50], 8)) ||
        startsWith(const <int>[0x42, 0x4D]); // BMP
  }

  /// A credential-free, filename-safe cache key: the SHA-256 of [key]'s string
  /// form, after the identity of its [server] when it has one. Neither carries
  /// a token (see class docs), so the hash doesn't either. Hashing also keeps
  /// an odd reference from escaping the cache directory.
  ///
  /// A key with no server ('') hashes as it always did, so a URL's cover keeps
  /// the file it had before servers were told apart.
  static String _hash(Uri key, String server) => sha256
      .convert(utf8.encode(
        server.isEmpty ? key.toString() : '$server\u0000$key',
      ))
      .toString();

  static Uri _identity(Uri key) => key;

  static String? _anyServer(Uri key) => '';

  /// The default fetcher: a plain GET (over the reused [_httpClient]) that
  /// returns the body bytes only for a 2xx image response. Any transport error,
  /// non-2xx status, or non-image body yields `null`. The URL — which may carry
  /// a credential — is never logged, even on error.
  Future<List<int>?> _defaultFetch(Uri url) async {
    try {
      final http.Response response =
          await _httpClient.get(url).timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final String contentType =
          (response.headers['content-type'] ?? '').toLowerCase();
      if (!contentType.startsWith('image/')) return null;
      final List<int> bytes = response.bodyBytes;
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  /// Releases the shared HTTP client. The on-disk cache is left intact — it is
  /// durable and persists across restarts by design; call when the owning
  /// container is torn down.
  void dispose() => _httpClient.close();
}
