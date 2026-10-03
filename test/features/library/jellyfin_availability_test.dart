import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/library_grouping.dart';
import 'package:linthra/core/catalog/source_priority.dart';
import 'package:linthra/core/diagnostics/app_diagnostics.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/reachability.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/core/sources/source_availability.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_session_store.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/jellyfin_session_store_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/downloads/download_providers.dart';
import 'package:linthra/features/library/library_browse_providers.dart';
import 'package:linthra/features/library/library_controller.dart';
import 'package:linthra/features/library/source_availability_providers.dart';
import 'package:linthra/features/library/source_preference_controller.dart';
import 'package:linthra/features/library/unified_library_providers.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_availability_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_state.dart';

import '../../core/sources/jellyfin/fake_jellyfin_client.dart';

/// The reporter's setup, reduced to essentials: a Jellyfin server saved at a
/// LAN-only address, plus some on-device music.
const JellyfinSession _session = JellyfinSession(
  baseUrl: 'http://192.168.22.1:8096',
  userId: 'user-1',
  accessToken: 'tok',
  deviceId: 'device-1',
  userName: 'alice',
  serverName: 'Home',
);

Track _jellyfin(String id, String title) => Track(
      id: id,
      title: title,
      uri: 'jellyfin:$id',
      artistName: 'Adele',
      albumName: '25',
      duration: const Duration(minutes: 3),
    );

Track _local(String name, String title) => Track(
      id: name,
      title: title,
      uri: 'file:///music/$name.mp3',
      artistName: 'Portishead',
      albumName: 'Dummy',
      duration: const Duration(minutes: 4),
    );

final List<Track> _jellyfinTracks = <Track>[
  _jellyfin('101', 'Hello'),
  _jellyfin('102', 'Someone Like You'),
];
final List<Track> _localTracks = <Track>[
  _local('glory-box', 'Glory Box'),
  _local('roads', 'Roads'),
];

List<String> _uris(List<Track> tracks) =>
    <String>[for (final Track t in tracks) t.uri];

/// A server whose session check, at one address only, waits until the test
/// answers it: a LAN address that hangs until it times out while the user is
/// away from home, next to a public address that answers at once.
class _HangingAddressClient extends FakeJellyfinClient {
  _HangingAddressClient(this.hangingBaseUrl);

  final String hangingBaseUrl;
  final List<Completer<void>> hanging = <Completer<void>>[];

  @override
  Future<void> verifySession(JellyfinSession session) async {
    if (session.baseUrl == hangingBaseUrl) {
      final Completer<void> answer = Completer<void>();
      hanging.add(answer);
      await answer.future;
    }
    return super.verifySession(session);
  }
}

/// Pins the source preference so unification is deterministic and the async
/// preference load can't race the assertions.
class _FixedPreference extends SourcePreferenceController {
  @override
  SourcePriority build() => const SourcePriority(<String>['jellyfin']);
}

/// A container wired the way the app is, but with the network and the poll timer
/// under the test's control.
///
/// The library repository is seeded exactly as a completed Jellyfin sync plus a
/// local folder scan would leave it, so "what is stored" and "what is shown" can
/// be compared directly.
Future<
    ({
      ProviderContainer container,
      FakeJellyfinClient client,
      InMemoryMusicLibraryRepository repository,
      InMemoryJellyfinSessionStore sessionStore
    })> _boot({
  JellyfinException? verifyError,
  Set<String> offlineKeys = const <String>{},
  FakeJellyfinClient? fakeClient,
}) async {
  final repository = InMemoryMusicLibraryRepository();
  await repository.upsertCatalog(
    sourceId: 'jellyfin',
    tracks: _jellyfinTracks,
    albums: groupAlbums(_jellyfinTracks),
    artists: groupArtists(_jellyfinTracks),
  );
  await repository.upsertCatalog(
    sourceId: 'local',
    tracks: _localTracks,
    albums: groupAlbums(_localTracks),
    artists: groupArtists(_localTracks),
  );
  final sessionStore = InMemoryJellyfinSessionStore(initialSession: _session);
  final client = fakeClient ?? FakeJellyfinClient(verifyError: verifyError);
  final container = ProviderContainer(
    overrides: <Override>[
      musicLibraryRepositoryProvider.overrideWithValue(repository),
      jellyfinSessionStoreProvider.overrideWithValue(sessionStore),
      jellyfinClientProvider.overrideWithValue(client),
      librarySourcePriorityProvider.overrideWith(_FixedPreference.new),
      offlineAvailableTrackKeysProvider.overrideWithValue(offlineKeys),
      // Drive probes explicitly instead of racing a background timer.
      jellyfinAvailabilityPollIntervalProvider.overrideWithValue(null),
    ],
  );
  addTearDown(container.dispose);
  // Keep the availability notifier alive for the whole test, the way the app's
  // library subscription does.
  container.listen(jellyfinAvailabilityProvider, (_, __) {});
  container.listen(libraryControllerProvider, (_, __) {});
  // Let the persisted session load, the catalog load, and the startup probe run.
  await _settle(container);
  return (
    container: container,
    client: client,
    repository: repository,
    sessionStore: sessionStore,
  );
}

/// Lets the async session load, catalog load and availability probe settle.
Future<void> _settle(ProviderContainer container) async {
  for (int i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  await container.read(libraryControllerProvider.notifier).refresh();
}

void main() {
  group('app starts while Jellyfin is unreachable', () {
    test('excludes Jellyfin tracks and keeps local music usable', () async {
      final boot = await _boot(verifyError: JellyfinException.notReachable());
      final ProviderContainer c = boot.container;

      expect(
        c.read(jellyfinAvailabilityProvider).status,
        SourceAvailability.unreachable,
      );
      // The active library holds only what can actually be played.
      expect(_uris(c.read(libraryUnifiedTracksProvider)), _uris(_localTracks));
      // Albums and artists are derived from the same set, so no browse surface
      // can offer a route back to a hidden track.
      expect(
        <String>[for (final a in c.read(libraryAlbumsProvider)) a.title],
        <String>['Dummy'],
      );
      expect(
        <String>[for (final a in c.read(libraryArtistsProvider)) a.name],
        <String>['Portishead'],
      );
    });

    test('keeps the connection configured and every record intact', () async {
      final boot = await _boot(verifyError: JellyfinException.notReachable());
      final ProviderContainer c = boot.container;

      // The saved server configuration is untouched — the user does not have to
      // remove the connection to get a usable library.
      final JellyfinSettingsState settings =
          c.read(jellyfinSettingsControllerProvider);
      expect(settings.phase, JellyfinConnectionPhase.connected);
      expect(settings.baseUrl, 'http://192.168.22.1:8096');
      expect(await boot.sessionStore.read(), isNotNull);
      expect(
        c.read(jellyfinSettingsControllerProvider.notifier).session,
        isNotNull,
      );

      // And nothing was deleted from the catalog: every stored row is still
      // there, ready to reappear.
      final List<Track> stored = await boot.repository.getAllTracks();
      expect(
          _uris(stored), containsAll(<String>['jellyfin:101', 'jellyfin:102']));
      expect(stored, hasLength(4));
      expect(c.read(unavailableTrackCountProvider), 2);
    });

    test('a rejected session reads as an authentication error, not offline',
        () async {
      final boot = await _boot(verifyError: JellyfinException.unauthorized());
      expect(
        boot.container.read(jellyfinAvailabilityProvider).status,
        SourceAvailability.authenticationError,
      );
      // Still excluded — the tracks can't be fetched either way — but the state
      // says the fix is signing in again, not moving closer to the server.
      expect(_uris(boot.container.read(libraryUnifiedTracksProvider)),
          _uris(_localTracks));
    });

    test('keeps Jellyfin tracks that are available offline', () async {
      final boot = await _boot(
        verifyError: JellyfinException.notReachable(),
        offlineKeys: <String>{
          CachedTrack.cacheKeyForTrack(_jellyfinTracks.first),
        },
      );
      expect(
        _uris(boot.container.read(libraryUnifiedTracksProvider)),
        <String>['jellyfin:101', ..._uris(_localTracks)],
      );
      expect(boot.container.read(unavailableTrackCountProvider), 1);
    });
  });

  group('connected -> unreachable', () {
    test('a reachable server shows the whole library', () async {
      final boot = await _boot();
      expect(
        boot.container.read(jellyfinAvailabilityProvider).status,
        SourceAvailability.available,
      );
      expect(
        _uris(boot.container.read(libraryUnifiedTracksProvider)),
        <String>[..._uris(_jellyfinTracks), ..._uris(_localTracks)],
      );
    });

    test('leaving the network hides Jellyfin tracks on the next probe',
        () async {
      final boot = await _boot();
      final ProviderContainer c = boot.container;
      expect(c.read(libraryUnifiedTracksProvider), hasLength(4));

      boot.client.verifyError = JellyfinException.notReachable();
      await c.read(jellyfinAvailabilityProvider.notifier).refresh();

      expect(c.read(jellyfinAvailabilityProvider).status,
          SourceAvailability.unreachable);
      expect(_uris(c.read(libraryUnifiedTracksProvider)), _uris(_localTracks));
      // Nothing was removed to make that happen.
      expect(await boot.repository.getAllTracks(), hasLength(4));
      expect(await boot.sessionStore.read(), isNotNull);
    });

    test('a failed playback resolution hides them without deleting anything',
        () async {
      // The playback path's own finding is adopted immediately, so the user
      // isn't left staring at tracks that just failed to play until the next
      // poll. It may only move the availability flag.
      final boot = await _boot();
      final ProviderContainer c = boot.container;

      c
          .read(jellyfinAvailabilityProvider.notifier)
          .noteReachability(ReachabilityStatus.serverUnreachable);

      expect(c.read(jellyfinAvailabilityProvider).status,
          SourceAvailability.unreachable);
      expect(_uris(c.read(libraryUnifiedTracksProvider)), _uris(_localTracks));
      expect(await boot.repository.getAllTracks(), hasLength(4));
      expect(await boot.sessionStore.read(), isNotNull);
      expect(c.read(jellyfinSettingsControllerProvider).phase,
          JellyfinConnectionPhase.connected);
    });

    test('an expired session is reported as an authentication error', () async {
      final boot = await _boot();
      boot.container
          .read(jellyfinAvailabilityProvider.notifier)
          .noteReachability(ReachabilityStatus.authFailure);
      expect(boot.container.read(jellyfinAvailabilityProvider).status,
          SourceAvailability.authenticationError);
    });
  });

  group('a playback attempt from a previous sign-in', () {
    test('cannot hide the library of the server signed in now', () async {
      final _HangingAddressClient client =
          _HangingAddressClient(_session.baseUrl);
      final boot = await _boot(fakeClient: client);
      final ProviderContainer c = boot.container;
      // The startup probes of the saved address hang too; let them answer so
      // the library starts from a reachable server.
      for (final Completer<void> probe in client.hanging) {
        probe.complete();
      }
      client.hanging.clear();
      await _settle(c);
      expect(c.read(jellyfinAvailabilityProvider).status,
          SourceAvailability.available);

      // A track is started on the saved LAN address, which now hangs.
      final Future<Object?> playing = c
          .read(remoteSourceRouterProvider)
          .resolve(_jellyfinTracks.first)
          .then<Object?>((_) => null, onError: (Object error) => error);
      await Future<void>.delayed(Duration.zero);
      expect(client.hanging, hasLength(1));

      // Meanwhile the listener signs out and back in through the server's
      // public address, which answers.
      await c.read(jellyfinSettingsControllerProvider.notifier).clear();
      final bool signedIn =
          await c.read(jellyfinSettingsControllerProvider.notifier).signIn(
                url: 'https://music.example.com',
                username: 'alice',
                password: 'pw',
              );
      expect(signedIn, isTrue);
      await _settle(c);
      expect(c.read(jellyfinAvailabilityProvider).status,
          SourceAvailability.available);

      // The old address finally gives up.
      client.verifyError = JellyfinException.notReachable();
      client.hanging.single.complete();
      expect(await playing, isA<PlaybackResolutionException>());
      client.verifyError = null;
      await _settle(c);

      expect(c.read(jellyfinAvailabilityProvider).status,
          SourceAvailability.available);
    });
  });

  group('unreachable -> connected', () {
    test('tracks reappear on their own, with no reconnect or rescan', () async {
      final boot = await _boot(verifyError: JellyfinException.notReachable());
      final ProviderContainer c = boot.container;
      expect(c.read(libraryUnifiedTracksProvider), hasLength(2));

      // Back on the home network. Nothing but the probe result changes — no
      // sign-in, no upsertCatalog, no library refresh.
      boot.client.verifyError = null;
      await c.read(jellyfinAvailabilityProvider.notifier).refresh();

      expect(c.read(jellyfinAvailabilityProvider).status,
          SourceAvailability.available);
      expect(
        _uris(c.read(libraryUnifiedTracksProvider)),
        <String>[..._uris(_jellyfinTracks), ..._uris(_localTracks)],
      );
      expect(c.read(unavailableTrackCountProvider), 0);
    });

    test('a successful playback resolution restores them too', () async {
      final boot = await _boot(verifyError: JellyfinException.notReachable());
      final ProviderContainer c = boot.container;
      expect(c.read(libraryUnifiedTracksProvider), hasLength(2));

      c
          .read(jellyfinAvailabilityProvider.notifier)
          .noteReachability(ReachabilityStatus.reachable);

      expect(c.read(libraryUnifiedTracksProvider), hasLength(4));
    });

    test('survives a round trip out and back', () async {
      final boot = await _boot();
      final ProviderContainer c = boot.container;
      final notifier = c.read(jellyfinAvailabilityProvider.notifier);

      boot.client.verifyError = JellyfinException.notReachable();
      await notifier.refresh();
      expect(c.read(libraryUnifiedTracksProvider), hasLength(2));

      boot.client.verifyError = null;
      await notifier.refresh();
      expect(c.read(libraryUnifiedTracksProvider), hasLength(4));

      boot.client.verifyError = JellyfinException.notReachable();
      await notifier.refresh();
      expect(c.read(libraryUnifiedTracksProvider), hasLength(2));

      // Four rows stored throughout: visibility changed, the catalog never did.
      expect(await boot.repository.getAllTracks(), hasLength(4));
    });
  });

  group('no server configured', () {
    test('reports notConfigured and hides nothing', () async {
      final repository = InMemoryMusicLibraryRepository();
      await repository.upsertCatalog(
        sourceId: 'local',
        tracks: _localTracks,
        albums: groupAlbums(_localTracks),
        artists: groupArtists(_localTracks),
      );
      final container = ProviderContainer(
        overrides: <Override>[
          musicLibraryRepositoryProvider.overrideWithValue(repository),
          jellyfinSessionStoreProvider
              .overrideWithValue(InMemoryJellyfinSessionStore()),
          jellyfinClientProvider.overrideWithValue(FakeJellyfinClient()),
          librarySourcePriorityProvider.overrideWith(_FixedPreference.new),
          jellyfinAvailabilityPollIntervalProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      container.listen(jellyfinAvailabilityProvider, (_, __) {});
      await _settle(container);

      expect(container.read(jellyfinAvailabilityProvider).status,
          SourceAvailability.notConfigured);
      expect(container.read(unavailableSourceIdsProvider), isEmpty);
      expect(_uris(container.read(libraryUnifiedTracksProvider)),
          _uris(_localTracks));
    });
  });

  group('diagnostics report the real connection state', () {
    test('an unreachable configured server does not read as connected', () {
      const AppDiagnosticsData data = AppDiagnosticsData(
        appVersion: '0.2.4',
        jellyfinState: 'configured (server unreachable)',
        jellyfinHost: 'http://192.168.22.1:8096',
        libraryTrackCount: 9063,
        unavailableTrackCount: 9000,
      );
      final String report = AppDiagnostics.report(data);
      expect(report, contains('Jellyfin: configured (server unreachable)'));
      expect(report, isNot(contains('Jellyfin: connected')));
      expect(report, contains('Jellyfin host: 192.168.22.1:8096'));
      expect(report, contains('Library tracks: 9063'));
      expect(
        report,
        contains('Unavailable tracks (hidden, not deleted): 9000'),
      );
    });

    test('omits the hidden-track line when nothing is hidden', () {
      const AppDiagnosticsData data = AppDiagnosticsData(
        appVersion: '0.2.4',
        jellyfinState: 'connected',
        libraryTrackCount: 9063,
        unavailableTrackCount: 0,
      );
      final String report = AppDiagnostics.report(data);
      expect(report, contains('Jellyfin: connected'));
      expect(report, isNot(contains('Unavailable tracks')));
    });
  });
}
