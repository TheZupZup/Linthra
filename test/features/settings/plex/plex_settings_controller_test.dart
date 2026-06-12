import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';
import 'package:linthra/core/repositories/plex_session_store.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_exception.dart';
import 'package:linthra/core/sources/plex/plex_music_source.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_plex_session_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/plex_session_store_provider.dart';
import 'package:linthra/features/settings/plex/plex_settings_controller.dart';
import 'package:linthra/features/settings/plex/plex_settings_providers.dart';
import 'package:linthra/features/settings/plex/plex_settings_state.dart';
import 'package:linthra/features/settings/plex/plex_sync_controller.dart';
import 'package:linthra/features/settings/plex/plex_sync_state.dart';

import '../../../core/sources/plex/fake_plex_client.dart';

const String _token = 'super-secret-plex-token';

const PlexSession _session = PlexSession(
  baseUrl: 'https://plex.example.com:32400',
  token: _token,
  machineIdentifier: 'machine-abc',
  serverVersion: '1.40.1',
  clientIdentifier: 'install-1',
  selectedSectionKeys: <String>['5'],
);

const PlexDirectory _musicSection =
    PlexDirectory(key: '5', title: 'Music', type: 'artist');
const PlexDirectory _secondMusicSection =
    PlexDirectory(key: '9', title: 'Vinyl rips', type: 'artist');
const PlexDirectory _movieSection =
    PlexDirectory(key: '1', title: 'Movies', type: 'movie');

/// A [PlexSessionStore] whose operations can be made to throw, to prove a
/// storage failure never crashes or wedges the controller.
class _FlakyPlexSessionStore implements PlexSessionStore {
  _FlakyPlexSessionStore({
    PlexSession? initialSession,
    this.readError,
    this.writeError,
    this.clearError,
  }) : _session = initialSession;

  PlexSession? _session;
  Object? readError;
  Object? writeError;
  Object? clearError;

  @override
  Future<PlexSession?> read() async {
    final Object? error = readError;
    if (error != null) throw error;
    return _session;
  }

  @override
  Future<void> write(PlexSession session) async {
    final Object? error = writeError;
    if (error != null) throw error;
    _session = session;
  }

  @override
  Future<void> clear() async {
    final Object? error = clearError;
    if (error != null) throw error;
    _session = null;
  }
}

/// A [PlexSessionStore] whose read blocks until released, simulating a slow
/// secure-storage read on a real device so user actions can race the startup
/// restore. The read returns what was persisted when it *started* (a stale
/// snapshot), exactly like a disk read would.
class _GatedReadStore implements PlexSessionStore {
  _GatedReadStore(this._session);

  PlexSession? _session;
  final Completer<void> readGate = Completer<void>();

  @override
  Future<PlexSession?> read() async {
    final PlexSession? snapshot = _session;
    await readGate.future;
    return snapshot;
  }

  @override
  Future<void> write(PlexSession session) async {
    _session = session;
  }

  @override
  Future<void> clear() async {
    _session = null;
  }
}

/// Records catalog upserts so the disconnect/connect cleanup paths can be
/// asserted (and made to fail).
class _RecordingRepository implements MusicLibraryRepository {
  _RecordingRepository({this.upsertError});

  final Object? upsertError;

  String? upsertedSourceId;
  List<Track> upsertedTracks = const <Track>[];
  int upsertCount = 0;

  @override
  Future<void> upsertCatalog({
    required String sourceId,
    required List<Track> tracks,
    required List<Album> albums,
    required List<Artist> artists,
  }) async {
    upsertCount++;
    if (upsertError != null) throw upsertError!;
    upsertedSourceId = sourceId;
    upsertedTracks = tracks;
  }

  @override
  Future<List<Track>> getAllTracks() async => upsertedTracks;

  @override
  Future<List<Album>> getAllAlbums() async => const <Album>[];

  @override
  Future<List<Artist>> getAllArtists() async => const <Artist>[];

  @override
  Future<Track?> getTrackById(String id) async => null;

  @override
  Future<void> removeTracks(List<String> trackIds) async {}
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

ProviderContainer _container({
  FakePlexClient? client,
  PlexSessionStore? store,
  MusicLibraryRepository? repository,
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      plexClientProvider.overrideWithValue(
        client ?? FakePlexClient(sections: const [_musicSection]),
      ),
      plexSessionStoreProvider
          .overrideWithValue(store ?? InMemoryPlexSessionStore()),
      if (repository != null)
        musicLibraryRepositoryProvider.overrideWithValue(repository),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('load', () {
    test('starts disconnected when nothing is persisted', () async {
      final container = _container();
      container.read(plexSettingsControllerProvider);
      await _settle();
      expect(
        container.read(plexSettingsControllerProvider).phase,
        PlexConnectionPhase.disconnected,
      );
      expect(container.read(plexMusicSourceProvider), isNull);
    });

    test('ensureLoaded readies the signed-in source with its selection',
        () async {
      final container = _container(
        store: InMemoryPlexSessionStore(initialSession: _session),
      );

      await container
          .read(plexSettingsControllerProvider.notifier)
          .ensureLoaded();

      final state = container.read(plexSettingsControllerProvider);
      expect(state.phase, PlexConnectionPhase.connected);
      expect(state.baseUrl, _session.baseUrl);
      expect(state.serverVersion, '1.40.1');
      expect(state.selectedSectionKeys, <String>['5']);

      final PlexMusicSource? source = container.read(plexMusicSourceProvider);
      expect(source, isNotNull);
      expect(source!.id, 'plex');
      expect(source.session.selectedSectionKeys, <String>['5']);
    });

    test('a storage failure on read stays disconnected (startup never breaks)',
        () async {
      final container = _container(
        store: _FlakyPlexSessionStore(readError: StateError('keystore gone')),
      );

      await container
          .read(plexSettingsControllerProvider.notifier)
          .ensureLoaded();

      final state = container.read(plexSettingsControllerProvider);
      expect(state.phase, PlexConnectionPhase.disconnected);
      // A user who *was* connected shouldn't wonder where the server went:
      // the failure to even read the saved session is said out loud
      // (statically — no token, no raw storage error).
      expect(state.errorMessage, contains("Couldn't restore"));
      expect(container.read(plexMusicSourceProvider), isNull);
    });

    test('the persisted client identifier feeds the announced client identity',
        () async {
      final container = _container(
        store: InMemoryPlexSessionStore(initialSession: _session),
      );
      await container
          .read(plexSettingsControllerProvider.notifier)
          .ensureLoaded();

      expect(
        container.read(plexClientIdentityProvider).clientIdentifier,
        'install-1',
      );
    });

    test('a connect that wins the slow-startup-restore race is kept', () async {
      // Secure-storage reads can be slow on real devices: the user connects
      // to a NEW server while the old session is still being read.
      final store = _GatedReadStore(_session);
      final container = _container(
        client: FakePlexClient(
          identity:
              const PlexServerIdentity(machineIdentifier: 'other-machine'),
          sections: const [_musicSection],
        ),
        store: store,
      );
      final notifier = container.read(plexSettingsControllerProvider.notifier);

      final ok = await notifier.connect(
        url: 'https://new.example.com',
        token: 'new-token',
      );
      expect(ok, isTrue);

      // The stale read lands afterwards — and is discarded.
      store.readGate.complete();
      await _settle();

      final state = container.read(plexSettingsControllerProvider);
      expect(state.baseUrl, 'https://new.example.com');
      expect(notifier.session!.machineIdentifier, 'other-machine');
      expect(notifier.session!.token, 'new-token');
    });

    test('a disconnect during the startup restore is not resurrected',
        () async {
      final store = _GatedReadStore(_session);
      final container = _container(store: store);
      final notifier = container.read(plexSettingsControllerProvider.notifier);

      await notifier.disconnect();

      // The pre-disconnect snapshot lands afterwards — and is discarded:
      // signing out must stay signed out.
      store.readGate.complete();
      await _settle();

      final state = container.read(plexSettingsControllerProvider);
      expect(state.phase, PlexConnectionPhase.disconnected);
      expect(notifier.session, isNull);
      expect(container.read(plexMusicSourceProvider), isNull);
    });
  });

  group('testConnection', () {
    test('reports the reached server on success without persisting', () async {
      final store = InMemoryPlexSessionStore();
      final client = FakePlexClient();
      final container = _container(client: client, store: store);
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await _settle();

      final ok = await notifier.testConnection(
        url: 'plex.example.com',
        token: _token,
      );

      expect(ok, isTrue);
      final state = container.read(plexSettingsControllerProvider);
      expect(state.phase, PlexConnectionPhase.tested);
      expect(state.statusMessage, contains('Plex Media Server'));
      // The bare host was normalized and the token sent on the check.
      expect(client.lastBaseUrl, 'https://plex.example.com');
      expect(client.lastToken, _token);
      // A test never persists anything.
      expect(await store.read(), isNull);
    });

    test('surfaces a friendly, token-free error when the token is rejected',
        () async {
      final container = _container(
        client: FakePlexClient(identityError: PlexException.unauthorized()),
      );
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await _settle();

      final ok = await notifier.testConnection(
        url: 'plex.example.com',
        token: 'wrong-token',
      );

      expect(ok, isFalse);
      final state = container.read(plexSettingsControllerProvider);
      expect(state.phase, PlexConnectionPhase.disconnected);
      expect(state.errorMessage, isNotNull);
      expect(state.errorKind, PlexErrorKind.unauthorized);
      expect(state.errorMessage, isNot(contains('wrong-token')));
    });

    test('rejects an unusable address before any network call', () async {
      final client = FakePlexClient();
      final container = _container(client: client);
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await _settle();

      final ok = await notifier.testConnection(url: 'ftp://x', token: _token);

      expect(ok, isFalse);
      expect(client.identityCount, 0);
      expect(
        container.read(plexSettingsControllerProvider).errorKind,
        PlexErrorKind.invalidUrl,
      );
    });
  });

  group('connect', () {
    test(
        'persists a token-bearing session, stamps the client identifier, '
        'and exposes a real source', () async {
      final store = InMemoryPlexSessionStore();
      final client = FakePlexClient(
        identity: const PlexServerIdentity(
          machineIdentifier: 'machine-abc',
          version: '1.40.1',
        ),
        sections: const [_movieSection, _musicSection],
      );
      final container = _container(client: client, store: store);
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await _settle();
      final String launchIdentifier =
          container.read(plexClientIdentityProvider).clientIdentifier;

      final ok = await notifier.connect(
        url: 'https://plex.example.com:32400',
        token: '  $_token  ',
      );

      expect(ok, isTrue);
      final state = container.read(plexSettingsControllerProvider);
      expect(state.phase, PlexConnectionPhase.connected);
      expect(state.baseUrl, 'https://plex.example.com:32400');
      expect(state.serverVersion, '1.40.1');
      expect(state.errorMessage, isNull);

      // The stored session carries the trimmed token plus the exact client
      // identifier the verify announced, so later launches present the same
      // install to the server.
      final saved = await store.read();
      expect(saved, isNotNull);
      expect(saved!.token, _token);
      expect(saved.machineIdentifier, 'machine-abc');
      expect(saved.clientIdentifier, launchIdentifier);
      expect(
        container.read(plexClientIdentityProvider).clientIdentifier,
        launchIdentifier,
      );

      // The music libraries were fetched for the picker — music only.
      expect(state.sections, const <PlexLibrarySection>[
        PlexLibrarySection(key: '5', title: 'Music'),
      ]);
      // Connected with nothing selected yet: a valid state, not an error.
      expect(state.selectedSectionKeys, isEmpty);

      final PlexMusicSource? source = container.read(plexMusicSourceProvider);
      expect(source, isNotNull);
      expect(source!.session, saved);
    });

    test('does not persist anything on a rejected token', () async {
      final store = InMemoryPlexSessionStore();
      final container = _container(
        client: FakePlexClient(identityError: PlexException.unauthorized()),
        store: store,
      );
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await _settle();

      final ok = await notifier.connect(url: 'plex.example.com', token: 'bad');

      expect(ok, isFalse);
      expect(await store.read(), isNull);
      expect(
        container.read(plexSettingsControllerProvider).phase,
        PlexConnectionPhase.disconnected,
      );
      expect(container.read(plexMusicSourceProvider), isNull);
    });

    test('fails honestly when the session cannot be saved', () async {
      final container = _container(
        store: _FlakyPlexSessionStore(writeError: StateError('disk full')),
      );
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await _settle();

      final ok = await notifier.connect(url: 'plex.example.com', token: _token);

      expect(ok, isFalse);
      final state = container.read(plexSettingsControllerProvider);
      expect(state.phase, PlexConnectionPhase.disconnected);
      expect(state.errorMessage, contains("Couldn't save your Plex session"));
      expect(container.read(plexMusicSourceProvider), isNull);
    });

    test('a section-listing failure keeps the connection and is retryable',
        () async {
      final client = FakePlexClient(
        sectionsError: PlexException.serverError(503),
      );
      final container = _container(client: client);
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await _settle();

      final ok = await notifier.connect(url: 'plex.example.com', token: _token);

      expect(ok, isTrue);
      var state = container.read(plexSettingsControllerProvider);
      expect(state.phase, PlexConnectionPhase.connected);
      expect(state.errorMessage, contains('HTTP 503'));
      expect(state.sections, isEmpty);

      // The retry succeeds once the server recovers.
      client.sectionsError = null;
      client.sections = const [_musicSection];
      await notifier.refreshSections();
      state = container.read(plexSettingsControllerProvider);
      expect(state.errorMessage, isNull);
      expect(state.sections, hasLength(1));
    });

    test(
        'reconnecting to the same server keeps the library selection and '
        'refreshes the catalog against it', () async {
      final store = InMemoryPlexSessionStore(
        // machineIdentifier matches the fake's default identity → same server.
        initialSession: _session.copyWith(
          machineIdentifier: 'fake-machine-id',
          selectedSectionKeys: const <String>['5'],
        ),
      );
      final repo = _RecordingRepository();
      final container = _container(
        client: FakePlexClient(
          sections: const [_musicSection],
          itemsByType: const <PlexMetadataType, List<PlexMetadata>>{
            PlexMetadataType.track: <PlexMetadata>[
              PlexMetadata(ratingKey: '101', type: 'track', title: 'Aurora'),
            ],
          },
        ),
        store: store,
        repository: repo,
      );
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      // The user re-pastes a rotated token for the same server.
      final ok = await notifier.connect(
        url: 'https://plex.example.com:32400',
        token: 'rotated-token',
      );
      await _settle();

      expect(ok, isTrue);
      // The selection survived the reconnect — in state and at rest…
      expect(
        container.read(plexSettingsControllerProvider).selectedSectionKeys,
        <String>['5'],
      );
      final saved = await store.read();
      expect(saved!.selectedSectionKeys, <String>['5']);
      expect(saved.token, 'rotated-token');
      // …and the kept selection was re-synced in the background.
      expect(repo.upsertedSourceId, 'plex');
      expect(repo.upsertedTracks.map((Track t) => t.uri), ['plex:101']);
    });

    test(
        'connecting to a different server starts with a clean selection and '
        'drops the old server\'s rows', () async {
      final store = InMemoryPlexSessionStore(
        // A previous session for another machine, with a selection.
        initialSession: _session, // machineIdentifier: machine-abc
      );
      final repo = _RecordingRepository();
      final container = _container(
        client: FakePlexClient(
          // The new server identifies as a different machine.
          identity: const PlexServerIdentity(
            machineIdentifier: 'other-machine',
          ),
          sections: const [_musicSection],
        ),
        store: store,
        repository: repo,
      );
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      final ok = await notifier.connect(
        url: 'https://new.example.com:32400',
        token: 'other-token',
      );
      await _settle();

      expect(ok, isTrue);
      // The old server's selection doesn't leak onto the new one…
      expect(
        container.read(plexSettingsControllerProvider).selectedSectionKeys,
        isEmpty,
      );
      expect((await store.read())!.selectedSectionKeys, isEmpty);
      // …and the old server's synced rows (unplayable ratingKeys from another
      // machine) were cleared quietly.
      expect(repo.upsertedSourceId, 'plex');
      expect(repo.upsertedTracks, isEmpty);
    });
  });

  group('sections', () {
    test('refreshSections keeps only music libraries', () async {
      final client = FakePlexClient(
        sections: const [_movieSection, _musicSection, _secondMusicSection],
      );
      final container = _container(
        client: client,
        store: InMemoryPlexSessionStore(initialSession: _session),
      );
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      await notifier.refreshSections();

      expect(
        container.read(plexSettingsControllerProvider).sections,
        const <PlexLibrarySection>[
          PlexLibrarySection(key: '5', title: 'Music'),
          PlexLibrarySection(key: '9', title: 'Vinyl rips'),
        ],
      );
    });

    test('loadSectionsIfNeeded fetches once per connection', () async {
      final client = FakePlexClient(sections: const [_musicSection]);
      final container = _container(
        client: client,
        store: InMemoryPlexSessionStore(initialSession: _session),
      );
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      await notifier.loadSectionsIfNeeded();
      expect(
        container.read(plexSettingsControllerProvider).sections,
        hasLength(1),
      );

      // A repeat call must not refetch: were it to hit the server again, this
      // injected failure would surface as an error.
      client.sectionsError = PlexException.serverError(500);
      await notifier.loadSectionsIfNeeded();
      final state = container.read(plexSettingsControllerProvider);
      expect(state.errorMessage, isNull);
      expect(state.sections, hasLength(1));
    });

    test('does nothing when not connected', () async {
      final client = FakePlexClient(sections: const [_musicSection]);
      final container = _container(client: client);
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await _settle();

      await notifier.loadSectionsIfNeeded();
      await notifier.refreshSections();

      expect(container.read(plexSettingsControllerProvider).sections, isEmpty);
    });

    test(
        'sectionsLoaded distinguishes a failed listing from a server with '
        'no music libraries', () async {
      final client = FakePlexClient(
        sectionsError: PlexException.serverError(503),
      );
      final container = _container(
        client: client,
        store: InMemoryPlexSessionStore(initialSession: _session),
      );
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      await notifier.refreshSections();
      var state = container.read(plexSettingsControllerProvider);
      expect(state.sectionsLoaded, isFalse);
      expect(state.errorMessage, isNotNull);

      // Once a listing succeeds — even an empty one — the state says
      // "loaded", so the UI can show "no music libraries" honestly.
      client.sectionsError = null;
      client.sections = const <PlexDirectory>[_movieSection];
      await notifier.refreshSections();
      state = container.read(plexSettingsControllerProvider);
      expect(state.sectionsLoaded, isTrue);
      expect(state.sections, isEmpty);
      expect(state.errorMessage, isNull);
    });

    test('prunes selected libraries the server no longer has', () async {
      final store = InMemoryPlexSessionStore(
        initialSession:
            _session.copyWith(selectedSectionKeys: const <String>['5', '9']),
      );
      // Section 9 was deleted server-side; only 5 remains.
      final container = _container(
        client: FakePlexClient(sections: const [_musicSection]),
        store: store,
      );
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      await notifier.refreshSections();

      // The vanished key is dropped from the state, the live session, and
      // the persisted record — it had no checkbox left to deselect it with.
      expect(
        container.read(plexSettingsControllerProvider).selectedSectionKeys,
        <String>['5'],
      );
      expect(notifier.session!.selectedSectionKeys, <String>['5']);
      expect((await store.read())!.selectedSectionKeys, <String>['5']);
    });

    test('a failed listing never shrinks the selection', () async {
      final container = _container(
        client: FakePlexClient(sectionsError: PlexException.notReachable()),
        store: InMemoryPlexSessionStore(
          initialSession:
              _session.copyWith(selectedSectionKeys: const <String>['5', '9']),
        ),
      );
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      await notifier.refreshSections();

      expect(
        container.read(plexSettingsControllerProvider).selectedSectionKeys,
        <String>['5', '9'],
      );
      expect(notifier.session!.selectedSectionKeys, <String>['5', '9']);
    });

    test('a failed prune persist quietly keeps the old selection', () async {
      final store = _FlakyPlexSessionStore(
        initialSession:
            _session.copyWith(selectedSectionKeys: const <String>['5', '9']),
      );
      final container = _container(
        client: FakePlexClient(sections: const [_musicSection]),
        store: store,
      );
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      store.writeError = StateError('keystore busy');
      await notifier.refreshSections();

      // Not persistable → not applied (state and store stay consistent); the
      // stale key remains until a later refresh can prune it, and no error is
      // raised for this background cleanup.
      final state = container.read(plexSettingsControllerProvider);
      expect(state.selectedSectionKeys, <String>['5', '9']);
      expect(state.errorMessage, isNull);
    });
  });

  group('library selection', () {
    test('toggleSection persists the chosen keys into the session', () async {
      final store = InMemoryPlexSessionStore();
      final container = _container(store: store);
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await _settle();
      await notifier.connect(url: 'plex.example.com', token: _token);

      await notifier.toggleSection('5', included: true);

      var state = container.read(plexSettingsControllerProvider);
      expect(state.selectedSectionKeys, <String>['5']);
      expect((await store.read())!.selectedSectionKeys, <String>['5']);

      // Deselecting persists too — back to "connected, nothing chosen".
      await notifier.toggleSection('5', included: false);
      state = container.read(plexSettingsControllerProvider);
      expect(state.selectedSectionKeys, isEmpty);
      expect((await store.read())!.selectedSectionKeys, isEmpty);
      // Still connected: an empty selection is not a sign-out.
      expect(state.phase, PlexConnectionPhase.connected);
    });

    test('the live source picks up a selection change', () async {
      final container = _container();
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await _settle();
      await notifier.connect(url: 'plex.example.com', token: _token);

      expect(
        container.read(plexMusicSourceProvider)!.session.selectedSectionKeys,
        isEmpty,
      );

      await notifier.setSelectedSections(const <String>['5', '9']);

      expect(
        container.read(plexMusicSourceProvider)!.session.selectedSectionKeys,
        <String>['5', '9'],
      );
    });

    test('a failed save keeps state and store consistent', () async {
      final store = _FlakyPlexSessionStore();
      final container = _container(store: store);
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await _settle();
      await notifier.connect(url: 'plex.example.com', token: _token);

      store.writeError = StateError('disk full');
      await notifier.setSelectedSections(const <String>['5']);

      final state = container.read(plexSettingsControllerProvider);
      expect(state.selectedSectionKeys, isEmpty);
      expect(state.errorMessage, contains("Couldn't save your library"));
      expect((await store.read())!.selectedSectionKeys, isEmpty);
    });

    test('selection is ignored when not connected', () async {
      final store = InMemoryPlexSessionStore();
      final container = _container(store: store);
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await _settle();

      await notifier.setSelectedSections(const <String>['5']);

      expect(
        container.read(plexSettingsControllerProvider).selectedSectionKeys,
        isEmpty,
      );
      expect(await store.read(), isNull);
    });
  });

  group('disconnect', () {
    test('removes only the Plex session and resets to disconnected', () async {
      final store = InMemoryPlexSessionStore(initialSession: _session);
      final container = _container(store: store);
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();
      expect(container.read(plexMusicSourceProvider), isNotNull);

      await notifier.disconnect();

      expect(await store.read(), isNull);
      final state = container.read(plexSettingsControllerProvider);
      expect(state.phase, PlexConnectionPhase.disconnected);
      expect(state.statusMessage, contains('Disconnected'));
      expect(notifier.session, isNull);
      expect(container.read(plexMusicSourceProvider), isNull);
    });

    test(
        'drops the synced Plex rows but leaves other sources untouched, and '
        'resets the sync status', () async {
      final repository = InMemoryMusicLibraryRepository();
      // The catalog holds rows from several sources, as on a real device.
      await repository.upsertCatalog(
        sourceId: 'jellyfin',
        tracks: const <Track>[
          Track(id: 'j1', title: 'Jelly song', uri: 'jellyfin:j1'),
        ],
        albums: const <Album>[],
        artists: const <Artist>[],
      );
      final container = _container(
        client: FakePlexClient(
          sections: const [_musicSection],
          itemsByType: const <PlexMetadataType, List<PlexMetadata>>{
            PlexMetadataType.track: <PlexMetadata>[
              PlexMetadata(ratingKey: '101', type: 'track', title: 'Aurora'),
            ],
          },
        ),
        store: InMemoryPlexSessionStore(initialSession: _session),
        repository: repository,
      );
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();
      await container.read(plexSyncControllerProvider.notifier).sync();
      expect((await repository.getAllTracks()), hasLength(2));
      expect(
        container.read(plexSyncControllerProvider).status,
        PlexSyncStatus.success,
      );

      await notifier.disconnect();

      // Without a session (and with no offline cache in phase 1) the Plex
      // rows are permanently unplayable — they're removed; Jellyfin stays.
      final tracks = await repository.getAllTracks();
      expect(tracks.map((Track t) => t.uri), <String>['jellyfin:j1']);
      expect(
        container.read(plexSettingsControllerProvider).statusMessage,
        contains('synced Plex tracks were removed'),
      );
      // The old "Synced N tracks" status described the ended session.
      expect(
        container.read(plexSyncControllerProvider).status,
        PlexSyncStatus.idle,
      );
    });

    test('a failed catalog cleanup still disconnects, with an honest message',
        () async {
      final container = _container(
        store: InMemoryPlexSessionStore(initialSession: _session),
        repository: _RecordingRepository(upsertError: StateError('db locked')),
      );
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      await notifier.disconnect();

      final state = container.read(plexSettingsControllerProvider);
      // The part that matters for the token — the session — is gone…
      expect(state.phase, PlexConnectionPhase.disconnected);
      expect(notifier.session, isNull);
      // …and the message doesn't claim the rows were removed when they
      // weren't.
      expect(state.statusMessage, contains('Disconnected'));
      expect(
        state.statusMessage,
        isNot(contains('synced Plex tracks were removed')),
      );
    });

    test('a failed clear stays connected and reports it', () async {
      final store = _FlakyPlexSessionStore(
        initialSession: _session,
        clearError: StateError('keystore busy'),
      );
      final container = _container(store: store);
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      await notifier.disconnect();

      final state = container.read(plexSettingsControllerProvider);
      expect(state.phase, PlexConnectionPhase.connected);
      expect(state.errorMessage, contains("Couldn't remove"));
      // The session is still live (and still persisted), so nothing is lost.
      expect(notifier.session, isNotNull);
    });
  });

  group('token safety', () {
    test('the state never carries the token, in any field or message',
        () async {
      final container = _container(
        client: FakePlexClient(sections: const [_musicSection]),
      );
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await _settle();

      await notifier.connect(url: 'plex.example.com', token: _token);
      await notifier.toggleSection('5', included: true);

      final state = container.read(plexSettingsControllerProvider);
      for (final String? text in <String?>[
        state.baseUrl,
        state.serverName,
        state.serverVersion,
        state.statusMessage,
        state.errorMessage,
      ]) {
        expect(text ?? '', isNot(contains(_token)));
      }
    });

    test('failure messages stay token-free on every error path', () async {
      for (final PlexException error in <PlexException>[
        PlexException.unauthorized(),
        PlexException.notReachable(),
        PlexException.notPlex(),
        PlexException.serverError(500),
      ]) {
        final container = _container(
          client: FakePlexClient(identityError: error),
        );
        final notifier =
            container.read(plexSettingsControllerProvider.notifier);
        await _settle();

        await notifier.connect(url: 'plex.example.com', token: _token);

        final state = container.read(plexSettingsControllerProvider);
        expect(state.errorMessage, isNotNull);
        expect(state.errorMessage, isNot(contains(_token)));
      }
    });

    test('the live session keeps redacting the token in toString', () async {
      final container = _container();
      final notifier = container.read(plexSettingsControllerProvider.notifier);
      await _settle();
      await notifier.connect(url: 'plex.example.com', token: _token);

      final String text = notifier.session.toString();
      expect(text, isNot(contains(_token)));
      expect(text, contains('<redacted>'));
    });
  });
}
