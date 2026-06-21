import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/download_progress.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_account_fingerprint.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_auto_sync_store.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_session_store.dart';
import 'package:linthra/data/repositories/jellyfin_auto_sync_store_provider.dart';
import 'package:linthra/data/repositories/jellyfin_session_store_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_state.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_sync_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_sync_state.dart';

import '../../../core/sources/jellyfin/fake_jellyfin_client.dart';
import 'fake_jellyfin_authenticator.dart';

JellyfinSession _sessionFor({
  String baseUrl = 'https://music.example.com',
  String userId = 'user-1',
  String userName = 'alice',
}) =>
    JellyfinSession(
      baseUrl: baseUrl,
      userId: userId,
      accessToken: 'secret-token-value',
      deviceId: 'device-1',
      userName: userName,
      serverName: 'Home',
    );

JellyfinItemDto _audio(String id) => JellyfinItemDto(
      id: id,
      name: 'Track $id',
      album: 'Album',
      artists: const <String>['Artist'],
      runTimeTicks: 1000000,
      indexNumber: 1,
    );

/// A recording [MusicLibraryRepository] that counts upserts and remembers the
/// last one, so a test can prove auto-sync went down the same upsert path as a
/// manual sync (and how many times it ran).
class _RecordingRepository implements MusicLibraryRepository {
  int upsertCount = 0;
  String? lastSourceId;
  List<Track> lastTracks = const <Track>[];

  @override
  Future<void> upsertCatalog({
    required String sourceId,
    required List<Track> tracks,
    required List<Album> albums,
    required List<Artist> artists,
  }) async {
    upsertCount++;
    lastSourceId = sourceId;
    lastTracks = tracks;
  }

  @override
  Future<List<Track>> getAllTracks() async => lastTracks;

  @override
  Future<List<Album>> getAllAlbums() async => const <Album>[];

  @override
  Future<List<Artist>> getAllArtists() async => const <Artist>[];

  @override
  Future<Track?> getTrackByUri(String uri) async => null;

  @override
  Future<void> removeTracks(List<String> trackIds) async {}
}

/// Counts download requests so a test can prove the metadata sync never kicks
/// off a download/cache fetch on its own.
class _SpyDownloadRepository implements DownloadRepository {
  int requestCount = 0;

  @override
  Future<DownloadRequestOutcome> requestDownload(Track track) async {
    requestCount++;
    return DownloadRequestOutcome.started;
  }

  @override
  Stream<Map<String, DownloadStatus>> get statusStream =>
      const Stream<Map<String, DownloadStatus>>.empty();

  @override
  Stream<Map<String, DownloadProgress>> get progressStream =>
      const Stream<Map<String, DownloadProgress>>.empty();

  @override
  Future<DownloadStatus> statusFor(String trackId) async =>
      DownloadStatus.notDownloaded;

  @override
  Future<void> removeDownload(Track track) async {}

  @override
  Future<List<String>> downloadedTrackKeys() async => const <String>[];
}

ProviderContainer _container({
  required FakeJellyfinAuthenticator authenticator,
  required _RecordingRepository repository,
  InMemoryJellyfinAutoSyncStore? autoSyncStore,
  FakeJellyfinClient? client,
  _SpyDownloadRepository? downloads,
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      jellyfinAuthenticatorProvider.overrideWithValue(authenticator),
      jellyfinSessionStoreProvider
          .overrideWithValue(InMemoryJellyfinSessionStore()),
      jellyfinClientProvider.overrideWithValue(
        client ??
            FakeJellyfinClient(
              itemsByKind: <JellyfinItemKind, List<JellyfinItemDto>>{
                JellyfinItemKind.audio: <JellyfinItemDto>[
                  _audio('a'),
                  _audio('b'),
                ],
              },
            ),
      ),
      jellyfinAutoSyncStoreProvider
          .overrideWithValue(autoSyncStore ?? InMemoryJellyfinAutoSyncStore()),
      musicLibraryRepositoryProvider.overrideWithValue(repository),
      if (downloads != null)
        downloadRepositoryProvider.overrideWithValue(downloads),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Lets the controller's async load settle.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

/// Drains the fire-and-forget auto-sync started by sign-in to completion.
Future<void> _drainAutoSync() => pumpEventQueue(times: 50);

Future<bool> _signIn(
  ProviderContainer container, {
  String url = 'music.example.com',
  String username = 'alice',
}) =>
    container.read(jellyfinSettingsControllerProvider.notifier).signIn(
          url: url,
          username: username,
          password: 'pw',
        );

void main() {
  group('Jellyfin auto-sync on connect', () {
    test('a successful sign-in triggers exactly one auto-sync', () async {
      final repo = _RecordingRepository();
      final store = InMemoryJellyfinAutoSyncStore();
      final container = _container(
        authenticator: FakeJellyfinAuthenticator(session: _sessionFor()),
        repository: repo,
        autoSyncStore: store,
      );
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      expect(await _signIn(container), isTrue);
      await _drainAutoSync();

      // One sync ran down the normal upsert path…
      expect(repo.upsertCount, 1);
      expect(repo.lastSourceId, 'jellyfin');
      expect(repo.lastTracks, hasLength(2));
      // …and finished as a success the UI can show.
      expect(
        container.read(jellyfinSyncControllerProvider).status,
        JellyfinSyncStatus.success,
      );
      // The account is now remembered so it won't auto-sync again on its own.
      expect(await store.read(), jellyfinAccountFingerprint(_sessionFor()));
    });

    test('a failed sign-in does not trigger a sync', () async {
      final repo = _RecordingRepository();
      final store = InMemoryJellyfinAutoSyncStore();
      final container = _container(
        authenticator: FakeJellyfinAuthenticator(
          signInError: JellyfinException.unauthorized(),
        ),
        repository: repo,
        autoSyncStore: store,
      );
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      expect(await _signIn(container), isFalse);
      await _drainAutoSync();

      expect(repo.upsertCount, 0);
      expect(
        container.read(jellyfinSyncControllerProvider).status,
        JellyfinSyncStatus.idle,
      );
      expect(await store.read(), isNull);
    });

    test('reconnecting the same account does not auto-sync again', () async {
      final repo = _RecordingRepository();
      // The store already remembers this exact account from a prior run.
      final store = InMemoryJellyfinAutoSyncStore(
          jellyfinAccountFingerprint(_sessionFor()));
      final container = _container(
        authenticator: FakeJellyfinAuthenticator(session: _sessionFor()),
        repository: repo,
        autoSyncStore: store,
      );
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      expect(await _signIn(container), isTrue);
      await _drainAutoSync();

      // Connected, but no unsolicited full re-sync — the manual button remains.
      expect(repo.upsertCount, 0);
      expect(
        container.read(jellyfinSyncControllerProvider).status,
        JellyfinSyncStatus.idle,
      );
    });

    test('changing server/account allows a new initial auto-sync', () async {
      final repo = _RecordingRepository();
      final store = InMemoryJellyfinAutoSyncStore();
      final auth = FakeJellyfinAuthenticator(session: _sessionFor());
      final container = _container(
        authenticator: auth,
        repository: repo,
        autoSyncStore: store,
      );
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      // First account.
      await _signIn(container);
      await _drainAutoSync();
      expect(repo.upsertCount, 1);

      // Sign out, then sign in to a *different* server + user.
      await container.read(jellyfinSettingsControllerProvider.notifier).clear();
      auth.session = _sessionFor(
        baseUrl: 'https://other.example.com',
        userId: 'user-2',
        userName: 'bob',
      );
      await _signIn(container, url: 'other.example.com', username: 'bob');
      await _drainAutoSync();

      // The new account is a fresh connection, so it auto-syncs once more.
      expect(repo.upsertCount, 2);
      expect(
        await store.read(),
        jellyfinAccountFingerprint(
          _sessionFor(baseUrl: 'https://other.example.com', userId: 'user-2'),
        ),
      );
    });

    test('manual sync still works after the auto-sync', () async {
      final repo = _RecordingRepository();
      final container = _container(
        authenticator: FakeJellyfinAuthenticator(session: _sessionFor()),
        repository: repo,
      );
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      await _signIn(container);
      await _drainAutoSync();
      expect(repo.upsertCount, 1);

      // The user can still pull a refresh on demand.
      await container.read(jellyfinSyncControllerProvider.notifier).sync();
      expect(repo.upsertCount, 2);
      expect(
        container.read(jellyfinSyncControllerProvider).status,
        JellyfinSyncStatus.success,
      );
    });

    test('auto-sync uses the same path as a manual sync', () async {
      // Drive the manual sync and the auto-sync over identical inputs and prove
      // they store the same catalog under the same source id.
      final manualRepo = _RecordingRepository();
      final manual = _container(
        authenticator: FakeJellyfinAuthenticator(session: _sessionFor()),
        repository: manualRepo,
        // A store that already knows the account, so sign-in won't auto-sync —
        // leaving the manual call as the only sync.
        autoSyncStore: InMemoryJellyfinAutoSyncStore(
          jellyfinAccountFingerprint(_sessionFor()),
        ),
      );
      manual.read(jellyfinSettingsControllerProvider);
      await _settle();
      await _signIn(manual);
      await _drainAutoSync();
      expect(manualRepo.upsertCount, 0); // confirmed: auto-sync was skipped
      await manual.read(jellyfinSyncControllerProvider.notifier).sync();

      final autoRepo = _RecordingRepository();
      final auto = _container(
        authenticator: FakeJellyfinAuthenticator(session: _sessionFor()),
        repository: autoRepo,
      );
      auto.read(jellyfinSettingsControllerProvider);
      await _settle();
      await _signIn(auto);
      await _drainAutoSync();

      expect(autoRepo.lastSourceId, manualRepo.lastSourceId);
      expect(
        autoRepo.lastTracks.map((t) => t.id),
        manualRepo.lastTracks.map((t) => t.id),
      );
    });

    test('a sync failure after sign-in surfaces a friendly retry state',
        () async {
      final repo = _RecordingRepository();
      final store = InMemoryJellyfinAutoSyncStore();
      final container = _container(
        authenticator: FakeJellyfinAuthenticator(session: _sessionFor()),
        repository: repo,
        autoSyncStore: store,
        // The catalog fetch fails (server unreachable) once connected.
        client:
            FakeJellyfinClient(itemsError: JellyfinException.notReachable()),
      );
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      expect(await _signIn(container), isTrue);
      await _drainAutoSync();

      // Still connected, sync errored with a friendly, secret-free message.
      expect(
        container.read(jellyfinSettingsControllerProvider).phase,
        JellyfinConnectionPhase.connected,
      );
      final syncState = container.read(jellyfinSyncControllerProvider);
      expect(syncState.status, JellyfinSyncStatus.error);
      expect(syncState.message, contains("Couldn't reach"));
      expect(syncState.message, isNot(contains('secret-token-value')));
      // The account is NOT recorded, so the next fresh connection retries.
      expect(await store.read(), isNull);
    });

    test('the auto-sync starts no downloads or cache fetches', () async {
      final repo = _RecordingRepository();
      final downloads = _SpyDownloadRepository();
      final container = _container(
        authenticator: FakeJellyfinAuthenticator(session: _sessionFor()),
        repository: repo,
        downloads: downloads,
      );
      container.read(jellyfinSettingsControllerProvider);
      await _settle();

      await _signIn(container);
      await _drainAutoSync();

      expect(repo.upsertCount, 1); // metadata synced…
      expect(downloads.requestCount, 0); // …but nothing was downloaded.
    });

    test('repeated provider rebuilds do not resync', () async {
      final repo = _RecordingRepository();
      final container = _container(
        authenticator: FakeJellyfinAuthenticator(session: _sessionFor()),
        repository: repo,
      );
      container.read(jellyfinSettingsControllerProvider);
      await _settle();
      await _signIn(container);
      await _drainAutoSync();
      expect(repo.upsertCount, 1);

      // The sync path reads the live source through jellyfinMusicSourceProvider.
      // Rebuilding it repeatedly (as a connection-state change or a widget
      // rebuild would) re-mints the source but, since auto-sync lives in
      // sign-in and not in any build(), must never kick off another sync.
      for (int i = 0; i < 5; i++) {
        container.invalidate(jellyfinMusicSourceProvider);
        container.read(jellyfinMusicSourceProvider);
        container.read(jellyfinSyncControllerProvider);
        await _drainAutoSync();
      }

      expect(repo.upsertCount, 1);
    });
  });
}
