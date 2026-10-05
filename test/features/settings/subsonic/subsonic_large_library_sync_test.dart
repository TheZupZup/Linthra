// Issue #680: a Navidrome library of ~80k tracks never synced, because the
// sync held the whole library until the last of ~8,000 requests and lost all
// of it on any interruption. These tests drive the real controller, the real
// HttpSubsonicClient (against a synthetic Navidrome) and the production
// Recording(Drift) repository stack, and pin down the reconciling behaviour:
// batches are saved as they arrive, stale rows are pruned only after a provably
// complete walk, and an unfinished sync is resumed on the next launch/resume.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/diagnostics/app_diagnostics.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/catalog_track_counter.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';
import 'package:linthra/core/repositories/reconciling_catalog_writer.dart';
import 'package:linthra/core/sources/subsonic/subsonic_account_fingerprint.dart';
import 'package:linthra/data/database/linthra_database.dart';
import 'package:linthra/data/repositories/drift_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_library_added_store.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_auto_sync_store.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_session_store.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_sync_pending_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/recording_music_library_repository.dart';
import 'package:linthra/data/repositories/subsonic_auto_sync_store_provider.dart';
import 'package:linthra/data/repositories/subsonic_session_store_provider.dart';
import 'package:linthra/data/repositories/subsonic_sync_pending_store_provider.dart';
import 'package:linthra/features/settings/diagnostics/diagnostics_collector.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_controller.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_providers.dart';
import 'package:linthra/features/settings/subsonic/subsonic_sync_controller.dart';
import 'package:linthra/features/settings/subsonic/subsonic_sync_state.dart';

import '../../../core/sources/subsonic/synthetic_navidrome.dart';

const String _server = 'https://music.example.com';

/// The session a sign-in to [_server] as [user] produces, for the account
/// fingerprint (which reads only the base URL and username).
SubsonicSession _session(String user) => SubsonicSession(
      baseUrl: _server,
      username: user,
      salt: 'salt',
      token: 'token',
    );

String _account(String user) => subsonicAccountFingerprint(_session(user));

/// The production repository stack, with every reconciling write recorded.
class _SpyRepository
    implements
        MusicLibraryRepository,
        ReconcilingCatalogWriter,
        CatalogTrackCounter {
  _SpyRepository(this._inner);

  final RecordingMusicLibraryRepository _inner;
  final List<List<Track>> upserts = <List<Track>>[];
  int prunes = 0;

  @override
  Future<void> upsertTracks({
    required String sourceId,
    required List<Track> tracks,
  }) {
    upserts.add(List<Track>.of(tracks));
    return _inner.upsertTracks(sourceId: sourceId, tracks: tracks);
  }

  @override
  Future<List<String>> removeTracksNotIn({
    required String sourceId,
    required Set<String> keepUris,
  }) {
    prunes++;
    return _inner.removeTracksNotIn(sourceId: sourceId, keepUris: keepUris);
  }

  @override
  Future<int> countTracks({String? sourceId}) =>
      _inner.countTracks(sourceId: sourceId);

  @override
  Future<List<Track>> getAllTracks() => _inner.getAllTracks();

  @override
  Future<List<Album>> getAllAlbums() => _inner.getAllAlbums();

  @override
  Future<List<Artist>> getAllArtists() => _inner.getAllArtists();

  @override
  Future<Track?> getTrackByUri(String uri) => _inner.getTrackByUri(uri);

  @override
  Future<void> upsertCatalog({
    required String sourceId,
    required List<Track> tracks,
    required List<Album> albums,
    required List<Artist> artists,
  }) =>
      _inner.upsertCatalog(
        sourceId: sourceId,
        tracks: tracks,
        albums: albums,
        artists: artists,
      );

  @override
  Future<void> removeTracks(List<String> trackUris) =>
      _inner.removeTracks(trackUris);
}

/// One app "process": a container over [server], a catalog database that can
/// outlive it (to model a relaunch), and the persisted stores.
class _App {
  _App(
    this.server, {
    LinthraDatabase? db,
    InMemorySubsonicSyncPendingStore? pending,
    InMemorySubsonicAutoSyncStore? autoSync,
    SubsonicSession? restoredSession,
  })  : db = db ?? _openDatabase(),
        pending = pending ?? InMemorySubsonicSyncPendingStore(),
        // Pre-seeded for alice so signing in doesn't start an auto-sync; each
        // test starts the sync it wants explicitly.
        autoSync =
            autoSync ?? InMemorySubsonicAutoSyncStore(_account('alice')) {
    repository = _SpyRepository(RecordingMusicLibraryRepository(
      delegate: DriftMusicLibraryRepository(this.db),
      addedStore: InMemoryLibraryAddedStore(),
    ));
    container = ProviderContainer(overrides: <Override>[
      subsonicClientProvider.overrideWithValue(server.client()),
      subsonicSessionStoreProvider.overrideWithValue(
        InMemorySubsonicSessionStore(initialSession: restoredSession),
      ),
      subsonicAutoSyncStoreProvider.overrideWithValue(this.autoSync),
      subsonicSyncPendingStoreProvider.overrideWithValue(this.pending),
      musicLibraryRepositoryProvider.overrideWithValue(repository),
      subsonicSyncRetryDelaysProvider.overrideWithValue(
        const <Duration>[Duration.zero, Duration.zero],
      ),
    ]);
    addTearDown(container.dispose);
  }

  final SyntheticNavidrome server;
  final LinthraDatabase db;
  final InMemorySubsonicSyncPendingStore pending;
  final InMemorySubsonicAutoSyncStore autoSync;
  late final _SpyRepository repository;
  late final ProviderContainer container;

  SubsonicSyncController get sync =>
      container.read(subsonicSyncControllerProvider.notifier);

  SubsonicSyncState get state => container.read(subsonicSyncControllerProvider);

  Future<void> signIn([String user = 'alice']) async {
    final bool ok = await container
        .read(subsonicSettingsControllerProvider.notifier)
        .signIn(url: 'music.example.com', username: user, password: 'pw');
    expect(ok, isTrue);
  }

  /// A relaunch: the saved session is restored, as bootstrap does.
  Future<void> restore() => container
      .read(subsonicSettingsControllerProvider.notifier)
      .ensureLoaded();

  Future<void> signOut() =>
      container.read(subsonicSettingsControllerProvider.notifier).clear();

  Future<Set<String>> subsonicUris() async => <String>{
        for (final Track t in await repository.getAllTracks())
          if (t.uri.startsWith('subsonic:')) t.uri,
      };

  Future<int> subsonicRows() => repository.countTracks(sourceId: 'subsonic');

  /// Writes rows straight into the catalog, as an earlier sync would have.
  Future<void> seed(String sourceId, List<String> uris) =>
      repository.upsertTracks(sourceId: sourceId, tracks: <Track>[
        for (final String uri in uris) Track(id: uri, title: uri, uri: uri),
      ]);

  Future<SubsonicSyncDiagnostics> diagnostics() => container
      .read(Provider<DiagnosticsCollector>(DiagnosticsCollector.new))
      .collectSubsonicSync();
}

/// Set equality in linear time. `expect(a, b)` on two sets deep-matches every
/// element against every other, which is quadratic and takes minutes at 80k.
void _expectSameSet(Set<String> actual, Set<String> expected) {
  expect(actual.length, expected.length);
  expect(expected.difference(actual), isEmpty);
}

/// A fresh in-memory catalog, closed when the test ends.
LinthraDatabase _openDatabase() {
  final LinthraDatabase db =
      LinthraDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

void main() {
  group('Subsonic sync of a large library (#680)', () {
    test('an 80k-track library syncs in bounded batches, pruned once',
        () async {
      final _App app = _App(SyntheticNavidrome(albums: 8000));
      await app.signIn();

      await app.sync.sync();

      expect(app.state.status, SubsonicSyncStatus.success);
      expect(app.state.trackCount, 80000);
      expect(await app.subsonicRows(), 80000);
      _expectSameSet(await app.subsonicUris(), app.server.urisFor('alice'));
      // Written as it was read: 40 batches, none larger than one batch plus
      // one album, and the one prune after the walk proved complete.
      expect(app.repository.upserts, hasLength(40));
      for (final List<Track> batch in app.repository.upserts) {
        expect(
          batch.length,
          lessThanOrEqualTo(SubsonicSyncController.syncBatchSize + 10),
        );
      }
      expect(app.repository.prunes, 1);
      // The album list read twice (16 full pages + the empty last one, the
      // second time to catch an album that moved during the first, #752), one
      // getAlbum per album, and none of the old unused album/artist passes.
      expect(app.server.albumListCalls, 2 * 17);
      expect(app.server.albumCalls, 8000);
      expect(app.server.calls.containsKey('getArtists'), isFalse);
      // Finished, so nothing is left to resume.
      expect(await app.pending.read(), isNull);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('an interrupted first sync keeps every batch it saved', () async {
      // The network goes away 30% of the way through 80k tracks.
      final _App app =
          _App(SyntheticNavidrome(albums: 8000, failAlbumCallsFrom: 2400));
      await app.signIn();

      await app.sync.sync();

      final SubsonicSyncState state = app.state;
      expect(state.status, SubsonicSyncStatus.error);
      expect(state.errorKind, 'notReachable');
      // Before #680 this was 0: nothing was written until the very end.
      final int rows = await app.subsonicRows();
      expect(rows, 22000); // 11 full batches out of 2,399 albums read.
      expect(state.savedTrackCount, rows);
      expect(state.message, contains('22000 tracks were saved'));
      expect(app.server.urisFor('alice').containsAll(await app.subsonicUris()),
          isTrue);
      expect(app.repository.prunes, 0);
      // Recorded as unfinished, for the next launch/resume.
      expect(await app.pending.read(), _account('alice'));
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('an interrupted re-sync keeps the previous catalog, stale rows too',
        () async {
      final _App first = _App(SyntheticNavidrome(albums: 100));
      await first.signIn();
      await first.sync.sync();
      // A track the server no longer has, from some earlier sync.
      await first.seed('subsonic', <String>['subsonic:gone-1']);
      final Set<String> before = await first.subsonicUris();
      expect(before, hasLength(1001));

      final _App second = _App(
        SyntheticNavidrome(albums: 100, failAlbumCallsFrom: 50),
        db: first.db,
      );
      await second.signIn();
      await second.sync.sync();

      expect(second.state.status, SubsonicSyncStatus.error);
      expect(second.repository.prunes, 0);
      _expectSameSet(await second.subsonicUris(), before);
    });

    test('a complete sync prunes only its own stale rows', () async {
      final _App app = _App(SyntheticNavidrome(albums: 30));
      await app
          .seed('subsonic', <String>['subsonic:gone-1', 'subsonic:gone-2']);
      await app.seed('local', <String>['/music/a.flac', '/music/b.flac']);
      await app.signIn();

      await app.sync.sync();

      expect(app.state.status, SubsonicSyncStatus.success);
      _expectSameSet(await app.subsonicUris(), app.server.urisFor('alice'));
      // Other sources are never touched by the Subsonic prune.
      expect(await app.repository.countTracks(sourceId: 'local'), 2);
    });

    test('a page-capped walk saves what it read but prunes nothing', () async {
      // A server that ignores offset serves the first 500 albums forever, so
      // the walk runs into the page cap.
      final _App app =
          _App(SyntheticNavidrome(albums: 600, ignoreOffset: true));
      await app.seed('subsonic', <String>['subsonic:gone-1']);
      await app.signIn();

      await app.sync.sync();

      expect(app.state.status, SubsonicSyncStatus.incomplete);
      expect(app.state.message, contains('nothing was removed'));
      expect(app.repository.prunes, 0);
      final Set<String> uris = await app.subsonicUris();
      expect(uris, contains('subsonic:gone-1'));
      expect(uris, hasLength(5000 + 1));
      // Running it again would only hit the cap again: nothing to resume.
      expect(await app.pending.read(), isNull);
    });

    test(
        'a walk that lost too many albums keeps the sync to resume, and the '
        'resumed sync prunes', () async {
      // A server rescan: 5 of 40 albums answer "not found" for now.
      final _App first = _App(
        SyntheticNavidrome(albums: 40, missingAlbums: <int>{1, 2, 3, 4, 5}),
      );
      await first.seed('subsonic', <String>['subsonic:gone-1']);
      await first.signIn();
      await first.sync.sync();

      expect(first.state.status, SubsonicSyncStatus.incomplete);
      expect(first.repository.prunes, 0);
      expect(await first.subsonicUris(), contains('subsonic:gone-1'));
      expect(await first.pending.read(), _account('alice'));
      expect(
        (await first.diagnostics()).label,
        'incomplete (350 tracks, stale tracks kept, will retry)',
      );

      // Next launch, the rescan is done: the resumed sync completes and
      // reconciles the stale rows.
      final _App relaunch = _App(
        SyntheticNavidrome(albums: 40),
        db: first.db,
        pending: first.pending,
        restoredSession: _session('alice'),
      );
      await relaunch.restore();
      await relaunch.sync.resumeIncompleteSync();

      expect(relaunch.state.status, SubsonicSyncStatus.success);
      _expectSameSet(
          await relaunch.subsonicUris(), relaunch.server.urisFor('alice'));
      expect(await relaunch.pending.read(), isNull);
    });

    test('an album removed mid-walk (error 70) is skipped and its rows pruned',
        () async {
      final _App first = _App(SyntheticNavidrome(albums: 40));
      await first.signIn();
      await first.sync.sync();

      final _App second = _App(
        SyntheticNavidrome(albums: 40, missingAlbums: <int>{7}),
        db: first.db,
      );
      await second.signIn();
      await second.sync.sync();

      expect(second.state.status, SubsonicSyncStatus.success);
      _expectSameSet(
        await second.subsonicUris(),
        second.server.urisFor('alice', exceptAlbums: <int>{7}),
      );
    });

    test('transient failures are retried and the sync completes', () async {
      final _App app = _App(SyntheticNavidrome(
        albums: 60,
        failingAlbumCalls: <int>{2, 45},
        serverErrorAlbumCalls: <int>{30},
      ));
      await app.signIn();

      await app.sync.sync();

      expect(app.state.status, SubsonicSyncStatus.success);
      _expectSameSet(await app.subsonicUris(), app.server.urisFor('alice'));
    });

    test('persistent rate limiting (HTTP 429) keeps the sync to resume',
        () async {
      final _App app = _App(
        SyntheticNavidrome(albums: 400, rateLimitAlbumCallsFrom: 300),
      );
      await app.signIn();

      await app.sync.sync();

      expect(app.state.status, SubsonicSyncStatus.error);
      expect(app.state.errorKind, 'serverError');
      expect(await app.subsonicRows(), 2000);
      // Rate limiting passes, so the next launch/resume tries again.
      expect(await app.pending.read(), _account('alice'));
      expect(app.state.message, contains('will try again'));
    });

    test('a resume during a sync that then fails retries it right away',
        () async {
      // Android resumes the app while the frozen sync's request is still in
      // flight; that request then fails (with both retries) once it thaws.
      final SyntheticNavidrome server = SyntheticNavidrome(
        albums: 1000,
        stallAtAlbumCall: 500,
        failingAlbumCalls: <int>{500, 501, 502},
      );
      final _App app = _App(server);
      await app.signIn();

      final Future<void> running = app.sync.sync();
      await server.stalled;
      await app.sync.resumeIncompleteSync();
      server.releaseStall();
      await running;

      // The failed run was retried at once, from the start, and finished.
      expect(app.state.status, SubsonicSyncStatus.success);
      _expectSameSet(await app.subsonicUris(), server.urisFor('alice'));
      expect(await app.pending.read(), isNull);
      expect(server.albumCalls, 499 + 3 + 1000);
    });

    test('a resume during a sync that succeeds does not run it again',
        () async {
      final SyntheticNavidrome server =
          SyntheticNavidrome(albums: 1000, stallAtAlbumCall: 500);
      final _App app = _App(server);
      await app.signIn();

      final Future<void> running = app.sync.sync();
      await server.stalled;
      await app.sync.resumeIncompleteSync();
      server.releaseStall();
      await running;

      expect(app.state.status, SubsonicSyncStatus.success);
      expect(server.albumCalls, 1000);
    });

    test('a failure no retry can fix does not leave a sync to resume',
        () async {
      final _App app = _App(
        SyntheticNavidrome(albums: 400, rejectCredentialsFromAlbumCall: 300),
      );
      await app.signIn();

      await app.sync.sync();

      expect(app.state.status, SubsonicSyncStatus.error);
      expect(app.state.errorKind, 'unauthorized');
      // What was read before the rejection is kept...
      expect(await app.subsonicRows(), 2000);
      expect(app.state.message, endsWith('2000 tracks were saved.'));
      expect(app.state.message, isNot(contains('try again')));
      // ...but retrying on every resume would only repeat the rejection.
      expect(await app.pending.read(), isNull);
    });

    test('signing out mid-sync stops further writes and prunes nothing',
        () async {
      final SyntheticNavidrome server =
          SyntheticNavidrome(albums: 1000, stallAtAlbumCall: 500);
      final _App app = _App(server);
      await app.seed('subsonic', <String>['subsonic:gone-1']);
      await app.signIn();

      final Future<void> running = app.sync.sync();
      await server.stalled;
      final int writesBeforeSignOut = app.repository.upserts.length;
      final Set<String> rowsAtSignOut = await app.subsonicUris();

      await app.signOut();
      server.releaseStall();
      await running;

      expect(app.repository.upserts, hasLength(writesBeforeSignOut));
      expect(app.repository.prunes, 0);
      _expectSameSet(await app.subsonicUris(), rowsAtSignOut);
      expect(app.state.status, SubsonicSyncStatus.idle);
      // Sign-out also forgets the unfinished sync.
      expect(await app.pending.read(), isNull);
    });

    test(
        'switching account mid-sync stops the old walk, then syncs the new '
        'account', () async {
      final SyntheticNavidrome server =
          SyntheticNavidrome(albums: 1000, stallAtAlbumCall: 500);
      final _App app = _App(server);
      await app.signIn('alice');

      final Future<void> running = app.sync.sync();
      await server.stalled;
      final int aliceWrites = app.repository.upserts.length;
      expect(aliceWrites, greaterThan(0));

      // Bob's first sign-in asks for an auto-sync while alice's still runs.
      await app.signIn('bob');
      server.releaseStall();
      await running;

      // Nothing of alice's was written after the switch...
      final Iterable<Track> laterWrites =
          app.repository.upserts.skip(aliceWrites).expand((List<Track> b) => b);
      expect(
          laterWrites.where((Track t) => t.uri.contains('-alice-')), isEmpty);
      // ...and bob's queued sync ran to completion, so the catalog is exactly
      // bob's library (alice's partial rows pruned by bob's complete walk).
      expect(app.state.status, SubsonicSyncStatus.success);
      _expectSameSet(await app.subsonicUris(), server.urisFor('bob'));
      expect(await app.autoSync.read(), _account('bob'));
    });

    test(
        'an interrupted sync is resumed on the next launch and clears its '
        'marker', () async {
      final _App killed =
          _App(SyntheticNavidrome(albums: 1000, failAlbumCallsFrom: 500));
      await killed.signIn();
      await killed.sync.sync();
      expect(await killed.subsonicRows(), 4000);
      expect(await killed.pending.read(), _account('alice'));

      // Relaunch: same catalog database and preferences, session restored.
      final _App relaunch = _App(
        SyntheticNavidrome(albums: 1000),
        db: killed.db,
        pending: killed.pending,
        autoSync: InMemorySubsonicAutoSyncStore(),
        restoredSession: _session('alice'),
      );
      await relaunch.restore();
      await relaunch.sync.resumeIncompleteSync();

      expect(relaunch.state.status, SubsonicSyncStatus.success);
      _expectSameSet(
          await relaunch.subsonicUris(), relaunch.server.urisFor('alice'));
      expect(await relaunch.pending.read(), isNull);
      // A resumed first sync marks the account as auto-synced, like the
      // original run would have.
      expect(await relaunch.autoSync.read(), _account('alice'));
    });

    test('resume is a no-op when no sync is unfinished', () async {
      final _App app = _App(
        SyntheticNavidrome(albums: 10),
        restoredSession: _session('alice'),
      );
      await app.restore();

      await app.sync.resumeIncompleteSync();

      expect(app.server.calls, isEmpty);
      expect(app.state.status, SubsonicSyncStatus.idle);
    });

    test("another account's leftover marker is dropped without syncing",
        () async {
      final _App app = _App(
        SyntheticNavidrome(albums: 10),
        pending: InMemorySubsonicSyncPendingStore(_account('bob')),
        restoredSession: _session('alice'),
      );
      await app.restore();

      await app.sync.resumeIncompleteSync();

      expect(app.server.calls, isEmpty);
      expect(await app.pending.read(), isNull);
    });

    test('diagnostics report a failed sync, its saved tracks and the retry',
        () async {
      final _App app =
          _App(SyntheticNavidrome(albums: 1000, failAlbumCallsFrom: 500));
      await app.signIn();
      await app.sync.sync();

      final SubsonicSyncDiagnostics live = await app.diagnostics();
      expect(live.label, 'failed: notReachable (4000 saved, will retry)');
      expect(live.trackCount, 4000);
      expect(live.errorKind, 'notReachable');

      // After the process died, only the marker and the rows remain; the
      // report still says what happened.
      final _App relaunch = _App(
        SyntheticNavidrome(albums: 1000),
        db: app.db,
        pending: app.pending,
        restoredSession: _session('alice'),
      );
      await relaunch.restore();
      final SubsonicSyncDiagnostics later = await relaunch.diagnostics();
      expect(later.label, 'interrupted, will retry');
      expect(later.trackCount, 4000);

      final String report = AppDiagnostics.report(AppDiagnosticsData(
        appVersion: 'test',
        subsonicState: 'connected',
        subsonicSyncState: live.label,
        subsonicTrackCount: live.trackCount,
        libraryTrackCount: 4000,
        lastErrorKind: live.errorKind,
      ));
      expect(report, contains('Subsonic sync: failed: notReachable'));
      expect(report, contains('Subsonic tracks: 4000'));
      expect(report, contains('Library tracks: 4000'));
      expect(report, contains('Last error: notReachable'));
    });
  });

  group('albums that fail or move during a walk', () {
    test(
        'one album that always fails: every other album syncs, nothing is '
        'pruned, and resuming does not walk the library again (#740)',
        () async {
      final SyntheticNavidrome server =
          SyntheticNavidrome(albums: 500, brokenAlbums: <int>{250});
      final _App app = _App(server);
      await app.seed('subsonic', <String>['subsonic:gone-1']);
      await app.signIn();

      await app.sync.sync();

      expect(app.state.status, SubsonicSyncStatus.incomplete);
      expect(app.state.unreadAlbumCount, 1);
      expect(app.state.message, contains("1 album couldn't be read"));
      final Set<String> uris = await app.subsonicUris();
      expect(
        server.urisFor('alice', exceptAlbums: <int>{250}).difference(uris),
        isEmpty,
      );
      // Not a complete walk, so the stale row stays.
      expect(uris, contains('subsonic:gone-1'));
      expect(app.repository.prunes, 0);
      // Nothing left to resume: the next walk would fail it the same way.
      expect(await app.pending.read(), isNull);
      final int calls = server.albumCalls;

      await app.sync.resumeIncompleteSync();
      await app.sync.resumeIncompleteSync();

      expect(server.albumCalls, calls);
      expect(
        (await app.diagnostics()).label,
        'incomplete (4990 tracks, 1 album unread, stale tracks kept)',
      );
    });

    test('a sync again once the album is fixed completes and prunes', () async {
      final _App first = _App(
        SyntheticNavidrome(albums: 100, brokenAlbums: <int>{40}),
      );
      await first.seed('subsonic', <String>['subsonic:gone-1']);
      await first.signIn();
      await first.sync.sync();
      expect(first.state.status, SubsonicSyncStatus.incomplete);

      final _App fixed = _App(SyntheticNavidrome(albums: 100), db: first.db);
      await fixed.signIn();
      await fixed.sync.sync();

      expect(fixed.state.status, SubsonicSyncStatus.success);
      _expectSameSet(await fixed.subsonicUris(), fixed.server.urisFor('alice'));
    });

    test(
        "an album deleted between two list pages doesn't take a live album's "
        'tracks with it (#752)', () async {
      final _App first = _App(SyntheticNavidrome(albums: 1000));
      await first.signIn();
      await first.sync.sync();
      _expectSameSet(await first.subsonicUris(), first.server.urisFor('alice'));

      // Next time, album 10 is deleted on the server right after the first
      // page of the album list is read, so album 500 slides into that page.
      final _App second = _App(
        SyntheticNavidrome(
          albums: 1000,
          afterAlbumListCall: (SyntheticNavidrome server, int call) {
            if (call == 1) server.removeFromListing(10);
          },
        ),
        db: first.db,
      );
      await second.signIn();
      await second.sync.sync();

      expect(second.state.status, SubsonicSyncStatus.success);
      expect(second.repository.prunes, 1);
      // Album 10 is gone, album 500 is not.
      _expectSameSet(
        await second.subsonicUris(),
        second.server.urisFor('alice', exceptAlbums: <int>{10}),
      );
    });
  });

  group('SubsonicSyncState.diagnosticsLabel', () {
    test('describes every status', () {
      expect(
        const SubsonicSyncState().diagnosticsLabel(pendingRetry: false),
        isNull,
      );
      expect(
        const SubsonicSyncState().diagnosticsLabel(pendingRetry: true),
        'interrupted, will retry',
      );
      expect(
        const SubsonicSyncState.syncing(savedTrackCount: 12)
            .diagnosticsLabel(pendingRetry: true),
        'syncing (12 saved)',
      );
      expect(
        const SubsonicSyncState.success(trackCount: 5, message: 'm')
            .diagnosticsLabel(pendingRetry: false),
        'ok (5 tracks)',
      );
      expect(
        const SubsonicSyncState.success(
          trackCount: 5,
          message: 'm',
          complete: false,
        ).diagnosticsLabel(pendingRetry: false),
        'incomplete (5 tracks, stale tracks kept)',
      );
      expect(
        const SubsonicSyncState.success(
          trackCount: 5,
          message: 'm',
          complete: false,
        ).diagnosticsLabel(pendingRetry: true),
        'incomplete (5 tracks, stale tracks kept, will retry)',
      );
      expect(
        const SubsonicSyncState.error('m', errorKind: 'unauthorized')
            .diagnosticsLabel(pendingRetry: false),
        'failed: unauthorized (0 saved)',
      );
      expect(
        const SubsonicSyncState.error('m').diagnosticsLabel(pendingRetry: true),
        'failed: syncFailed (0 saved, will retry)',
      );
    });
  });
}
