import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_exception.dart';
import 'package:linthra/data/repositories/in_memory_plex_session_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/plex_session_store_provider.dart';
import 'package:linthra/features/settings/plex/plex_settings_controller.dart';
import 'package:linthra/features/settings/plex/plex_settings_providers.dart';
import 'package:linthra/features/settings/plex/plex_sync_controller.dart';
import 'package:linthra/features/settings/plex/plex_sync_state.dart';

import '../../../core/sources/plex/fake_plex_client.dart';

const String _token = 'super-secret-plex-token';

/// `machineIdentifier` matches [FakePlexClient]'s default identity, so a
/// re-connect in these tests counts as the same server.
const PlexSession _session = PlexSession(
  baseUrl: 'https://plex.example.com:32400',
  token: _token,
  machineIdentifier: 'fake-machine-id',
  clientIdentifier: 'install-1',
  selectedSectionKeys: <String>['5'],
);

const PlexDirectory _musicSection =
    PlexDirectory(key: '5', title: 'Music', type: 'artist');

const PlexMetadata _trackItem = PlexMetadata(
  ratingKey: '101',
  type: 'track',
  title: 'Aurora',
  grandparentTitle: 'The Band',
  parentTitle: 'First Light',
  duration: 215000,
  thumb: '/library/metadata/101/thumb/1',
);
const PlexMetadata _secondTrackItem =
    PlexMetadata(ratingKey: '102', type: 'track', title: 'Dusk');
const PlexMetadata _albumItem = PlexMetadata(
  ratingKey: '201',
  type: 'album',
  title: 'First Light',
  parentTitle: 'The Band',
);
const PlexMetadata _artistItem =
    PlexMetadata(ratingKey: '301', type: 'artist', title: 'The Band');

const Map<PlexMetadataType, List<PlexMetadata>> _libraryItems =
    <PlexMetadataType, List<PlexMetadata>>{
  PlexMetadataType.track: <PlexMetadata>[_trackItem, _secondTrackItem],
  PlexMetadataType.album: <PlexMetadata>[_albumItem],
  PlexMetadataType.artist: <PlexMetadata>[_artistItem],
};

/// Records every upsert so tests can assert exactly what reached the catalog
/// (and can be made to throw, proving storage failures surface friendly).
class _RecordingRepository implements MusicLibraryRepository {
  _RecordingRepository({this.upsertError});

  final Object? upsertError;

  String? upsertedSourceId;
  List<Track> upsertedTracks = const <Track>[];
  List<Album> upsertedAlbums = const <Album>[];
  List<Artist> upsertedArtists = const <Artist>[];
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
    upsertedAlbums = albums;
    upsertedArtists = artists;
  }

  @override
  Future<List<Track>> getAllTracks() async => upsertedTracks;

  @override
  Future<List<Album>> getAllAlbums() async => upsertedAlbums;

  @override
  Future<List<Artist>> getAllArtists() async => upsertedArtists;

  @override
  Future<Track?> getTrackById(String id) async => null;

  @override
  Future<void> removeTracks(List<String> trackIds) async {}
}

/// A [FakePlexClient] whose item listings block until [gate] completes, so a
/// test can hold a sync mid-flight and race it against selection changes.
class _GatedPlexClient extends FakePlexClient {
  _GatedPlexClient({super.sections, super.itemsByType});

  Completer<void> gate = Completer<void>();

  @override
  Future<List<PlexMetadata>> fetchSectionItems({
    required String baseUrl,
    required String token,
    required String sectionKey,
    required PlexMetadataType itemType,
  }) async {
    await gate.future;
    return super.fetchSectionItems(
      baseUrl: baseUrl,
      token: token,
      sectionKey: sectionKey,
      itemType: itemType,
    );
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

ProviderContainer _container({
  FakePlexClient? client,
  PlexSession? session,
  MusicLibraryRepository? repository,
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      plexClientProvider.overrideWithValue(
        client ??
            FakePlexClient(
              sections: const [_musicSection],
              itemsByType: _libraryItems,
            ),
      ),
      plexSessionStoreProvider.overrideWithValue(
        InMemoryPlexSessionStore(initialSession: session),
      ),
      musicLibraryRepositoryProvider
          .overrideWithValue(repository ?? _RecordingRepository()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('sync', () {
    test('reports a friendly error when not connected, touching nothing',
        () async {
      final repo = _RecordingRepository();
      final container = _container(repository: repo);
      await container
          .read(plexSettingsControllerProvider.notifier)
          .ensureLoaded();

      await container.read(plexSyncControllerProvider.notifier).sync();

      final state = container.read(plexSyncControllerProvider);
      expect(state.isError, isTrue);
      expect(state.message, contains('Connect to your Plex server'));
      expect(repo.upsertCount, 0);
    });

    test('pulls the selected libraries into the catalog under the plex id',
        () async {
      final client = FakePlexClient(
        sections: const [_musicSection],
        itemsByType: _libraryItems,
      );
      final repo = _RecordingRepository();
      final container =
          _container(client: client, session: _session, repository: repo);
      await container
          .read(plexSettingsControllerProvider.notifier)
          .ensureLoaded();

      await container.read(plexSyncControllerProvider.notifier).sync();

      expect(repo.upsertedSourceId, 'plex');
      expect(
        repo.upsertedTracks.map((Track t) => t.uri),
        <String>['plex:101', 'plex:102'],
      );
      // What reaches the (persisted) catalog stays credential-free: opaque
      // plex: URIs and plex-thumb: references — never a tokenized URL.
      for (final Track track in repo.upsertedTracks) {
        expect(track.uri, isNot(contains(_token)));
        expect(track.uri, isNot(contains('X-Plex-Token')));
        final Uri? artwork = track.artworkUri;
        if (artwork != null) {
          expect(artwork.scheme, 'plex-thumb');
          expect(artwork.toString(), isNot(contains(_token)));
        }
      }
      expect(repo.upsertedAlbums, hasLength(1));
      expect(repo.upsertedArtists, hasLength(1));
      // Each kind was listed once, scoped to the selected section.
      expect(
        client.itemRequests.map((r) => r.sectionKey).toSet(),
        <String>{'5'},
      );
      expect(client.itemRequests, hasLength(3));

      final state = container.read(plexSyncControllerProvider);
      expect(state.status, PlexSyncStatus.success);
      expect(state.trackCount, 2);
      expect(state.message, contains('Synced 2 tracks'));
    });

    test(
        'selected libraries with no tracks report honestly and still '
        'replace the catalog', () async {
      final repo = _RecordingRepository();
      final container = _container(
        client: FakePlexClient(sections: const [_musicSection]),
        session: _session,
        repository: repo,
      );
      await container
          .read(plexSettingsControllerProvider.notifier)
          .ensureLoaded();

      await container.read(plexSyncControllerProvider.notifier).sync();

      // The empty result is written (a previously wider selection's rows
      // must not linger), and the message says what happened.
      expect(repo.upsertCount, 1);
      expect(repo.upsertedTracks, isEmpty);
      final state = container.read(plexSyncControllerProvider);
      expect(state.status, PlexSyncStatus.success);
      expect(state.trackCount, 0);
      expect(state.message, contains('no tracks yet'));
    });

    test('an empty selection clears previously synced Plex rows', () async {
      final repo = _RecordingRepository();
      final container = _container(
        session: _session.copyWith(selectedSectionKeys: const <String>[]),
        repository: repo,
      );
      await container
          .read(plexSettingsControllerProvider.notifier)
          .ensureLoaded();

      await container.read(plexSyncControllerProvider.notifier).sync();

      expect(repo.upsertCount, 1);
      expect(repo.upsertedSourceId, 'plex');
      expect(repo.upsertedTracks, isEmpty);
      final state = container.read(plexSyncControllerProvider);
      expect(state.status, PlexSyncStatus.success);
      expect(state.message, contains('No music libraries are selected'));
    });
  });

  group('failures', () {
    test('maps each failure kind to a friendly, token-free message', () async {
      final cases = <PlexException, String>{
        PlexException.notReachable(): "Couldn't reach your Plex server",
        PlexException.unauthorized(): 'rejected by the server',
        PlexException.notPlex(): "didn't respond like a Plex Media Server",
        PlexException.serverError(503): 'reported an error',
        PlexException.notFound(): "A selected library wasn't found",
        PlexException.unsupportedResponse(): 'could not use',
      };
      for (final MapEntry<PlexException, String> entry in cases.entries) {
        final repo = _RecordingRepository();
        final container = _container(
          client: FakePlexClient(itemsError: entry.key),
          session: _session,
          repository: repo,
        );
        await container
            .read(plexSettingsControllerProvider.notifier)
            .ensureLoaded();

        await container.read(plexSyncControllerProvider.notifier).sync();

        final state = container.read(plexSyncControllerProvider);
        expect(state.isError, isTrue, reason: '${entry.key.kind}');
        expect(state.message, contains(entry.value),
            reason: '${entry.key.kind}');
        expect(state.message, isNot(contains(_token)),
            reason: '${entry.key.kind}');
        // A failed listing never half-writes the catalog.
        expect(repo.upsertCount, 0, reason: '${entry.key.kind}');
      }
    });

    test('a storage failure surfaces a friendly message', () async {
      final container = _container(
        session: _session,
        repository: _RecordingRepository(upsertError: StateError('disk full')),
      );
      await container
          .read(plexSettingsControllerProvider.notifier)
          .ensureLoaded();

      await container.read(plexSyncControllerProvider.notifier).sync();

      final state = container.read(plexSyncControllerProvider);
      expect(state.isError, isTrue);
      expect(state.message, contains('Something went wrong'));
      expect(state.message, isNot(contains(_token)));
    });
  });

  group('coalescing', () {
    test(
        'a selection change during a sync re-runs once against the newest '
        'selection; a manual tap mid-sync is a no-op', () async {
      final client = _GatedPlexClient(
        sections: const [
          _musicSection,
          PlexDirectory(key: '9', title: 'Vinyl rips', type: 'artist'),
        ],
        itemsByType: _libraryItems,
      );
      final repo = _RecordingRepository();
      final container =
          _container(client: client, session: _session, repository: repo);
      final settings = container.read(plexSettingsControllerProvider.notifier);
      await settings.ensureLoaded();
      final sync = container.read(plexSyncControllerProvider.notifier);

      final Future<void> first = sync.sync();
      await _settle();
      expect(container.read(plexSyncControllerProvider).isSyncing, isTrue);

      // While the walk is held at the gate, the user widens the selection
      // (the settings controller kicks syncAfterSelectionChange itself) and
      // also mashes the sync button — neither may stack extra walks.
      await settings.setSelectedSections(const <String>['5', '9']);
      await sync.sync();

      client.gate.complete();
      await first;
      await _settle();

      // Exactly two passes: the original walk plus one coalesced re-run.
      expect(repo.upsertCount, 2);
      // The re-run walked the NEW selection (both sections, three kinds).
      expect(client.itemRequests, hasLength(3 + 6));
      expect(
        client.itemRequests.skip(3).map((r) => r.sectionKey).toSet(),
        <String>{'5', '9'},
      );
      expect(
        container.read(plexSyncControllerProvider).status,
        PlexSyncStatus.success,
      );
    });
  });

  group('selection-driven sync', () {
    test('toggling a library kicks a background sync that fills the catalog',
        () async {
      final repo = _RecordingRepository();
      final container = _container(repository: repo);
      final settings = container.read(plexSettingsControllerProvider.notifier);
      await settings.ensureLoaded();
      await settings.connect(url: 'plex.example.com', token: _token);
      await _settle();

      await settings.toggleSection('5', included: true);
      await _settle();

      expect(repo.upsertedSourceId, 'plex');
      expect(
        repo.upsertedTracks.map((Track t) => t.uri),
        <String>['plex:101', 'plex:102'],
      );
      final state = container.read(plexSyncControllerProvider);
      expect(state.status, PlexSyncStatus.success);
      expect(state.trackCount, 2);
    });

    test('deselecting the last library prunes its tracks from the catalog',
        () async {
      final repo = _RecordingRepository();
      final container = _container(session: _session, repository: repo);
      final settings = container.read(plexSettingsControllerProvider.notifier);
      await settings.ensureLoaded();
      await container.read(plexSyncControllerProvider.notifier).sync();
      expect(repo.upsertedTracks, isNotEmpty);

      await settings.toggleSection('5', included: false);
      await _settle();

      expect(repo.upsertedTracks, isEmpty);
      expect(
        container.read(plexSyncControllerProvider).message,
        contains('No music libraries are selected'),
      );
    });
  });

  group('token safety', () {
    test('no sync outcome ever carries the token in its message', () async {
      final outcomes = <PlexSyncState>[];

      // Success.
      var container = _container(session: _session);
      await container
          .read(plexSettingsControllerProvider.notifier)
          .ensureLoaded();
      await container.read(plexSyncControllerProvider.notifier).sync();
      outcomes.add(container.read(plexSyncControllerProvider));

      // Every typed failure.
      for (final PlexException error in <PlexException>[
        PlexException.unauthorized(),
        PlexException.notReachable(),
        PlexException.notPlex(),
        PlexException.serverError(500),
        PlexException.notFound(),
      ]) {
        container = _container(
          client: FakePlexClient(itemsError: error),
          session: _session,
        );
        await container
            .read(plexSettingsControllerProvider.notifier)
            .ensureLoaded();
        await container.read(plexSyncControllerProvider.notifier).sync();
        outcomes.add(container.read(plexSyncControllerProvider));
      }

      for (final PlexSyncState state in outcomes) {
        expect(state.message, isNotNull);
        expect(state.message, isNot(contains(_token)));
      }
    });
  });
}
