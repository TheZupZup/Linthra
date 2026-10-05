import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/album.dart';
import '../../../core/models/artist.dart';
import '../../../core/models/playlist.dart';
import '../../../core/models/track.dart';
import '../../../core/repositories/music_library_repository.dart';
import '../../../core/repositories/reconciling_catalog_writer.dart';
import '../../../core/repositories/remote_catalog_owner_store.dart';
import '../../../core/repositories/remote_sync_result.dart';
import '../../../core/repositories/subsonic_auto_sync_store.dart';
import '../../../core/sources/subsonic/subsonic_account_fingerprint.dart';
import '../../../core/sources/subsonic/subsonic_catalog_walk.dart';
import '../../../core/sources/subsonic/subsonic_exception.dart';
import '../../../core/sources/subsonic/subsonic_music_source.dart';
import '../../../core/sources/subsonic/subsonic_track_mapper.dart';
import '../../../data/repositories/favorites_repository_provider.dart';
import '../../../data/repositories/music_library_repository_provider.dart';
import '../../../data/repositories/playlist_repository_provider.dart';
import '../../../data/repositories/remote_catalog_owner_store_provider.dart';
import '../../../data/repositories/subsonic_auto_sync_store_provider.dart';
import '../../../data/repositories/subsonic_sync_pending_store_provider.dart';
import '../../library/library_controller.dart';
import 'subsonic_settings_controller.dart';
import 'subsonic_sync_state.dart';

/// Drives the "Sync Navidrome library" action.
///
/// Reads the signed-in [SubsonicMusicSource] (via [subsonicMusicSourceProvider])
/// to fetch the catalog, then hands the results to the `MusicLibraryRepository`
/// under the stable `subsonic` source id — the same upsert path local scanning
/// and Jellyfin use. The Library screen reads from that repository, so a refresh
/// after the upsert makes the synced tracks appear. It then imports Navidrome
/// **playlists** and adopts server **favourites** best-effort (mirroring the
/// Jellyfin sync), so a failure there never aborts a successful track sync.
///
/// Onboarding: a fresh Subsonic/Navidrome connection triggers [autoSyncIfNeeded]
/// once, so the library populates on its own without the user discovering the
/// manual "Sync Navidrome library" button. It runs the exact same path as the
/// manual [sync] and is gated by a persisted per-account fingerprint, so it
/// fires for a new server/account but not on a reconnect, a rebuild, a reopened
/// Settings screen, or an app restart of an already-synced account — mirroring
/// the Jellyfin onboarding. The manual [sync] is always available.
///
/// Large libraries (issue #680): a Navidrome library of ~80k tracks takes
/// thousands of requests to read, long enough for Android to freeze or kill the
/// app partway. So the sync never holds the library back until the end:
///
///  - the source walks it in batches of [syncBatchSize] tracks, and each batch
///    is **upserted** as soon as it arrives (nothing is deleted up front), so
///    whatever was read survives an interruption, and an interrupted re-sync
///    leaves the previous catalog in place;
///  - rows the walk did not see are pruned only after a walk that is provably
///    complete ([SubsonicCatalogWalk.isComplete]); a failed, stopped, truncated
///    or doubtful walk prunes nothing;
///  - an unfinished sync is recorded in [SubsonicSyncPendingStore] and
///    [resumeIncompleteSync] runs it again on launch/resume for the same
///    account. Re-running is safe: upserts and the prune are idempotent;
///  - every batch first checks the signed-in account is still the one the sync
///    started for, so signing out or switching account stops further writes.
///
/// Security: the source mints any authenticated stream/download URL lazily at
/// use time, so nothing persisted here carries a credential. This controller
/// never logs the session, and surfaces only friendly, secret-free messages.
class SubsonicSyncController extends Notifier<SubsonicSyncState> {
  /// Guards against overlapping syncs (an auto-sync racing a manual tap). Set
  /// synchronously before any await so a second concurrent call simply bails,
  /// satisfying "never run two syncs at once" without cancelling the first.
  ///
  /// Riverpod keeps this notifier instance across `ref.invalidate` (sign-out
  /// does that), so the flag can outlive the account it was set for; see
  /// [_rerunQueued].
  bool _syncing = false;

  /// The account (fingerprint) the running sync belongs to.
  String? _runningAccount;

  /// Set when a sync is requested for a *different* account while one is still
  /// running (sign out, then straight into another account). The old walk stops
  /// at its next batch; this makes the new account's sync run right after it
  /// instead of being dropped.
  bool _rerunQueued = false;
  String? _rerunRecordFingerprint;

  /// Set when [resumeIncompleteSync] lands while a sync is already running
  /// (Android resumed the app with the frozen sync's request still in
  /// flight). If that sync then fails in a way worth retrying, it runs once
  /// more straight away instead of waiting for the next return to the app.
  bool _resumeRequested = false;

  /// The catalog write most recently handed out; the next one waits for it
  /// (see [_writeInTurn]).
  ///
  /// Like [_syncing], it lives on the notifier, which Riverpod keeps across
  /// `ref.invalidate`: a sign-in's [_adoptCatalog] still takes its turn behind
  /// a batch that the previous account's walk had already started writing.
  Future<void> _lastWrite = Future<void>.value();

  /// Tracks per batch. Each batch costs a transaction plus a pass over the
  /// whole "recently added" record (the Recording repository loads and saves
  /// it per write), so small batches make a big library's sync quadratic: at
  /// 80k tracks, 500-track batches measured ~20 s of bookkeeping against
  /// ~7 s at 2000. An interruption still loses at most one batch of reading
  /// (a couple of hundred albums).
  static const int syncBatchSize = 2000;

  @override
  SubsonicSyncState build() => const SubsonicSyncState();

  /// The manual "Sync Navidrome library" action. Walks the library's tracks
  /// into the local catalog, then refreshes Navidrome playlists and favourites.
  /// Reflects loading/success/error through [state]; never throws.
  Future<void> sync() => _runSync();

  /// Runs the **first** automatic sync for a freshly connected server/account.
  ///
  /// Idempotent by account: if this exact server+user has already been
  /// auto-synced before, it doesn't sync the library, so a reconnect, a
  /// provider rebuild, a reopened Settings screen, or an app restart never
  /// re-pulls the whole library on its own. It only refreshes the account's
  /// playlists and favourites, which signing out cleared. Changing the server
  /// URL or signing in as a different user is a new account, and syncs again.
  /// The manual [sync] stays available for an on-demand refresh. Never throws.
  ///
  /// It runs on every sign-in, so it is also where the library stops showing
  /// another account's tracks: signing out keeps them, and they go here,
  /// before this account's walk, which may write nothing (#741).
  Future<void> autoSyncIfNeeded() async {
    final SubsonicMusicSource? source = ref.read(subsonicMusicSourceProvider);
    if (source == null) {
      // Not connected (shouldn't happen right after a sign-in) — nothing to do.
      return;
    }
    final String fingerprint = subsonicAccountFingerprint(source.session);
    final SubsonicAutoSyncStore store = ref.read(subsonicAutoSyncStoreProvider);
    String? lastSynced;
    try {
      lastSynced = await store.read();
    } catch (_) {
      // A storage hiccup must never block onboarding; treat it as "not synced
      // yet" and let the sync proceed — re-running it is safe and idempotent.
      lastSynced = null;
    }
    bool tookOver;
    try {
      tookOver = await _adoptCatalog(source);
    } catch (_) {
      // Couldn't clear another account's tracks: the sync tries again before
      // it walks anything, and reports it if it still can't.
      tookOver = true;
    }
    // With another account's tracks gone, this account's library has to come
    // back even if it was synced once before.
    if (!tookOver && lastSynced == fingerprint) {
      // This account's first sync already happened; don't resync on its own.
      // Its playlists and favourites are another matter: this runs on a
      // sign-in, signing out cleared them, and they are cheap to pull, so they
      // come back now rather than at the next resume or launch.
      await _refreshPlaylists();
      await _refreshFavorites();
      return;
    }
    await _runSync(recordFingerprint: fingerprint);
  }

  /// Re-runs a sync that started for the signed-in account but never finished:
  /// the app was frozen, backgrounded or killed partway, or the server dropped
  /// out. Called on launch and on every resume; a no-op unless such a sync is on
  /// record for *this* account and nothing is running. A marker left by another
  /// account is dropped. Never throws.
  Future<void> resumeIncompleteSync() async {
    if (_syncing) {
      _resumeRequested = true;
      return;
    }
    final String? account = await _pendingForCurrentAccount();
    if (account == null) return;
    // Pass the account along so a resumed *first* sync still marks the
    // account as auto-synced once it lands, like the run it replaces would.
    await _runSync(recordFingerprint: account);
  }

  /// The signed-in account's fingerprint when an unfinished sync is on record
  /// for it, else null. A marker left by another account is dropped.
  Future<String?> _pendingForCurrentAccount() async {
    final SubsonicMusicSource? source = ref.read(subsonicMusicSourceProvider);
    if (source == null) return null;
    final String account = subsonicAccountFingerprint(source.session);
    final String? pending;
    try {
      pending = await ref.read(subsonicSyncPendingStoreProvider).read();
    } catch (_) {
      return null;
    }
    if (pending == null) return null;
    if (pending != account) {
      await _clearPending();
      return null;
    }
    return account;
  }

  /// The shared sync path behind [sync], [autoSyncIfNeeded] and
  /// [resumeIncompleteSync].
  ///
  /// When [recordFingerprint] is non-null (an auto-sync), the account is
  /// remembered **only after the walk ran to its end**, so a sync that failed
  /// (e.g. the server became unreachable right after sign-in) is retried
  /// automatically on the next fresh connection rather than being silently
  /// marked done — and the manual sync stays available meanwhile.
  Future<void> _runSync({String? recordFingerprint}) async {
    if (_syncing) {
      // A sync is already in flight; never stack a second concurrent one.
      _queueIfAnotherAccount(recordFingerprint);
      return;
    }
    _syncing = true;
    try {
      String? record = recordFingerprint;
      do {
        _rerunQueued = false;
        _resumeRequested = false;
        await _syncOnce(recordFingerprint: record);
        record = _rerunRecordFingerprint;
        _rerunRecordFingerprint = null;
        if (!_rerunQueued && _resumeRequested) {
          // A resume came in while this run was going. The marker is still
          // set only if the run failed in a way worth retrying; then retry
          // now, once per resume, rather than until the next resume.
          final String? account = await _pendingForCurrentAccount();
          if (account != null) {
            _rerunQueued = true;
            record = account;
          }
        }
      } while (_rerunQueued);
    } catch (_) {
      // _syncOnce settles its own failures; this only catches one raised while
      // doing so after the container was disposed, keeping "never throws".
    } finally {
      _syncing = false;
      _runningAccount = null;
    }
  }

  /// Called on sign-out, which keeps the library: makes sure the tracks it
  /// keeps are recorded as [account]'s, so the next account to sign in clears
  /// them rather than inheriting them. Only fills in a missing record, which
  /// is what a library synced before #741 has. Never throws.
  Future<void> rememberCatalogOwner(String account) async {
    try {
      final RemoteCatalogOwnerStore owners =
          ref.read(remoteCatalogOwnerStoreProvider);
      if (await owners.read(SubsonicMusicSource.sourceId) == null) {
        await owners.write(SubsonicMusicSource.sourceId, account);
      }
    } catch (_) {
      // Best-effort: without it, the next sign-in falls back to the account
      // that last auto-synced to decide whose tracks these are.
    }
  }

  /// Makes the Subsonic slice of the catalog [source]'s account's before
  /// anything is written for it, and returns whether another account's
  /// tracks had to go (#741).
  ///
  /// Signing out keeps the slice, so the library stays there offline, but its
  /// rows are still the previous account's, and the next account's walk only
  /// prunes them once it completes with something in it. An empty library, or
  /// a first walk that failed or stopped, left them under the new account:
  /// unplayable, or worse, on a server with sequential ids, playing the new
  /// server's song with the same id under the old title.
  ///
  /// Runs in turn with the catalog writes ([_writeInTurn]), so a batch that
  /// the previous account's walk had already started writing lands before the
  /// clear, never after it.
  Future<bool> _adoptCatalog(SubsonicMusicSource source) async {
    final String account = subsonicAccountFingerprint(source.session);
    final bool tookOver = await _writeInTurn(() async {
      // Signed out or switched again meanwhile: the account signed in now
      // adopts the slice on its own.
      if (!_isCurrentAccount(account)) return false;
      final RemoteCatalogOwnerStore owners =
          ref.read(remoteCatalogOwnerStoreProvider);
      final String? owner = await _readQuietly(() => owners.read(source.id));
      if (owner == account) return false;
      // Nothing recorded the owner before #741. Then the account whose first
      // sync landed last is the best guess, and with no guess at all the
      // tracks are taken to be this account's own: nothing is removed.
      final String? previous = owner ??
          await _readQuietly(ref.read(subsonicAutoSyncStoreProvider).read);
      final bool othersTracks = previous != null && previous != account;
      if (othersTracks) {
        await ref.read(musicLibraryRepositoryProvider).upsertCatalog(
          sourceId: source.id,
          tracks: const <Track>[],
          albums: const <Album>[],
          artists: const <Artist>[],
        );
      }
      try {
        await owners.write(source.id, account);
      } catch (_) {
        // Best-effort: the next sync asks again, and clears nothing of this
        // account's that it isn't about to replace.
      }
      return othersTracks;
    });
    if (tookOver) await _refreshLibrary();
    return tookOver;
  }

  /// Runs [write] once the catalog write handed out before it has finished,
  /// so the writes for the Subsonic slice never overlap: [_adoptCatalog]'s
  /// clear can't be overtaken by a batch that was already under way.
  Future<T> _writeInTurn<T>(Future<T> Function() write) {
    final Future<T> turn = _lastWrite.then((_) => write());
    _lastWrite = turn.then<void>((_) {}, onError: (Object _) {});
    return turn;
  }

  /// [read]'s answer, or null when the store couldn't be read.
  static Future<String?> _readQuietly(Future<String?> Function() read) async {
    try {
      return await read();
    } catch (_) {
      return null;
    }
  }

  /// A request that lands while a sync runs is normally covered by that sync.
  /// Only when the signed-in account is no longer the one being synced does it
  /// queue a fresh run (the old walk is about to stop on its own).
  void _queueIfAnotherAccount(String? recordFingerprint) {
    final SubsonicMusicSource? source = ref.read(subsonicMusicSourceProvider);
    if (source == null) return;
    if (subsonicAccountFingerprint(source.session) == _runningAccount) return;
    _rerunQueued = true;
    _rerunRecordFingerprint = recordFingerprint;
  }

  Future<void> _syncOnce({String? recordFingerprint}) async {
    final SubsonicMusicSource? source = ref.read(subsonicMusicSourceProvider);
    if (source == null) {
      state = const SubsonicSyncState.error(
        'Connect to your Subsonic/Navidrome server in Settings before syncing.',
      );
      return;
    }
    final String account = subsonicAccountFingerprint(source.session);
    _runningAccount = account;

    final MusicLibraryRepository repository =
        ref.read(musicLibraryRepositoryProvider);
    // Production always reconciles. A repository without the capability (some
    // test fakes) gets the old single write at the end, and only for a
    // complete walk, since that write replaces the whole slice.
    final ReconcilingCatalogWriter? writer =
        repository is ReconcilingCatalogWriter
            ? repository as ReconcilingCatalogWriter
            : null;
    final List<Track> collected = <Track>[];
    // Every uri this walk saw: what the prune keeps, and the saved count.
    final Set<String> seen = <String>{};
    bool libraryShown = false;
    int saved() => writer == null ? 0 : seen.length;

    state = const SubsonicSyncState.syncing();
    try {
      // Normally done at sign-in already. Here too, so another account's
      // tracks are gone before this walk can fail, stop or find nothing.
      await _adoptCatalog(source);
      await _markPending(account);
      final SubsonicCatalogWalk walk = await source.walkTracks(
        batchSize: syncBatchSize,
        retryDelays: ref.read(subsonicSyncRetryDelaysProvider),
        onBatch: (List<Track> batch) async {
          if (!_isCurrentAccount(account)) return false;
          if (writer != null) {
            // Asked again in turn: an account that signed in while this
            // batch waited has taken the slice over.
            final bool wrote = await _writeInTurn(() async {
              if (!_isCurrentAccount(account)) return false;
              await writer.upsertTracks(sourceId: source.id, tracks: batch);
              return true;
            });
            if (!wrote) return false;
          } else {
            collected.addAll(batch);
          }
          for (final Track track in batch) {
            seen.add(track.uri);
          }
          if (!_isCurrentAccount(account)) return false;
          state = SubsonicSyncState.syncing(savedTrackCount: saved());
          if (writer != null && !libraryShown) {
            // First batch visible right away, instead of an empty library
            // until the whole walk is done.
            libraryShown = true;
            await _refreshLibrary();
          }
          return true;
        },
      );

      if (walk.stopped || !_isCurrentAccount(account)) {
        // Signed out or switched account mid-walk. Leave the catalog as it is
        // and the card idle for whatever runs next; prune nothing.
        state = const SubsonicSyncState();
        return;
      }

      if (walk.isComplete && seen.isNotEmpty) {
        // Proven complete: whatever the walk didn't see is gone from the
        // server. (An empty walk never prunes: a server that suddenly lists
        // nothing is more likely broken than emptied. The slice is this
        // account's, see [_adoptCatalog], so what it keeps is its own.)
        final bool pruned = await _writeInTurn(() async {
          if (!_isCurrentAccount(account)) return false;
          if (writer != null) {
            await writer.removeTracksNotIn(
              sourceId: source.id,
              keepUris: seen,
            );
          } else {
            await repository.upsertCatalog(
              sourceId: source.id,
              tracks: collected,
              albums: const <Album>[],
              artists: const <Artist>[],
            );
          }
          return true;
        });
        if (!pruned) {
          // Signed out or switched account just now; as for a stopped walk.
          state = const SubsonicSyncState();
          return;
        }
      }
      if (seen.isNotEmpty) await _refreshLibrary();
      // The walk ran to its end. A complete one leaves nothing to resume, and
      // a page-capped one would only hit the cap again. One that lost too many
      // albums mid-walk (a server rescan) is worth another pass, though: keep
      // the marker so launch/resume reconciles the stale rows it had to keep.
      if (walk.isComplete || walk.truncated) await _clearPending();

      // Import Navidrome playlists and adopt server favourites best-effort; a
      // failure here is reported calmly but never fails the track sync. Done
      // even for an empty library: the account can still have hearts and
      // playlists.
      final PlaylistSyncResult playlists = await _refreshPlaylists();
      final FavoritesSyncResult favorites = await _refreshFavorites();

      state = SubsonicSyncState.success(
        trackCount: seen.length,
        complete: walk.isComplete,
        playlistCount: playlists.playlistCount,
        favoriteCount: favorites.favoriteCount,
        playlistsFailed: playlists.didFail,
        favoritesFailed: favorites.didFail,
        message: _composeMessage(
          trackCount: seen.length,
          playlists: playlists,
          favorites: favorites,
          empty: seen.isEmpty,
          complete: walk.isComplete,
        ),
      );
      await _recordAutoSynced(recordFingerprint);
    } on SubsonicException catch (error) {
      await _fail(
        account,
        _friendlyMessage(error),
        errorKind: error.kind.name,
        saved: saved(),
        retry: _worthRetrying(error.kind),
      );
    } catch (_) {
      await _fail(
        account,
        'Something went wrong saving your library. Please try again.',
        errorKind: SubsonicSyncState.unexpectedErrorKind,
        saved: saved(),
        retry: true,
      );
    }
  }

  /// Settles a sync that failed partway. Whatever it already saved stays, and
  /// is shown; the unfinished-sync marker stays too when trying again later
  /// could help, so the next launch/resume picks it up.
  Future<void> _fail(
    String account,
    String message, {
    required String errorKind,
    required int saved,
    required bool retry,
  }) async {
    if (!_isCurrentAccount(account)) {
      // The failure belongs to an account that's no longer signed in.
      state = const SubsonicSyncState();
      return;
    }
    if (!retry) await _clearPending();
    final String kept = saved == 1 ? '1 track was' : '$saved tracks were';
    state = SubsonicSyncState.error(
      saved == 0
          ? message
          : retry
              ? '$message $kept saved; Linthra will try again when you come '
                  'back to the app.'
              : '$message $kept saved.',
      errorKind: errorKind,
      savedTrackCount: saved,
    );
    if (saved > 0) {
      try {
        await _refreshLibrary();
      } catch (_) {
        // Best-effort: the saved tracks show on the next library load anyway.
      }
    }
  }

  /// Failures a later attempt can plausibly get past on its own. The rest
  /// (rejected credentials, a wrong or insecure address, ...) need the user to
  /// change something first, so retrying them on every resume would only
  /// repeat the same error.
  static bool _worthRetrying(SubsonicErrorKind kind) =>
      kind == SubsonicErrorKind.notReachable ||
      kind == SubsonicErrorKind.serverError ||
      kind == SubsonicErrorKind.unexpected;

  /// Whether [account] is still the signed-in Subsonic account. False once the
  /// app's container is gone too (shutdown while a walk was waiting on the
  /// network): nothing may be written after that either.
  bool _isCurrentAccount(String account) {
    final SubsonicMusicSource? source;
    try {
      source = ref.read(subsonicMusicSourceProvider);
    } on StateError {
      return false;
    }
    return source != null &&
        subsonicAccountFingerprint(source.session) == account;
  }

  Future<void> _refreshLibrary() =>
      ref.read(libraryControllerProvider.notifier).refresh();

  /// Records that a sync for [account] has started. Best-effort: without the
  /// marker an interrupted sync just isn't resumed automatically.
  Future<void> _markPending(String account) async {
    try {
      await ref.read(subsonicSyncPendingStoreProvider).write(account);
    } catch (_) {
      // Ignore: the manual sync stays available.
    }
  }

  /// Forgets the unfinished-sync marker. Best-effort: a stale marker only
  /// causes one extra (idempotent) sync on the next resume.
  Future<void> _clearPending() async {
    try {
      await ref.read(subsonicSyncPendingStoreProvider).clear();
    } catch (_) {
      // Ignore.
    }
  }

  /// Remembers a completed auto-sync's account [fingerprint], best-effort: a
  /// no-op for a manual sync (null), and a storage hiccup only means the next
  /// fresh connection re-runs the (idempotent) initial sync.
  Future<void> _recordAutoSynced(String? fingerprint) async {
    if (fingerprint == null) return;
    try {
      await ref.read(subsonicAutoSyncStoreProvider).write(fingerprint);
    } catch (_) {
      // Ignore: worst case the next connection auto-syncs again.
    }
  }

  /// Best-effort playlist refresh that never throws out of [sync]: a thrown
  /// error (rather than the repository's own friendly result) is mapped to a
  /// failed outcome so a single bad call can't abort a successful track sync.
  ///
  /// Navidrome's playlists only: this card reports what came from Navidrome,
  /// and another signed-in server answering says nothing about it.
  Future<PlaylistSyncResult> _refreshPlaylists() async {
    try {
      return await ref
          .read(playlistRepositoryProvider)
          .refreshFromRemote(source: PlaylistSource.subsonic);
    } catch (_) {
      return const PlaylistSyncResult.failed();
    }
  }

  /// Best-effort favourites refresh, mirroring [_refreshPlaylists].
  Future<FavoritesSyncResult> _refreshFavorites() async {
    try {
      return await ref
          .read(favoritesRepositoryProvider)
          .refreshFromRemote(providerScheme: SubsonicTrackMapper.uriScheme);
    } catch (_) {
      return const FavoritesSyncResult.failed();
    }
  }

  /// Builds the friendly success line from what actually synced (tracks,
  /// playlists, favourites) plus a calm note for any part that couldn't load, so
  /// a partial outcome reads clearly rather than as a scary failure. Every value
  /// is display-safe; no secret can reach here.
  String _composeMessage({
    required int trackCount,
    required PlaylistSyncResult playlists,
    required FavoritesSyncResult favorites,
    bool empty = false,
    bool complete = true,
  }) {
    final List<String> synced = <String>[];
    if (trackCount > 0) {
      synced.add(trackCount == 1 ? '1 track' : '$trackCount tracks');
    }
    if (playlists.didSync && playlists.playlistCount > 0) {
      final int n = playlists.playlistCount;
      synced.add(n == 1 ? '1 playlist' : '$n playlists');
    }
    if (favorites.didSync && favorites.favoriteCount > 0) {
      final int n = favorites.favoriteCount;
      synced.add(n == 1 ? '1 favorite' : '$n favorites');
    }

    final List<String> failures = <String>[];
    if (playlists.didFail) failures.add('playlists could not be loaded');
    if (favorites.didFail) failures.add('favorites could not be synced');

    final StringBuffer message = StringBuffer();
    if (synced.isEmpty) {
      message.write(empty
          ? 'Your library looks empty — nothing to sync yet.'
          : 'Synced your library.');
    } else {
      message.write('Synced ${_join(synced)}.');
    }
    if (!complete) {
      message.write(" Linthra couldn't confirm it read your whole library, "
          'so nothing was removed this time.');
    }
    if (failures.isNotEmpty) {
      message.write(' Some items could not be synced (${_join(failures)}).');
    }
    return message.toString();
  }

  /// Joins parts as "a", "a and b", or "a, b and c".
  static String _join(List<String> parts) {
    if (parts.length == 1) return parts.first;
    if (parts.length == 2) return '${parts[0]} and ${parts[1]}';
    return '${parts.sublist(0, parts.length - 1).join(', ')} '
        'and ${parts.last}';
  }

  /// Turns a typed Subsonic failure into a friendly, actionable line. Branches
  /// on [SubsonicErrorKind] rather than message text.
  String _friendlyMessage(SubsonicException error) {
    switch (error.kind) {
      case SubsonicErrorKind.notReachable:
        return "Couldn't reach your music server. Check your connection and "
            'that the server is online.';
      case SubsonicErrorKind.unauthorized:
        return 'Your session was rejected. Sign out and sign in again to '
            'refresh it.';
      case SubsonicErrorKind.notSubsonic:
        return "That server didn't respond like Subsonic. Double-check the "
            'server address in Settings.';
      case SubsonicErrorKind.serverError:
        return 'Your music server reported an error. Try again in a moment.';
      // The factory messages for these already carry specific, actionable
      // wording (which scheme to use, the certificate hint, …), so surface them.
      case SubsonicErrorKind.cleartextBlocked:
      case SubsonicErrorKind.insecureConnection:
      case SubsonicErrorKind.invalidUrl:
      case SubsonicErrorKind.streamUnavailable:
      case SubsonicErrorKind.unsupportedResponse:
      case SubsonicErrorKind.unexpected:
        return error.message;
    }
  }
}

final subsonicSyncControllerProvider =
    NotifierProvider<SubsonicSyncController, SubsonicSyncState>(
  SubsonicSyncController.new,
);

/// The waits between attempts when a sync request fails transiently. Its own
/// provider so tests can run the retry path without real delays.
final subsonicSyncRetryDelaysProvider = Provider<List<Duration>>(
  (ref) => SubsonicMusicSource.defaultRetryDelays,
);
