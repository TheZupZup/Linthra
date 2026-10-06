import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/models/download_progress.dart';
import '../../core/models/track.dart';
import '../../core/repositories/download_preferences.dart';
import '../../core/repositories/download_repository.dart';
import '../../core/repositories/download_store.dart';
import '../../core/repositories/offline_file_store.dart';
import '../../core/services/cache_eviction_policy.dart';
import '../../core/services/connectivity_service.dart';
import '../../core/services/download_scheduler.dart';
import '../../core/services/offline_cache_manager.dart';
import '../../core/services/offline_copy_origins.dart';
import '../../core/services/remote_track_downloader.dart';
import '../../core/services/track_prefetcher.dart';

/// The app's [DownloadRepository] *and* [OfflineCacheManager]: it owns the
/// offline-cache *policy* in one place and delegates the moving parts to focused
/// seams — durable metadata to a [DownloadStore], cached bytes to an
/// [OfflineFileStore], the remote byte-fetch to a [RemoteTrackDownloader], and
/// the (pure) eviction decision to a [CacheEvictionPolicy].
///
/// Promises enforced here so a caller can't skip them:
///  - **Downloads are user-initiated.** A track's download *status* changes only
///    in response to [requestDownload] / [removeDownload] (or an explicit clear /
///    pin). Auto-*preloaded* tracks ([prefetch]) are cached ahead of play too,
///    but they never take on a user-download status: they stay invisible to the
///    downloads UI, count toward the limit, and are the first to be evicted.
///  - **Automatic caching never removes a user download.** A pre-cache makes
///    room only by evicting other pre-cached entries, and never the ones that
///    are playing or about to play. If that isn't enough it simply doesn't
///    cache; the track streams when it's reached.
///  - **Bounded parallelism.** Several downloads fetch their bytes at once (via
///    a [DownloadScheduler]) so caching feels fast, but never more than the
///    scheduler's small limit — the app never opens an unbounded number of
///    requests. The byte fetch runs in parallel; the cache *commit* (eviction +
///    write + metadata) is serialized, so the limit is honored even when several
///    downloads finish at once. A repeated request for a track already
///    downloading (or queued) is ignored, so a track is never fetched twice.
///  - **Source-aware.** A remote (Jellyfin) track has its bytes fetched and
///    written to the offline directory; an on-device track is already local, so
///    it's recorded as available offline with no fetch and no managed file.
///  - **The mobile-data policy is respected.** A *remote* request runs on Wi-Fi
///    always, on mobile data only when the user turned on "Allow mobile data",
///    and never while offline. When the connection isn't allowed the request is
///    queued (not run) and [requestDownload] reports why, so the UI can prompt
///    the user instead of failing silently. A held request is asked again
///    whenever `networkChanges` reports a new connection, and when the
///    listener changes the policy ([retryHeldDownloads]), so it starts by
///    itself once it may, instead of sitting at "queued" for good.
///  - **Fetched with the account that asked.** A request remembers the
///    account its provider was signed in with (`accountScopeOf`). If that
///    account signs out or another takes its place while the request waits
///    (held by the network policy, or queued for a slot), it is dropped rather
///    than fetched with the new session, which would download another
///    account's item, or nothing, under this track. One already fetching then
///    is not saved either: its bytes are the old account's item.
///  - **Stays under the cache limit.** Before writing a remote download, the
///    policy evicts least-recently-used, unpinned, not-currently-playing tracks
///    to make room; if it still won't fit, the download is refused with a
///    friendly [CacheStorageException] and nothing is cached.
///
/// Safety: only app-managed cache files (in the offline directory) are ever
/// deleted — by file name derived from the non-secret track id. The user's
/// local source files (an on-device track's own path) are never passed to the
/// file store, so they can't be deleted here. A managed file the OS reclaimed
/// is detected on load and its stale metadata pruned, so playback falls back to
/// streaming instead of opening a missing file.
///
/// The authenticated URL a remote fetch needs is resolved inside the
/// [RemoteTrackDownloader] at fetch time; this repository never sees, stores, or
/// logs it. Persisted metadata carries only the non-secret track id, a
/// id-derived file name, the source's URI scheme, a byte size, timestamps, and
/// the pinned flag — never a token or URL.
class CacheDownloadRepository
    implements DownloadRepository, OfflineCacheManager, TrackPrefetcher {
  CacheDownloadRepository({
    required DownloadStore store,
    required OfflineFileStore files,
    required RemoteTrackDownloader downloader,
    required ConnectivityService connectivity,
    required DownloadPreferences preferences,
    CacheEvictionPolicy policy = const CacheEvictionPolicy(),
    DownloadScheduler? scheduler,
    Track? Function()? currentlyPlayingTrack,
    DateTime Function()? now,
    Future<List<Track>> Function()? catalogForMigration,
    Stream<NetworkStatus>? networkChanges,
    String? Function(Track track)? accountScopeOf,
    OfflineCopyOrigins? origins,
  })  : _store = store,
        _files = files,
        _downloader = downloader,
        _connectivity = connectivity,
        _preferences = preferences,
        _policy = policy,
        _scheduler = scheduler ?? DownloadScheduler(),
        _currentlyPlayingTrack = currentlyPlayingTrack,
        _now = now ?? DateTime.now,
        _catalogForMigration = catalogForMigration,
        _accountScopeOf = accountScopeOf,
        _origins = origins {
    // Followed from the start rather than from the first hold: a change that
    // lands while the first request is still asking the policy has to be
    // counted too (see [_networkChangeCount]).
    _networkSubscription = networkChanges?.listen(
      _onNetworkChange,
      // A connectivity stream that fails only means no automatic start; a
      // fresh request or a policy change still asks again.
      onError: (Object _, StackTrace __) {},
    );
    _originSubscription = origins?.changes.listen(
      (_) => _onOriginsChanged(),
      onError: (Object _, StackTrace __) {},
    );
  }

  final DownloadStore _store;
  final OfflineFileStore _files;
  final RemoteTrackDownloader _downloader;
  final ConnectivityService _connectivity;
  final DownloadPreferences _preferences;
  final CacheEvictionPolicy _policy;

  /// Bounds how many remote downloads fetch their bytes at the same time.
  final DownloadScheduler _scheduler;

  /// Supplies the track currently playing (or `null`), so it is never evicted
  /// out from under the user. A whole [Track] (not just an id) so its
  /// provider-aware [CachedTrack.cacheKey] protects exactly that provider's
  /// copy — a same-id track from another provider stays evictable. Read lazily
  /// so the repository doesn't depend on the playback layer at construction.
  final Track? Function()? _currentlyPlayingTrack;

  final DateTime Function() _now;

  /// Resolves the current catalog tracks, used once on load to migrate legacy
  /// (pre-v0.1.6, `sourceType`-less) cache records to provider-aware keys by
  /// inferring each record's provider from the catalog. The pre-v0.1.6 catalog is
  /// 1:1 bare-id→provider, so an unambiguous match is safe; an id the catalog now
  /// exposes under two providers is left unmigrated rather than mis-attributed.
  /// Null in tests/dev that don't exercise migration; the app wires it to the
  /// music library.
  final Future<List<Track>> Function()? _catalogForMigration;

  /// The non-secret identity of the account [track]'s provider is signed in
  /// with right now (`jellyfin:<fingerprint>`, …), or null when signed out or
  /// not wired (tests and dev, where every request counts as one account).
  final String? Function(Track track)? _accountScopeOf;

  /// The server each provider whose ids only mean something on one server is
  /// connected to now. A copy of such a provider's track is stamped with the
  /// server it came from and is kept in [_downloads] only while that server
  /// is connected; otherwise it waits in [_dormant]. Null in tests and dev,
  /// where every copy is unbound.
  final OfflineCopyOrigins? _origins;

  /// Follows [OfflineCopyOrigins.changes], so copies move between [_downloads]
  /// and [_dormant] as the listener connects to another server or signs out.
  StreamSubscription<void>? _originSubscription;

  /// Copies from a server other than the one connected now (or kept through
  /// a sign-out), by [_dormantKey]. Persisted with the rest and counted in
  /// the cache's usage and eviction, but never served, shown or promoted,
  /// since the same id names another song here. Each goes back into
  /// [_downloads] when its server is connected again.
  final Map<String, CachedTrack> _dormant = <String, CachedTrack>{};

  /// Follows the `networkChanges` stream, which reports each change of
  /// connection so downloads the network policy held back can be asked again.
  /// Null where the platform has no live network status: held downloads then
  /// wait for [retryHeldDownloads] or a fresh request.
  StreamSubscription<NetworkStatus>? _networkSubscription;

  /// Bumped on every connection change. A request notes it before asking the
  /// network policy, so a change that lands while the answer is on its way
  /// (and so found nothing held yet) still gets the request asked again.
  int _networkChangeCount = 0;

  bool _disposed = false;

  /// Remote requests the network policy is holding back, by cache key, with
  /// the account each was asked under. Their rows read "queued" and they are
  /// asked again on every connection change and by [retryHeldDownloads].
  /// In memory only: after a restart they read as not downloaded again.
  final Map<String, ({Track track, String? scope})> _held =
      <String, ({Track track, String? scope})>{};

  final Map<String, DownloadStatus> _statuses = <String, DownloadStatus>{};

  /// The durable cache references, loaded once and kept in sync with the store,
  /// so removal can find the file to delete, eviction can sort by metadata, and
  /// usage is cheap to total.
  final Map<String, CachedTrack> _downloads = <String, CachedTrack>{};

  /// The user download in flight for each track (queued for a slot or
  /// actively fetching). Reserved synchronously at the start of
  /// [requestDownload] so two rapid taps — or two callers — can never start the
  /// same fetch twice.
  final Map<String, _CacheOperation> _inFlight = <String, _CacheOperation>{};

  /// The pre-cache fetching each track's bytes right now. Reserved
  /// synchronously at the start of [prefetch] so two concurrent prefetches of
  /// the same track can't both spend network fetching it. Kept separate from
  /// [_inFlight] so a preload never makes a user [requestDownload] think the
  /// track is already a download.
  ///
  /// A download and a pre-cache of the same track can be in flight together (a
  /// download tapped while that track is being pre-cached). Each has its own
  /// [_CacheOperation], so a removal or a clear marks exactly the operations
  /// running when it lands, and one operation finishing can never consume the
  /// cancellation meant for the other.
  final Map<String, _CacheOperation> _preloading = <String, _CacheOperation>{};

  /// Live byte progress for in-flight downloads, surfaced via [progressStream].
  final Map<String, DownloadProgress> _progress = <String, DownloadProgress>{};

  /// Serializes the cache *commit* (eviction + write + metadata) across the
  /// otherwise-parallel downloads, so the limit can't be overshot when several
  /// finish at once. Bytes are fetched in parallel; only this step is ordered.
  Future<void> _commitChain = Future<void>.value();

  final StreamController<Map<String, DownloadStatus>> _changes =
      StreamController<Map<String, DownloadStatus>>.broadcast();

  final StreamController<CacheSnapshot> _cacheChanges =
      StreamController<CacheSnapshot>.broadcast();

  final StreamController<Map<String, DownloadProgress>> _progressChanges =
      StreamController<Map<String, DownloadProgress>>.broadcast();

  bool _loaded = false;
  Future<void>? _loading;

  /// Seeds the in-memory state from the durable cache, once. Along the way it
  /// self-heals: a managed entry whose file is gone is dropped (stale metadata),
  /// a managed entry missing its byte size (e.g. written by an earlier version)
  /// is backfilled from disk, so usage and eviction are accurate, and files no
  /// entry names are removed ([OfflineFileStore.removeAbandoned]).
  ///
  /// Every caller that arrives while that load is running waits for it rather
  /// than starting its own: a second load would put back the records as they
  /// were on disk over anything changed since the first finished (a pre-cached
  /// song the listener has since downloaded, a download just removed).
  Future<void> _ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    bool changed = false;
    final List<CachedTrack> records = await _store.loadDownloads();
    final Map<String, String?> legacyScheme = await _legacySchemeFor(records);
    final List<CachedTrack> kept = <CachedTrack>[];
    for (final CachedTrack record in records) {
      CachedTrack cached = record;
      // Legacy (pre-v0.1.6) records carry no sourceType, so they key as
      // `\0<id>` while a live track keys as `<scheme>\0<id>` — the download would
      // look missing to the row/offline consumers, and a fresh request would
      // re-fetch it. Re-key by inferring the provider from the catalog
      // (unambiguous matches only); the cache file name is untouched, so the
      // bytes keep resolving, and re-saving heals the record for next launch.
      final String? inferred = legacyScheme[cached.trackId];
      if (inferred != null &&
          inferred.isNotEmpty &&
          (cached.sourceType == null || cached.sourceType!.isEmpty)) {
        cached = cached.copyWith(sourceType: inferred);
        changed = true;
      }
      if (cached.isManaged) {
        final int? size = await _files.sizeFor(cached.fileName!);
        if (size == null) {
          // The managed file is gone; drop the record so it isn't counted and
          // playback falls back to streaming.
          changed = true;
          continue;
        }
        if (cached.sizeBytes == 0 && size > 0) {
          cached = cached.copyWith(sizeBytes: size);
          changed = true;
        }
      }
      kept.add(cached);
    }
    // Sorted for the server connected now in one step, after every await
    // above, so a connect landing mid-load can't leave some copies sorted for
    // the server before it.
    for (final CachedTrack cached in kept) {
      final CachedTrack adopted = _adopted(cached);
      if (!identical(adopted, cached)) changed = true;
      if (!offlineCopyBelongs(adopted, _origins)) {
        _dormant[_dormantKey(adopted)] = adopted;
        continue;
      }
      _downloads[_keyForCached(adopted)] = adopted;
      // A preloaded entry is cached and playable, but never a *download*: it
      // stays out of the status map so the downloads UI doesn't show it.
      if (!adopted.preloaded) {
        _statuses[_keyForCached(adopted)] = DownloadStatus.downloaded;
      }
    }
    if (changed) await _save();
    // A download cut off mid-commit (the app killed during "Download all", or
    // a record save that failed after the file was moved into place) leaves
    // its `.part` temp or a finished file no record names. Nothing counts,
    // evicts or clears those, so they go now, before anything here writes
    // (#747). Every record is kept, set-aside copies and pre-cached ones
    // included. A record list that read as empty may be a document that
    // couldn't be read rather than no downloads, so then only the temps go.
    await _files.removeAbandoned(
      <String>{
        for (final CachedTrack cached in kept)
          if (cached.isManaged) cached.fileName!,
      },
      temporaryOnly: records.isEmpty,
    );
    _loaded = true;
  }

  /// [copy] given the server connected now, when it is a bound copy saved
  /// before its server was recorded: it was made on the server the listener
  /// was using, which is the one connected now unless they switched before
  /// this version first ran. Otherwise [copy] itself.
  CachedTrack _adopted(CachedTrack copy) {
    if (copy.origin != null) return copy;
    final String? scheme = copy.sourceType;
    if (scheme == null) return copy;
    final String? server = _serverOf(scheme);
    return server == null ? copy : copy.copyWith(origin: server);
  }

  /// The server [scheme]'s copies are bound to right now, or null when they
  /// aren't bound or its provider is signed out (or can't say).
  String? _serverOf(String scheme) {
    final OfflineCopyOrigins? origins = _origins;
    if (origins == null) return null;
    try {
      return origins.binds(scheme) ? origins.current(scheme) : null;
    } catch (_) {
      return null;
    }
  }

  /// Whether [scheme]'s copies are bound to the server they came from.
  bool _binds(String? scheme) {
    final OfflineCopyOrigins? origins = _origins;
    if (origins == null || scheme == null) return false;
    try {
      return origins.binds(scheme);
    } catch (_) {
      return false;
    }
  }

  /// The listener connected to another server, or signed out or in: copies
  /// from the server now connected go back into use, everyone else's are set
  /// aside. Runs in the commit chain, so it never lands in the middle of a
  /// commit that is evicting or recording a copy.
  void _onOriginsChanged() {
    if (_disposed) return;
    unawaited(_commit(() async {
      // A load still running sorts with the server connected when it ends,
      // which may be the one before this change. One not started yet sorts
      // with whatever is connected then.
      final Future<void>? loading = _loading;
      if (loading != null) await loading;
      if (!_loaded || _disposed || !_resortCopies()) return;
      await _save();
      _emitStatus();
      _emitCache();
    }).catchError((Object _) {}));
  }

  /// Moves every copy to where it belongs for the server connected now, and
  /// says whether anything moved. Synchronous, so no request sees half of it.
  bool _resortCopies() {
    bool changed = false;
    for (final MapEntry<String, CachedTrack> entry
        in _downloads.entries.toList()) {
      final CachedTrack adopted = _adopted(entry.value);
      if (!identical(adopted, entry.value)) changed = true;
      if (offlineCopyBelongs(adopted, _origins)) {
        _downloads[entry.key] = adopted;
        continue;
      }
      _downloads.remove(entry.key);
      if (_statuses[entry.key] == DownloadStatus.downloaded) {
        _statuses.remove(entry.key);
      }
      _dormant[_dormantKey(adopted)] = adopted;
      changed = true;
    }
    for (final MapEntry<String, CachedTrack> entry
        in _dormant.entries.toList()) {
      final CachedTrack copy = entry.value;
      final String key = _keyForCached(copy);
      if (!offlineCopyBelongs(copy, _origins) || _downloads.containsKey(key)) {
        continue;
      }
      _dormant.remove(entry.key);
      _downloads[key] = copy;
      // A request still out for this track was asked on the server just
      // left, so it ends without saving anything and leaves this row as it
      // finds it (see [requestDownload]).
      if (!copy.preloaded) _statuses[key] = DownloadStatus.downloaded;
      changed = true;
    }
    return changed;
  }

  /// Where a set-aside copy is kept: its server plus its track's cache key,
  /// since two servers can each have a copy of the same id.
  static String _dormantKey(CachedTrack copy) =>
      '${copy.origin ?? ''}${String.fromCharCode(0)}${copy.cacheKey}';

  /// Every copy on disk, in use or set aside: what counts toward the cache
  /// limit and what eviction may pick from.
  List<CachedTrack> get _allCopies =>
      <CachedTrack>[..._downloads.values, ..._dormant.values];

  /// The provider scheme for each legacy (sourceType-less) record's bare id,
  /// resolved via the catalog oracle so those records can be re-keyed to
  /// provider-aware identity. Empty when there's nothing to migrate or no oracle
  /// is wired. A bare id the catalog exposes under more than one provider maps to
  /// null (ambiguous → left unmigrated rather than mis-attributed).
  Future<Map<String, String?>> _legacySchemeFor(
      List<CachedTrack> records) async {
    final Future<List<Track>> Function()? oracle = _catalogForMigration;
    if (oracle == null) return const <String, String?>{};
    final bool hasLegacy = records
        .any((CachedTrack c) => c.sourceType == null || c.sourceType!.isEmpty);
    if (!hasLegacy) return const <String, String?>{};
    final List<Track> tracks;
    try {
      tracks = await oracle();
    } catch (_) {
      return const <String, String?>{};
    }
    final Map<String, String?> byId = <String, String?>{};
    for (final Track track in tracks) {
      byId[track.id] =
          byId.containsKey(track.id) ? null : CachedTrack.schemeOf(track.uri);
    }
    return byId;
  }

  @override
  Stream<Map<String, DownloadStatus>> get statusStream async* {
    await _ensureLoaded();
    yield _snapshot();
    yield* _changes.stream;
  }

  @override
  Future<DownloadStatus> statusFor(String trackId) async {
    await _ensureLoaded();
    // A plain catalog-id convenience: the catalog's primary key makes ids unique
    // there, so a bare id resolves to one track. The cache itself is keyed
    // provider-aware (see [_snapshot]) and [statusStream] emits those keys — the
    // app's per-row status joins on the cache key, never this. Scans the
    // provider-aware map by id so a caller can still ask by plain id; under a
    // cross-provider same-id collision it returns the first matching copy.
    for (final MapEntry<String, DownloadStatus> e in _statuses.entries) {
      if (_trackIdOfKey(e.key) == trackId) return e.value;
    }
    return DownloadStatus.notDownloaded;
  }

  @override
  Stream<Map<String, DownloadProgress>> get progressStream async* {
    yield _progressSnapshot();
    yield* _progressChanges.stream;
  }

  @override
  Future<DownloadRequestOutcome> requestDownload(Track track) async {
    if (!_downloader.isRemote(track)) {
      // On-device track: no bytes to fetch and no network gate, so record it as
      // available offline directly.
      await _requestOnDeviceDownload(track);
      return DownloadRequestOutcome.started;
    }

    final String key = _keyForTrack(track);
    // Asked for now, so it is no longer waiting to be asked again. If the
    // network policy still holds it, it is held again on the way out.
    _held.remove(key);
    // Reserve the in-flight slot synchronously, before any `await`, so a second
    // request for the same track (a double tap, or a second caller) bails out
    // here instead of starting a duplicate fetch.
    final _CacheOperation? running = _inFlight[key];
    if (running != null &&
        !running.abandoned &&
        !_orphaned(running, track, preloaded: false)) {
      // A fresh, explicit request supersedes a pending cancellation of the
      // request still running (the user removed it and immediately asked
      // again): that request goes ahead, and its row shows where it really is
      // rather than staying at the "not downloaded" the removal set.
      if (running.canceled) {
        running.canceled = false;
        final DownloadStatus? phase = running.phase;
        if (phase != null) _set(key, phase);
      }
      return DownloadRequestOutcome.started;
    }
    // One still out was asked under an account that has signed out or been
    // replaced (or on a server no longer connected): it saves nothing (see
    // [_canceledOrOrphaned]), so it can't stand in for this request. It is
    // dropped, and this one is fetched with the account asking now.
    running?.canceled = true;
    final _CacheOperation operation = _CacheOperation(
      scope: _scopeOf(track),
      origin: _serverOf(_sourceTypeOf(track) ?? ''),
    );
    _inFlight[key] = operation;
    final int networkChangesBefore = _networkChangeCount;
    DownloadRequestOutcome outcome = DownloadRequestOutcome.started;
    try {
      outcome = await _runRemoteRequest(track, operation);
      return outcome;
    } on CacheStorageException {
      // The cache is full with nothing safe to evict; surface the friendly,
      // secret-free error so the UI can prompt to free space or raise the
      // limit. Status was already reset to not-downloaded before the throw.
      rethrow;
    } catch (_) {
      // Other errors may carry source-specific detail; the UI only needs the
      // failed state (which offers a retry) — but a download the user cancelled
      // mid-fetch must stay gone, not flip to "failed".
      if (!operation.canceled) {
        _set(key, DownloadStatus.failed);
      }
      return DownloadRequestOutcome.started;
    } finally {
      // Every path out of a request ends here, so a cancellation is settled
      // here. The step that noticed it (the wait for a slot, or the commit)
      // stopped without touching the status, which can still read "queued" or
      // "downloading": the slot can come after the cancel, and Clear all only
      // resets rows it can see. A cancelled download must not end there, or
      // the row sticks and pre-cache skips the track, so it goes back to not
      // downloaded, unless its bytes were committed before the cancel landed.
      // Or unless a download of it is in use anyway: one of this server's
      // that came back while a request asked on the server just left was out.
      // The row and the progress are left to the request that replaced this
      // one, if one did (see above).
      final bool current = identical(_inFlight[key], operation);
      final CachedTrack? committed = _downloads[key];
      if (current && operation.canceled && _statuses.containsKey(key)) {
        if (committed == null || committed.preloaded) {
          _set(key, DownloadStatus.notDownloaded);
        } else if (_statuses[key] != DownloadStatus.downloaded) {
          _set(key, DownloadStatus.downloaded);
        }
      }
      if (current) {
        _inFlight.remove(key);
        _clearProgress(key);
      }
      // Held back by the network policy: remember it, so it starts by itself
      // once the connection (or the policy) lets it. Done here, after the
      // in-flight slot is released, so the next ask isn't taken for a
      // duplicate of this one.
      if (outcome != DownloadRequestOutcome.started && !operation.canceled) {
        _hold(key, track, operation.scope, networkChangesBefore);
      }
    }
  }

  @override
  Future<void> retryHeldDownloads() async {
    if (_disposed || _held.isEmpty) return;
    final List<({Track track, String? scope})> held = _held.values.toList();
    _held.clear();
    await Future.wait(<Future<void>>[
      for (final ({Track track, String? scope}) entry in held)
        _retryHeld(entry.track, entry.scope),
    ]);
  }

  /// Asks again for one held download, unless the account it was asked under
  /// is gone: then it is dropped, since the session signed in now would fetch
  /// another account's item (or nothing) under this track.
  Future<void> _retryHeld(Track track, String? scope) async {
    final String key = _keyForTrack(track);
    if (_scopeOf(track) != scope) {
      if (!_inFlight.containsKey(key) &&
          _statuses[key] == DownloadStatus.queued) {
        _set(key, DownloadStatus.notDownloaded);
      }
      return;
    }
    try {
      await requestDownload(track);
    } on CacheStorageException {
      // Nothing safe left to evict. Nobody is looking at a snackbar for a
      // download that started on its own, so the row says it failed, and its
      // Retry explains the cache limit.
      _set(key, DownloadStatus.failed);
    }
  }

  /// Records [track] as held by the network policy. When the connection
  /// changed while this request was being decided, the request may have been
  /// answered for the connection before it, so it is asked again now rather
  /// than at the next change.
  void _hold(String key, Track track, String? scope, int networkChangesBefore) {
    if (_disposed) return;
    _held[key] = (track: track, scope: scope);
    if (_networkChangeCount != networkChangesBefore) {
      unawaited(retryHeldDownloads());
    }
  }

  void _onNetworkChange(NetworkStatus status) {
    _networkChangeCount++;
    // Offline can't run anything; whatever is held stays held.
    if (status == NetworkStatus.offline) return;
    unawaited(retryHeldDownloads());
  }

  /// Records an on-device track as available offline: its bytes are already
  /// local, so there is no fetch, no managed file, and no network gate.
  Future<void> _requestOnDeviceDownload(Track track) async {
    await _ensureLoaded();
    final String key = _keyForTrack(track);
    if (_statuses[key] == DownloadStatus.downloaded) return;
    // Through the same commit lock the remote path writes under. [_save] hands
    // the store a snapshot taken now and finishes asynchronously, so two
    // unserialized saves can land out of order and the older snapshot can
    // overwrite the newer one, losing a record. Requests arrive concurrently
    // (several rows at once, or a "Download all"), so this has to be ordered
    // even though there are no bytes to fetch.
    await _commit(() async {
      _downloads[key] = CachedTrack(
        trackId: track.id,
        sourceType: _sourceTypeOf(track),
        cachedAt: _now(),
      );
      await _save();
      _statuses[key] = DownloadStatus.downloaded;
      _emitStatus();
      _emitCache();
    });
  }

  /// Drives one remote download: skip if already cached, promote a preloaded
  /// copy in place, apply the mobile-data policy, then wait for a concurrency
  /// slot before fetching the bytes and committing them under the cache limit.
  Future<DownloadRequestOutcome> _runRemoteRequest(
    Track track,
    _CacheOperation operation,
  ) async {
    await _ensureLoaded();
    final String key = _keyForTrack(track);
    // Already cached — nothing to do. (A track that is downloading or queued is
    // already in [_inFlight], so it never reaches here a second time.)
    if (_statuses[key] == DownloadStatus.downloaded) {
      return DownloadRequestOutcome.started;
    }

    // A track preloaded ahead of play is already cached: promote it to a user
    // download in place, without re-fetching its bytes.
    final CachedTrack? maybePreloaded = _downloads[key];
    if (maybePreloaded != null &&
        maybePreloaded.preloaded &&
        maybePreloaded.isManaged) {
      // Serialized with every other metadata write for the same reason as the
      // on-device path above: an unordered save can be overwritten by an older
      // snapshot still in flight.
      //
      // The entry is read again *inside* the commit, because waiting for the
      // chain is exactly when a commit queued ahead can evict this preloaded
      // copy to make room for its own. Promoting the copy read before the wait
      // would persist a `downloaded` record pointing at a file that commit just
      // deleted. When it is gone, this returns false and the request falls
      // through to a real download below.
      final bool promoted = await _commit(() async {
        final CachedTrack? current = _downloads[key];
        if (current == null || !current.preloaded || !current.isManaged) {
          return false;
        }
        // Stamped as used now, like a download fetched now. A pre-cache
        // nobody has played yet has no access time, which eviction reads as
        // the least recently used, so the song just downloaded would be the
        // first download to go.
        _downloads[key] =
            current.copyWith(preloaded: false, lastAccessedAt: _now());
        try {
          await _saveOrThrow();
        } catch (_) {
          // Not saved, the next launch would find the pre-cache it was, free
          // to be evicted (#786): it stays one (unless a removal dropped it
          // while it was being saved), and the request says why.
          if (_downloads.containsKey(key)) _downloads[key] = current;
          _set(key, DownloadStatus.notDownloaded);
          throw const CacheStorageException(_recordNotSavedMessage);
        }
        // A Clear all deleting this copy's file (or a removal) dropped the
        // record while it was being saved, so there is nothing left to call
        // downloaded. A request the clear did not cancel fetches it below.
        if (!_downloads.containsKey(key)) return operation.canceled;
        _statuses[key] = DownloadStatus.downloaded;
        _emitStatus();
        _emitCache();
        return true;
      });
      if (promoted) return DownloadRequestOutcome.started;
    }

    // The network gate only matters here, where there are bytes to pull over the
    // network. When it blocks, the track waits as "queued" for an explicit
    // retry once allowed (the in-flight reservation is released by the caller),
    // and the outcome tells the UI why so it can prompt instead of failing.
    final _NetworkDecision decision = await _networkDecision();
    if (decision != _NetworkDecision.allowed) {
      _setPhase(key, operation, DownloadStatus.queued);
      return decision == _NetworkDecision.offline
          ? DownloadRequestOutcome.waitingForConnection
          : DownloadRequestOutcome.waitingForWifi;
    }

    // Accepted: show "queued" until a concurrency slot frees up, then fetch.
    _setPhase(key, operation, DownloadStatus.queued);
    // What the network policy says once the slot is free. A download can wait
    // a long time for one (a whole album is accepted at once and three fetch
    // at a time), and the listener can leave Wi-Fi or turn mobile data off
    // meanwhile. One that may no longer run is held like a request made now,
    // still "queued", and starts again when the connection allows it.
    _NetworkDecision atSlot = _NetworkDecision.allowed;
    await _scheduler.schedule(() async {
      // Removed or cleared while it waited for this slot: skip the fetch, so a
      // cancelled download spends no data and the slot goes straight to the
      // next one. [requestDownload] settles its status on the way out.
      if (operation.canceled) return;
      // The account it was asked under signed out or was replaced while it
      // waited: the session there now would fetch another account's item, or
      // nothing, so it is dropped like a cancelled download.
      if (_scopeOf(track) != operation.scope) {
        operation.canceled = true;
        return;
      }
      atSlot = await _networkDecision();
      if (atSlot != _NetworkDecision.allowed || operation.canceled) return;
      _setPhase(key, operation, DownloadStatus.downloading);
      // A file bigger than the whole cache can't fit whatever is evicted, so
      // it is stopped as soon as that shows rather than downloaded in full
      // first (#745). The exact fit is still decided at commit, against the
      // limit as it stands then.
      final int limit = await _preferences.maxCacheBytes();
      final _Downloaded downloaded;
      try {
        downloaded = await _download(
          track,
          operation,
          refuseOver: limit,
          stillWanted: () =>
              !_canceledOrOrphaned(operation, track, preloaded: false),
          onProgress: (int received, int? total) {
            if (identical(_inFlight[key], operation)) {
              _reportProgress(track, received, total);
            }
          },
        );
      } on _TooBig {
        if (identical(_inFlight[key], operation)) {
          _set(key, DownloadStatus.notDownloaded);
        }
        throw const CacheStorageException();
      }
      try {
        // Commit serially so concurrent downloads can't jointly overshoot the
        // limit; the (slow) byte fetch above already ran in parallel.
        await _commit(
          () => _cacheRemote(track, downloaded, operation: operation),
        );
      } finally {
        // Published by the commit, or not wanted after all.
        await downloaded.draft.discard();
      }
    });
    switch (atSlot) {
      case _NetworkDecision.allowed:
        return DownloadRequestOutcome.started;
      case _NetworkDecision.needsWifi:
        return DownloadRequestOutcome.waitingForWifi;
      case _NetworkDecision.offline:
        return DownloadRequestOutcome.waitingForConnection;
    }
  }

  /// Fetches [track] into a new draft file, a chunk at a time: a download is
  /// never held in memory whole, where a big hi-res file, three at once plus a
  /// pre-cache, could take several gigabytes and get the app killed (#745).
  ///
  /// Stops as soon as the size the server announced, or the bytes received so
  /// far, pass [refuseOver], throwing [_TooBig]: such a file can't fit, so the
  /// rest isn't worth the time or the data. Stops too, throwing
  /// [_Abandoned], once [stillWanted] says its bytes would be thrown away
  /// anyway (a removed download, a session that is gone), rather than
  /// pulling the rest of the file first.
  ///
  /// The draft is gone when this throws; otherwise the caller publishes or
  /// discards it.
  Future<_Downloaded> _download(
    Track track,
    _CacheOperation operation, {
    required int refuseOver,
    required bool Function() stillWanted,
    void Function(int received, int? total)? onProgress,
  }) async {
    bool tooBig = false;
    int shown = -1;
    void progress(int received, int? total) {
      // Both: a server can announce a size that fits and send more than it.
      if ((total ?? 0) > refuseOver || received > refuseOver) {
        tooBig = true;
        throw const _TooBig();
      }
      // A source that already counted further while it fetched isn't sent
      // back to an earlier count.
      if (received < shown) return;
      shown = received;
      onProgress?.call(received, total);
    }

    void checkWanted() {
      if (stillWanted()) return;
      operation.abandoned = true;
      throw const _Abandoned();
    }

    final RemoteTrackData data;
    try {
      data = await _downloader.fetch(track, onProgress: progress);
    } on Object {
      // A source that reports progress while it fetches hands the refusal
      // back inside its own error.
      if (tooBig) throw const _TooBig();
      rethrow;
    }
    final Stream<List<int>> body = data.body;
    final int? total = data.length;
    bool reading = false;
    OfflineFileDraft? draft;
    try {
      // Refused on the announced size before any of the body is read.
      progress(0, total);
      checkWanted();
      draft = await _files.createDraft(_fileBaseName(track, operation.origin));
      int received = 0;
      reading = true;
      await for (final List<int> chunk in body) {
        received += chunk.length;
        progress(received, total);
        checkWanted();
        await draft.add(chunk);
      }
      return _Downloaded(draft, data.fileExtension);
    } on Object {
      // A body never listened to is cancelled, so its connection is closed
      // rather than left open; leaving the loop above cancels one being read.
      if (!reading) await body.listen(null).cancel();
      await draft?.discard();
      rethrow;
    }
  }

  /// Writes a freshly fetched remote track's bytes, evicting first to stay under
  /// the limit. A user download ([preloaded] `false`) takes on the `downloaded`
  /// status; a [preloaded] one is cached but stays out of the status map.
  ///
  /// Throws [CacheStorageException] (after resetting status) when a user
  /// download can't fit even after evicting everything safe to remove; a preload
  /// that can't fit returns quietly (it's best-effort).
  Future<void> _cacheRemote(
    Track track,
    _Downloaded downloaded, {
    required _CacheOperation operation,
    bool preloaded = false,
    Set<String> protectKeys = const <String>{},
    bool Function()? isStillWanted,
    bool Function()? mayMakeRoom,
  }) async {
    final String key = _keyForTrack(track);
    // The user removed or cleared this download while its bytes were still in
    // flight: honour that and commit nothing — no file write, no metadata, no
    // status — so a late fetch can't resurrect it or leave a stray file.
    // The mark stays for the request's own cleanup, which settles the status.
    // Asked again after every await below, since the removal isn't serialized
    // with this commit and can land in any of them.
    if (_canceledOrOrphaned(operation, track, preloaded: preloaded)) return;
    if (preloaded) {
      // The session that asked for these bytes is gone (sign-out, a different
      // server or account, or the pre-cache driver was disposed). They were
      // fetched with that session's credentials, so they must not land under a
      // key the new session would read.
      if (!_passes(isStillWanted)) return;
      final CachedTrack? existing = _downloads[key];
      // A user download for the same track raced this preload (commits are
      // serialized, so by now the winner is known). Don't clobber or duplicate
      // a real download with a preloaded copy — let the user's copy stand.
      if (_inFlight.containsKey(key) ||
          (existing != null && !existing.preloaded)) {
        return;
      }
    }
    final int incoming = downloaded.draft.length;
    final int maxBytes = await _preferences.maxCacheBytes();
    // Asked again after every await below: a sign-out can land in any of them.
    if (_canceledOrOrphaned(operation, track, preloaded: preloaded) ||
        (preloaded && !_passes(isStillWanted))) {
      return;
    }
    final EvictionPlan plan = _policy.plan(
      // Copies set aside for another server take up room on disk too, and are
      // given up like any other copy when it runs out.
      cached: _allCopies,
      incomingBytes: incoming,
      maxBytes: maxBytes,
      protectKey: _protectKey(),
      protectKeys: protectKeys,
      // A pre-cache may only displace other pre-caches: automatic caching
      // never removes something the user chose to download.
      onlyPreloaded: preloaded,
      // Only a copy in use is written over by this one. A copy of the same id
      // kept for another server stays next to it, so it still counts.
      incomingKey: _downloads.containsKey(key) ? key : null,
    );

    if (!plan.fits) {
      if (preloaded) return;
      _set(key, DownloadStatus.notDownloaded);
      throw const CacheStorageException();
    }
    bool evictedAStatus = false;
    bool evictedAny = false;
    for (final CachedTrack victim in plan.evict) {
      // A pre-cache whose queue has moved on (or whose session is gone) may
      // still keep its copy, but only in free space: what it would evict may
      // be what the new queue needs. Asked before every eviction, since either
      // can change while the previous one is being deleted. A cancelled
      // download stops making room too: nothing else is given up for it.
      if (_canceledOrOrphaned(operation, track, preloaded: preloaded) ||
          (preloaded && !(_passes(mayMakeRoom) && _passes(isStillWanted)))) {
        if (evictedAny) {
          await _save();
          if (evictedAStatus) _emitStatus();
          _emitCache();
        }
        return;
      }
      await _deleteManagedFile(victim);
      if (_forgetDeleted(victim)) evictedAStatus = true;
      evictedAny = true;
    }
    // Room made for a queue that has moved on since goes to the new one, not
    // to this copy.
    if (preloaded && evictedAny && !_passes(mayMakeRoom)) {
      await _save();
      _emitCache();
      return;
    }

    final String fileName = await downloaded.draft.publish(
      extension: downloaded.fileExtension,
    );
    if (_canceledOrOrphaned(operation, track, preloaded: preloaded) ||
        (preloaded && !_passes(isStillWanted))) {
      // Removed or cleared, or the session changed, while the bytes were being
      // written: take the file back out instead of publishing it, and persist
      // the evictions already made so the metadata matches what is on disk.
      await _files.delete(fileName);
      if (evictedAny) {
        await _save();
        if (evictedAStatus) _emitStatus();
        _emitCache();
      }
      return;
    }
    final DateTime now = _now();
    final CachedTrack? replaced = _downloads[key];
    _downloads[key] = CachedTrack(
      trackId: track.id,
      fileName: fileName,
      sourceType: _sourceTypeOf(track),
      sizeBytes: incoming,
      cachedAt: now,
      // A preload hasn't been played yet, so it has no access time — which also
      // keeps it ahead of played tracks of its own kind in eviction order.
      lastAccessedAt: preloaded ? null : now,
      preloaded: preloaded,
      origin: operation.origin,
    );
    try {
      await _saveOrThrow();
    } catch (_) {
      // The record couldn't be written (the disk is full). Kept, the copy
      // would look downloaded until the next launch, which removes a file no
      // record names (#747): it goes now instead, and the download fails the
      // way one with no room does (#786). A copy this one didn't write over
      // stays where it was.
      if (replaced != null && replaced.fileName != fileName) {
        _downloads[key] = replaced;
      } else {
        _downloads.remove(key);
      }
      await _files.delete(fileName);
      if (evictedAStatus) _emitStatus();
      _emitCache();
      if (preloaded) return;
      _set(key, DownloadStatus.notDownloaded);
      throw const CacheStorageException(_recordNotSavedMessage);
    }
    if (!preloaded) {
      _statuses[key] = DownloadStatus.downloaded;
    }
    // A preload changes only cache usage; a user download (or an eviction that
    // dropped a download) also changes download status.
    if (!preloaded || evictedAStatus) _emitStatus();
    _emitCache();
  }

  @override
  Future<void> prefetch(
    Track track, {
    Iterable<Track> keep = const <Track>[],
    bool Function()? isStillWanted,
    bool Function()? mayMakeRoom,
  }) async {
    try {
      await _ensureLoaded();
    } catch (_) {
      // The cache records couldn't be read, so nothing can be warmed now,
      // and a pre-cache never throws. The next request reads them again.
      return;
    }
    // Only remote tracks have bytes to fetch; local ones are already on disk.
    if (!_downloader.isRemote(track)) return;
    final String key = _keyForTrack(track);
    // Already cached (download or earlier preload), or a user download already
    // has it in flight — skip rather than fetch the same bytes twice.
    if (_downloads.containsKey(key)) return;
    if (_inFlight.containsKey(key)) return;
    if (_statuses[key] == DownloadStatus.downloading) return;
    // Reserve synchronously, before any await, so a second concurrent prefetch
    // of the same track bails here instead of fetching the same bytes twice.
    if (_preloading.containsKey(key)) return;
    final _CacheOperation operation =
        _CacheOperation(origin: _serverOf(_sourceTypeOf(track) ?? ''));
    _preloading[key] = operation;
    try {
      // Preload is best-effort and network-heavy, so it honours the mobile-data
      // policy and simply skips (rather than queueing) when it can't run now.
      if (!await _allowedToDownloadNow()) return;
      final Set<String> protectKeys = <String>{
        for (final Track kept in keep) _keyForTrack(kept),
      };
      // Respect the cache limit *before* spending data: if the only way to fit
      // would be evicting a user download, a pinned track, or what is playing
      // or about to play, a best-effort preload can never fit, so skip the
      // fetch rather than pull bytes we'd immediately discard.
      final int room =
          _precacheRoom(await _preferences.maxCacheBytes(), protectKeys);
      if (room <= 0) return;
      if (operation.canceled || !_passes(isStillWanted)) return;
      // Its size isn't known until the server says so, and other tracks'
      // sizes say little about it. So once it's clear this track can't fit,
      // the download stops there instead of pulling the rest just to throw it
      // away. The exact fit is still decided at commit, where the room may
      // have changed.
      final _Downloaded downloaded = await _download(
        track,
        operation,
        refuseOver: room,
        // Its bytes would be thrown away at commit once the session that asked
        // for them is gone, so they stop arriving then too. A queue that has
        // only moved on still keeps the copy if it fits in free space.
        stillWanted: () =>
            !_canceledOrOrphaned(operation, track, preloaded: true) &&
            _passes(isStillWanted),
      );
      try {
        // Share the one commit lock so a preload write can't race a user
        // download's and overshoot the limit.
        await _commit(() => _cacheRemote(
              track,
              downloaded,
              operation: operation,
              preloaded: true,
              protectKeys: protectKeys,
              isStillWanted: isStillWanted,
              mayMakeRoom: mayMakeRoom,
            ));
      } finally {
        await downloaded.draft.discard();
      }
    } catch (_) {
      // Best-effort: a failed preload caches nothing and changes no status; the
      // track still streams normally when it's reached.
    } finally {
      if (identical(_preloading[key], operation)) _preloading.remove(key);
    }
  }

  @override
  Future<void> removeDownload(Track track) async {
    await _ensureLoaded();
    final String key = _keyForTrack(track);
    // A download held for the network is cancelled by forgetting it.
    _held.remove(key);
    // If a fetch for this track is still in flight, mark it cancelled so its
    // late commit won't re-add the entry or leave a managed file on disk.
    _inFlight[key]?.canceled = true;
    _preloading[key]?.canceled = true;
    final CachedTrack? existing = _downloads.remove(key);
    await _deleteManagedFile(existing);
    await _save();
    // Also clears a queued/failed/downloading marker, so this doubles as cancel.
    _set(key, DownloadStatus.notDownloaded);
    _emitCache();
  }

  @override
  Future<List<String>> downloadedTrackKeys() async {
    await _ensureLoaded();
    return _statuses.entries
        .where((MapEntry<String, DownloadStatus> e) =>
            e.value == DownloadStatus.downloaded)
        .map((MapEntry<String, DownloadStatus> e) => e.key)
        .toList();
  }

  @override
  Stream<CacheSnapshot> get cacheStream async* {
    await _ensureLoaded();
    yield _cacheSnapshot();
    yield* _cacheChanges.stream;
  }

  @override
  Future<CacheSnapshot> cacheSnapshot() async {
    await _ensureLoaded();
    return _cacheSnapshot();
  }

  @override
  Future<void> setPinned(Track track, bool pinned) async {
    await _ensureLoaded();
    final String key = _keyForTrack(track);
    final CachedTrack? existing = _downloads[key];
    if (existing == null || existing.pinned == pinned) return;
    _downloads[key] = existing.copyWith(pinned: pinned);
    await _save();
    _emitCache();
  }

  @override
  Future<void> notePlayed(Track track) async {
    await _ensureLoaded();
    final String key = _keyForTrack(track);
    final CachedTrack? existing = _downloads[key];
    if (existing == null) return;
    _downloads[key] = existing.copyWith(lastAccessedAt: _now());
    await _save();
    _emitCache();
  }

  @override
  Future<void> clearAll() => _clear(keepPinned: false);

  @override
  Future<void> clearUnpinned() => _clear(keepPinned: true);

  /// Removes offline entries (optionally keeping pinned ones), deleting their
  /// app-managed cache files. On-device markers carry no managed file, so the
  /// user's local source files are never touched.
  Future<void> _clear({required bool keepPinned}) async {
    // Cancel any in-flight fetch first (synchronously, before any await), so a
    // download finishing mid-clear can't write a file and re-add an entry the
    // user just cleared. An in-flight download holds no committed entry yet, so
    // it is unpinned by nature — correct to drop under either clear mode.
    for (final _CacheOperation operation in _inFlight.values) {
      operation.canceled = true;
    }
    for (final _CacheOperation operation in _preloading.values) {
      operation.canceled = true;
    }
    await _ensureLoaded();
    // Those downloads have no entry among the victims below, so their queued
    // or downloading rows are reset here, as a single remove does, rather than
    // only once their fetches end. One requested again meanwhile is no longer
    // cancelled and keeps its row.
    bool resetARow = false;
    for (final MapEntry<String, _CacheOperation> entry in _inFlight.entries) {
      if (entry.value.canceled && _statuses.remove(entry.key) != null) {
        resetARow = true;
      }
    }
    // Downloads held for the network are cancelled too, as Clear all cancels
    // the ones waiting for a slot, so none of them starts after the clear.
    for (final String key in _held.keys) {
      if (!_inFlight.containsKey(key) && _statuses.remove(key) != null) {
        resetARow = true;
      }
    }
    _held.clear();
    // Copies set aside for another server go too: they are on this device.
    final List<CachedTrack> victims =
        _allCopies.where((CachedTrack c) => !(keepPinned && c.pinned)).toList();
    if (victims.isEmpty) {
      if (resetARow) _emitStatus();
      return;
    }
    for (final CachedTrack victim in victims) {
      await _deleteManagedFile(victim);
      _forgetDeleted(victim);
    }
    await _save();
    _emitStatus();
    _emitCache();
  }

  /// Forgets the record of [deleted], whose file was just deleted, wherever
  /// it is kept now, and says whether a download's status went with it.
  ///
  /// Looked up after the delete: a change of server can move a copy between
  /// [_downloads] and [_dormant] meanwhile (Clear all is not in the commit
  /// chain), and a clear or an eviction running alongside can have taken it
  /// out already. Only a record of the deleted file goes. Another copy under
  /// the same key, with its own file, is not this one and stays: another
  /// server's copy of the same id now in use (a pinned one "clear unpinned"
  /// keeps), or one downloaded while the delete ran.
  bool _forgetDeleted(CachedTrack deleted) {
    final String dormantKey = _dormantKey(deleted);
    final CachedTrack? setAside = _dormant[dormantKey];
    if (setAside != null && setAside.fileName == deleted.fileName) {
      _dormant.remove(dormantKey);
      return false;
    }
    final String key = _keyForCached(deleted);
    final CachedTrack? inUse = _downloads[key];
    if (inUse == null || inUse.fileName != deleted.fileName) return false;
    _downloads.remove(key);
    return _statuses.remove(key) != null;
  }

  /// Releases the change streams. Call when the owning provider is disposed.
  Future<void> dispose() async {
    _disposed = true;
    _held.clear();
    // Cancelling a platform event stream waits on the native side to
    // acknowledge, which must never hold up shutdown, so it isn't awaited.
    unawaited(_networkSubscription?.cancel().catchError((Object _) {}));
    _networkSubscription = null;
    unawaited(_originSubscription?.cancel().catchError((Object _) {}));
    _originSubscription = null;
    await _changes.close();
    await _cacheChanges.close();
    await _progressChanges.close();
  }

  /// The room a pre-cache may take: free space under the limit plus the
  /// pre-cached entries it may displace (never a user download, a pinned
  /// track, the playing track, or anything in [protectKeys]). A cheap,
  /// in-memory scan.
  int _precacheRoom(int maxBytes, Set<String> protectKeys) {
    final String? protectKey = _protectKey();
    int used = 0;
    int reclaimable = 0;
    for (final CachedTrack c in _allCopies) {
      used += c.sizeBytes;
      if (CacheEvictionPolicy.isEvictable(
        c,
        protectKey: protectKey,
        protectKeys: protectKeys,
        onlyPreloaded: true,
      )) {
        reclaimable += c.sizeBytes;
      }
    }
    return maxBytes - used + reclaimable;
  }

  /// Asks one of a pre-cache's checks. A missing check passes; one that throws
  /// doesn't, since a failing check can't vouch for the session the bytes
  /// were fetched with or the queue they were fetched for.
  static bool _passes(bool Function()? check) {
    if (check == null) return true;
    try {
      return check();
    } catch (_) {
      return false;
    }
  }

  /// Whether [operation] is cancelled, marking a user download cancelled first
  /// when the account it was asked under has signed out or been replaced.
  ///
  /// Signing out cancels nothing that is already fetching, and those bytes
  /// are the old account's item: on another Plex server (or an Airsonic-style
  /// Subsonic one) the same id names a different song. Saved under the
  /// track's key, they would play for the new account's song with that id
  /// and make it read as downloaded. A pre-cache asks its own `isStillWanted`.
  ///
  /// Either kind is also dropped when the server a bound copy would be
  /// stamped with is no longer the one connected (or was never known): it
  /// would be filed under the wrong server.
  bool _canceledOrOrphaned(
    _CacheOperation operation,
    Track track, {
    required bool preloaded,
  }) {
    if (operation.canceled) return true;
    if (_orphaned(operation, track, preloaded: preloaded)) {
      operation.canceled = true;
    }
    return operation.canceled;
  }

  /// Whether [operation] was asked under an account that has signed out or
  /// been replaced (a user download), or for a server that is no longer the
  /// one connected (a bound copy of either kind).
  bool _orphaned(
    _CacheOperation operation,
    Track track, {
    required bool preloaded,
  }) {
    final String? scheme = _sourceTypeOf(track);
    final bool serverMoved = _binds(scheme) &&
        (operation.origin == null || _serverOf(scheme!) != operation.origin);
    return serverMoved || (!preloaded && _scopeOf(track) != operation.scope);
  }

  /// The account [track]'s provider is signed in with right now. A check that
  /// throws reads as signed out, so it can never vouch for a session.
  String? _scopeOf(Track track) {
    final String? Function(Track track)? scopeOf = _accountScopeOf;
    if (scopeOf == null) return null;
    try {
      return scopeOf(track);
    } catch (_) {
      return null;
    }
  }

  /// The provider-aware cache key of the currently playing track (or `null`),
  /// for the eviction policy to protect exactly that provider's copy. Built from
  /// the live [Track] so a same-id track from another provider isn't shielded.
  String? _protectKey() {
    final Track? playing = _currentlyPlayingTrack?.call();
    return playing == null ? null : _keyForTrack(playing);
  }

  /// The connectivity gate as a simple yes/no, for the best-effort pre-cache
  /// path that just skips when it can't run.
  Future<bool> _allowedToDownloadNow() async =>
      await _networkDecision() == _NetworkDecision.allowed;

  /// Decides whether a download may run right now, and (when it can't) why:
  ///  - Wi-Fi: always allowed.
  ///  - Mobile data: allowed only when the user turned on "Allow mobile data";
  ///    otherwise held for Wi-Fi.
  ///  - Unknown: treated conservatively, like mobile data — allowed only when
  ///    the user allowed mobile data, so an undetermined link is never assumed
  ///    unmetered.
  ///  - Offline: never allowed; the request waits for a connection.
  Future<_NetworkDecision> _networkDecision() async {
    final NetworkStatus status = await _connectivity.currentStatus();
    switch (status) {
      case NetworkStatus.wifi:
        return _NetworkDecision.allowed;
      case NetworkStatus.mobile:
      case NetworkStatus.unknown:
        return await _preferences.allowMobileData()
            ? _NetworkDecision.allowed
            : _NetworkDecision.needsWifi;
      case NetworkStatus.offline:
        return _NetworkDecision.offline;
    }
  }

  /// Deletes the app-managed cache file behind [entry], if any. A `null` entry
  /// or an on-device record (no managed file) is a safe no-op — the file store
  /// is only ever asked to delete files it created in the offline directory.
  Future<void> _deleteManagedFile(CachedTrack? entry) async {
    final String? fileName = entry?.fileName;
    if (fileName != null && fileName.isNotEmpty) {
      await _files.delete(fileName);
    }
  }

  /// Writes the records, best-effort: a write that fails (a full disk) leaves
  /// the last saved set, and the next launch squares that with what is on
  /// disk (a record whose file is gone is dropped, a file no record names is
  /// removed). A copy the user just asked to keep can't be left to that, see
  /// [_saveOrThrow].
  Future<void> _save() async {
    try {
      await _saveOrThrow();
    } catch (_) {
      // Squared with what is on disk at the next launch, as above.
    }
  }

  /// Writes the records, throwing when they couldn't be (#786).
  Future<void> _saveOrThrow() => _store.saveDownloads(_allCopies);

  /// What a user download whose record couldn't be saved tells the user.
  static const String _recordNotSavedMessage =
      "Couldn't save the download. Your device may be out of storage space. "
      'Free up some space, then try again.';

  /// Moves a user download to [status] and remembers it as where that
  /// request stands, so a request that supersedes its cancellation can put
  /// the row back there.
  void _setPhase(String key, _CacheOperation operation, DownloadStatus status) {
    operation.phase = status;
    // A request replaced by a newer one for this track no longer drives its
    // row (see [requestDownload]).
    if (identical(_inFlight[key], operation)) _set(key, status);
  }

  void _set(String key, DownloadStatus status) {
    if (status == DownloadStatus.notDownloaded) {
      _statuses.remove(key);
    } else {
      _statuses[key] = status;
    }
    _emitStatus();
  }

  void _emitStatus() => _changes.add(_snapshot());

  void _emitCache() => _cacheChanges.add(_cacheSnapshot());

  void _emitProgress() => _progressChanges.add(_progressSnapshot());

  /// Runs [action] (a cache commit) only after any in-flight commit finishes,
  /// so the eviction + write step is never interleaved across the otherwise
  /// parallel downloads — which is what keeps the cache limit exact under load.
  /// The chain itself never rejects (errors are routed to [action]'s future),
  /// so one failed commit doesn't stall the ones behind it.
  Future<T> _commit<T>(Future<T> Function() action) {
    final Completer<T> result = Completer<T>();
    _commitChain = _commitChain.then((_) async {
      try {
        result.complete(await action());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  void _reportProgress(Track track, int received, int? total) {
    _progress[_keyForTrack(track)] = DownloadProgress(
      trackId: track.id,
      receivedBytes: received,
      totalBytes: total,
    );
    _emitProgress();
  }

  void _clearProgress(String key) {
    if (_progress.remove(key) != null) _emitProgress();
  }

  /// A copy of the provider-aware status map, keyed by each track's
  /// [CachedTrack.cacheKey] (`scheme\0id`) — the very key a live [Track] produces
  /// via [CachedTrack.cacheKeyForTrack]. Keeping the provider-aware key in the
  /// public projection is what stops two providers' same-id copies (`jellyfin:101`
  /// vs `subsonic:101`) from sharing a status: the per-row status/progress
  /// providers and the downloaded/offline sets all join on this key, so a
  /// download of one copy never lights up the other.
  Map<String, DownloadStatus> _snapshot() =>
      Map<String, DownloadStatus>.of(_statuses);

  Map<String, DownloadProgress> _progressSnapshot() =>
      Map<String, DownloadProgress>.of(_progress);

  CacheSnapshot _cacheSnapshot() {
    // Copies set aside for another server take room on this device, so they
    // count toward what is used; only those in use are listed.
    int used = 0;
    for (final CachedTrack c in _allCopies) {
      used += c.sizeBytes;
    }
    return CacheSnapshot(
      usedBytes: used,
      entries: List<CachedTrack>.unmodifiable(_downloads.values),
    );
  }

  /// The track's non-secret URI scheme (`jellyfin`, `file`, …), never the full
  /// URL — safe to persist as the cached track's source type. Delegates to
  /// [CachedTrack.schemeOf] so the repository's stored key and the key a consumer
  /// computes from a live [Track] via [CachedTrack.cacheKeyForTrack] can never
  /// drift to different scheme logic.
  static String? _sourceTypeOf(Track track) => CachedTrack.schemeOf(track.uri);

  /// The provider-aware cache identity for [track]: its source scheme **plus**
  /// catalog id, so two providers that expose the same local id (e.g. a Plex
  /// ratingKey `101` and a Subsonic id `101`) never share a cache slot, file, or
  /// status. This is the key for every in-memory map below.
  static String _keyForTrack(Track track) =>
      _cacheKey(_sourceTypeOf(track), track.id);

  /// The same identity for a persisted [entry] — its provider-aware
  /// [CachedTrack.cacheKey], built from the same `(sourceType, trackId)` it was
  /// written with, so a reloaded entry maps back to exactly the key its live
  /// track produces and cache state stays stable across restarts.
  static String _keyForCached(CachedTrack entry) => entry.cacheKey;

  /// Composes a credential-free cache key from a source scheme and catalog id —
  /// delegating to the one shared definition [CachedTrack.cacheKeyFor], so the
  /// repository, the metadata records, and the eviction policy can never drift
  /// to different key formats. [_trackIdOfKey] recovers the id for the id-keyed
  /// snapshots the UI reads.
  static String _cacheKey(String? sourceType, String trackId) =>
      CachedTrack.cacheKeyFor(sourceType, trackId);

  /// The catalog id embedded in a [key] from [_cacheKey] — used to project the
  /// internal, provider-aware maps back onto the id-keyed snapshots the UI and
  /// the cross-provider sync layers consume.
  static String _trackIdOfKey(String key) =>
      key.substring(key.indexOf(String.fromCharCode(0)) + 1);

  /// A provider-namespaced base name for [track]'s cache file, so two providers
  /// with the same id write to distinct files (`plex_101`, `jellyfin_101`). The
  /// [OfflineFileStore] sanitizes it further; the resulting file name is what's
  /// persisted, so existing files (named from the bare id) keep resolving.
  ///
  /// A copy bound to the server it came from ([origin]) gets that server's
  /// tag in its name too, so a copy of the same id from another server never
  /// writes over this one's file. The tag is a short hash, never the server's
  /// identity itself.
  static String _fileBaseName(Track track, String? origin) {
    final String base = '${_sourceTypeOf(track) ?? 'local'}_${track.id}';
    if (origin == null) return base;
    final String tag =
        sha256.convert(utf8.encode(origin)).toString().substring(0, 12);
    return '${_sourceTypeOf(track)}_${tag}_${track.id}';
  }
}

/// One download or pre-cache of one track, from its reservation to its
/// cleanup: what a removal or a clear marks, so the mark reaches exactly the
/// operation it was aimed at and is gone with it.
class _CacheOperation {
  _CacheOperation({this.scope, this.origin});

  /// The account the track's provider was signed in with when this was asked
  /// for. A user download is only fetched while that is still the account.
  final String? scope;

  /// The server a copy of a bound provider's track is fetched from (see
  /// `OfflineCopyOrigins`), read when this was asked for: what the copy is
  /// stamped with, and the server that must still be connected when it is
  /// saved. Null for every other provider.
  final String? origin;

  /// Set when the user removed or cleared the track while this operation was
  /// running. It then fetches nothing more and commits nothing. A fresh
  /// [CacheDownloadRepository.requestDownload] for the same track clears it
  /// on a running download (the listener asked again).
  bool canceled = false;

  /// Where a user download stands (`queued`, then `downloading`), or `null`
  /// before it has a row. Unused by a pre-cache, which never has one.
  DownloadStatus? phase;

  /// Set when the fetch stopped because this was cancelled, so its bytes are
  /// gone: a fresh request for the track then starts its own download rather
  /// than taking this one back.
  bool abandoned = false;
}

/// Whether the network policy lets a download run now, and why not when it
/// doesn't: held for Wi-Fi (mobile data not allowed) or waiting for a
/// connection (offline).
enum _NetworkDecision { allowed, needsWifi, offline }

/// Stops a download that can't fit (see [CacheDownloadRepository._download]).
/// A user download surfaces it as a [CacheStorageException]; a pre-cache
/// swallows it like any failed fetch.
class _TooBig implements Exception {
  const _TooBig();
}

/// Stops a download whose bytes would be thrown away anyway (see
/// [CacheDownloadRepository._download]).
class _Abandoned implements Exception {
  const _Abandoned();
}

/// A fetched track waiting in its draft to be committed.
class _Downloaded {
  const _Downloaded(this.draft, this.fileExtension);

  final OfflineFileDraft draft;

  /// The extension the server's content type implies, for the file's name.
  final String? fileExtension;
}
