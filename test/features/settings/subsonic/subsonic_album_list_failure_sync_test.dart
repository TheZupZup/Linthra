// A Subsonic re-sync whose first album-list reading fails partway changes
// nothing and stays due.
//
// The walk reads the whole album list before it reads any album. When a later
// page of that list keeps failing (a 503 that outlives the retries), the
// albums listed so far are only part of the library: walked, they would be
// written as if they were all of it, and a prune after them would drop the
// rest. The sync has to fail before it reads an album or writes a row, keep
// the catalog the last full sync left (stale rows too, since nothing proved
// them gone), and keep the unfinished-sync marker so the next launch or
// resume tries again.
//
// Drives the real controller and HttpSubsonicClient against a synthetic
// Navidrome, over the production Recording(Drift) repository stack.
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:linthra/data/repositories/in_memory_remote_catalog_owner_store.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_auto_sync_store.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_session_store.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_sync_pending_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/recording_music_library_repository.dart';
import 'package:linthra/data/repositories/remote_catalog_owner_store_provider.dart';
import 'package:linthra/data/repositories/subsonic_auto_sync_store_provider.dart';
import 'package:linthra/data/repositories/subsonic_session_store_provider.dart';
import 'package:linthra/data/repositories/subsonic_sync_pending_store_provider.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_controller.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_providers.dart';
import 'package:linthra/features/settings/subsonic/subsonic_sync_controller.dart';
import 'package:linthra/features/settings/subsonic/subsonic_sync_state.dart';

import '../../../core/sources/subsonic/synthetic_navidrome.dart';

const SubsonicSession _alice = SubsonicSession(
  baseUrl: 'https://music.example.com',
  username: 'alice',
  salt: 'salt',
  token: 'token',
);

final String _aliceAccount = subsonicAccountFingerprint(_alice);

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

/// One app "process" over [server], signed in as alice from a restored
/// session, with a catalog database and stores that can outlive it.
class _App {
  _App(
    this.server, {
    LinthraDatabase? db,
    InMemorySubsonicSyncPendingStore? pending,
    InMemoryRemoteCatalogOwnerStore? owners,
  })  : db = db ?? _openDatabase(),
        pending = pending ?? InMemorySubsonicSyncPendingStore(),
        owners = owners ?? InMemoryRemoteCatalogOwnerStore() {
    repository = _SpyRepository(RecordingMusicLibraryRepository(
      delegate: DriftMusicLibraryRepository(this.db),
      addedStore: InMemoryLibraryAddedStore(),
    ));
    container = ProviderContainer(overrides: <Override>[
      subsonicClientProvider.overrideWithValue(server.client()),
      subsonicSessionStoreProvider.overrideWithValue(
        InMemorySubsonicSessionStore(initialSession: _alice),
      ),
      subsonicAutoSyncStoreProvider
          .overrideWithValue(InMemorySubsonicAutoSyncStore(_aliceAccount)),
      subsonicSyncPendingStoreProvider.overrideWithValue(this.pending),
      remoteCatalogOwnerStoreProvider.overrideWithValue(this.owners),
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
  final InMemoryRemoteCatalogOwnerStore owners;
  late final _SpyRepository repository;
  late final ProviderContainer container;

  SubsonicSyncController get sync =>
      container.read(subsonicSyncControllerProvider.notifier);

  SubsonicSyncState get state => container.read(subsonicSyncControllerProvider);

  /// A launch: the saved session is restored, as bootstrap does.
  Future<void> restore() => container
      .read(subsonicSettingsControllerProvider.notifier)
      .ensureLoaded();

  Future<Set<String>> subsonicUris() async => <String>{
        for (final Track t in await repository.getAllTracks())
          if (t.uri.startsWith('subsonic:')) t.uri,
      };

  /// Writes rows straight into the catalog, as an earlier sync would have.
  Future<void> seed(List<String> uris) =>
      repository.upsertTracks(sourceId: 'subsonic', tracks: <Track>[
        for (final String uri in uris) Track(id: uri, title: uri, uri: uri),
      ]);
}

/// A fresh in-memory catalog, closed when the test ends.
LinthraDatabase _openDatabase() {
  final LinthraDatabase db =
      LinthraDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

/// Set equality in linear time (`expect` on two large sets is quadratic).
void _expectSameSet(Set<String> actual, Set<String> expected) {
  expect(actual.length, expected.length);
  expect(expected.difference(actual), isEmpty);
}

void main() {
  test(
      'a 503 on the second album-list page fails the re-sync before any album '
      'is read: nothing written, nothing pruned, the sync kept to resume',
      () async {
    // 600 albums: the list is two pages of 500.
    final _App first = _App(SyntheticNavidrome(albums: 600));
    await first.restore();
    await first.sync.sync();
    expect(first.state.status, SubsonicSyncStatus.success);
    expect(await first.pending.read(), isNull);
    // A row the server no longer has: only a prune after a complete walk may
    // take it out.
    await first.seed(<String>['subsonic:gone-1']);
    final Set<String> before = await first.subsonicUris();
    expect(before, hasLength(6000 + 1));

    final _App second = _App(
      SyntheticNavidrome(albums: 600, failAlbumListCallsFrom: 2),
      db: first.db,
      pending: first.pending,
      owners: first.owners,
    );
    await second.restore();
    await second.sync.sync();

    expect(second.state.status, SubsonicSyncStatus.error);
    expect(second.state.errorKind, 'serverError');
    expect(second.state.savedTrackCount, 0);
    // The first page, then the second with its two retries; no album read.
    expect(second.server.albumListCalls, 1 + 3);
    expect(second.server.albumCalls, 0);
    expect(second.repository.upserts, isEmpty);
    expect(second.repository.prunes, 0);
    _expectSameSet(await second.subsonicUris(), before);
    // A server error passes: the next launch/resume runs the sync again.
    expect(await second.pending.read(), _aliceAccount);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
