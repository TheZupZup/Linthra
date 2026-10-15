// A Jellyfin library fetch that fails after the account changed says nothing.
//
// The sync classifies a failed fetch by probing the session it synced with
// (`/Users/Me`), then shows the outcome on the card and drops a diagnostics
// breadcrumb. When the user signed out, or into another account, while the
// fetch was out, that failure belongs to an account that is gone: probing it
// would send the old token to the old server, and the error would land on
// the new account's card (or on a signed-out one) as if it were theirs. The
// run has to go back to idle instead, without a probe, a breadcrumb or a
// write.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/diagnostics/safe_event_log.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_music_source.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_sync_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_sync_state.dart';

import '../../../core/sources/jellyfin/fake_jellyfin_client.dart';

const JellyfinSession _alice = JellyfinSession(
  baseUrl: 'https://music.example.com',
  userId: 'user-1',
  accessToken: 'alice-token',
  deviceId: 'device-1',
  userName: 'alice',
);

const JellyfinSession _bob = JellyfinSession(
  baseUrl: 'https://music.example.com',
  userId: 'user-2',
  accessToken: 'bob-token',
  deviceId: 'device-1',
  userName: 'bob',
);

/// Counts catalog writes.
class _RecordingRepository implements MusicLibraryRepository {
  int upsertCount = 0;

  @override
  Future<void> upsertCatalog({
    required String sourceId,
    required List<Track> tracks,
    required List<Album> albums,
    required List<Artist> artists,
  }) async {
    upsertCount++;
  }

  @override
  Future<List<Track>> getAllTracks() async => const <Track>[];

  @override
  Future<List<Album>> getAllAlbums() async => const <Album>[];

  @override
  Future<List<Artist>> getAllArtists() async => const <Artist>[];

  @override
  Future<Track?> getTrackByUri(String uri) async => null;

  @override
  Future<void> removeTracks(List<String> trackIds) async {}
}

/// A [FakeJellyfinClient] that says through [reached] when the track listing
/// was asked for, then holds it on its gate.
class _HeldClient extends FakeJellyfinClient {
  _HeldClient({super.itemsError}) {
    itemsGate = Completer<void>();
  }

  final Completer<void> reached = Completer<void>();

  @override
  Future<JellyfinItemListing> fetchItems(
    JellyfinSession session, {
    required JellyfinItemKind kind,
  }) {
    if (!reached.isCompleted) reached.complete();
    return super.fetchItems(session, kind: kind);
  }
}

List<Override> _overrides(
  MusicLibraryRepository repository,
  JellyfinMusicSource? source,
) =>
    <Override>[
      musicLibraryRepositoryProvider.overrideWithValue(repository),
      jellyfinMusicSourceProvider.overrideWithValue(source),
    ];

Iterable<String> _failureBreadcrumbs() => SafeEventLog.instance.lines
    .where((String line) => line.contains('fail:library'));

void main() {
  setUp(SafeEventLog.instance.clear);
  tearDown(SafeEventLog.instance.clear);

  test(
      'a fetch that fails after a sign-out goes idle without a probe, a '
      'breadcrumb or a write', () async {
    final _HeldClient client =
        _HeldClient(itemsError: JellyfinException.serverError(503));
    final _RecordingRepository repository = _RecordingRepository();
    final ProviderContainer container = ProviderContainer(
      overrides: _overrides(
        repository,
        JellyfinMusicSource(session: _alice, client: client),
      ),
    );
    addTearDown(container.dispose);

    final Future<void> run =
        container.read(jellyfinSyncControllerProvider.notifier).sync();
    await client.reached.future;
    container.updateOverrides(_overrides(repository, null));
    client.itemsGate!.complete();
    await run;

    final JellyfinSyncState state =
        container.read(jellyfinSyncControllerProvider);
    expect(state.status, JellyfinSyncStatus.idle);
    expect(state.failureReason, isNull);
    expect(client.verifyCount, 0, reason: 'the old session is not probed');
    expect(repository.upsertCount, 0);
    expect(_failureBreadcrumbs(), isEmpty);
  });

  test(
      "a fetch that fails after a switch to another account leaves the new "
      "account's card alone", () async {
    final _HeldClient aliceClient =
        _HeldClient(itemsError: JellyfinException.notReachable());
    final FakeJellyfinClient bobClient = FakeJellyfinClient();
    final _RecordingRepository repository = _RecordingRepository();
    final ProviderContainer container = ProviderContainer(
      overrides: _overrides(
        repository,
        JellyfinMusicSource(session: _alice, client: aliceClient),
      ),
    );
    addTearDown(container.dispose);

    final Future<void> run =
        container.read(jellyfinSyncControllerProvider.notifier).sync();
    await aliceClient.reached.future;
    container.updateOverrides(_overrides(
      repository,
      JellyfinMusicSource(session: _bob, client: bobClient),
    ));
    aliceClient.itemsGate!.complete();
    await run;

    final JellyfinSyncState state =
        container.read(jellyfinSyncControllerProvider);
    expect(state.status, JellyfinSyncStatus.idle);
    expect(state.message, isNull);
    // Neither account's session was probed for alice's failure.
    expect(aliceClient.verifyCount, 0);
    expect(bobClient.verifyCount, 0);
    expect(bobClient.requestedKinds, isEmpty);
    expect(repository.upsertCount, 0);
    expect(_failureBreadcrumbs(), isEmpty);
  });
}
