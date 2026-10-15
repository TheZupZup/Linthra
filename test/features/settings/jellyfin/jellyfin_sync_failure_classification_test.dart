// A failed Jellyfin sync is classified by probing the session, and an
// inconclusive probe falls back to what the sync error itself says.
//
// The card offers a next step from the classified reason: sign in again,
// check the connection, try again later, or keep the library and retry the
// sync. Only an unreachable or a rejecting probe overrides the sync error;
// any other probe failure (the probe hit a server error, or an answer that
// isn't Jellyfin's) leaves the sync error's own static mapping in charge,
// and a probe that succeeds means the server is fine and only the library
// read failed. The existing tests pin the 401 and unreachable probes and a
// 5xx on both; these pin the fallback and the "connected, library kept"
// branch for the error kinds they didn't reach.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/diagnostics/safe_event_log.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_music_source.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_sync_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_sync_state.dart';

import '../../../core/sources/jellyfin/fake_jellyfin_client.dart';

const JellyfinSession _session = JellyfinSession(
  baseUrl: 'https://music.example.com',
  userId: 'user-1',
  accessToken: 'secret-token',
  deviceId: 'device-1',
  userName: 'alice',
);

/// Holds the catalog and counts writes to it.
class _RecordingRepository implements MusicLibraryRepository {
  _RecordingRepository({List<Track> existing = const <Track>[]})
      : tracks = existing;

  List<Track> tracks;
  int upsertCount = 0;

  @override
  Future<void> upsertCatalog({
    required String sourceId,
    required List<Track> tracks,
    required List<Album> albums,
    required List<Artist> artists,
  }) async {
    upsertCount++;
    this.tracks = tracks;
  }

  @override
  Future<List<Track>> getAllTracks() async => tracks;

  @override
  Future<List<Album>> getAllAlbums() async => const <Album>[];

  @override
  Future<List<Artist>> getAllArtists() async => const <Artist>[];

  @override
  Future<Track?> getTrackByUri(String uri) async => null;

  @override
  Future<void> removeTracks(List<String> trackIds) async {}
}

/// Runs one sync whose library read fails with [itemsError] and whose
/// session probe fails with [verifyError] (or succeeds when null).
Future<(JellyfinSyncState, FakeJellyfinClient)> _syncFailing({
  required JellyfinException itemsError,
  JellyfinException? verifyError,
  MusicLibraryRepository? repository,
}) async {
  final FakeJellyfinClient client = FakeJellyfinClient(
    itemsError: itemsError,
    verifyError: verifyError,
  );
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      musicLibraryRepositoryProvider
          .overrideWithValue(repository ?? _RecordingRepository()),
      jellyfinMusicSourceProvider.overrideWithValue(
        JellyfinMusicSource(session: _session, client: client),
      ),
    ],
  );
  addTearDown(container.dispose);
  await container.read(jellyfinSyncControllerProvider.notifier).sync();
  return (container.read(jellyfinSyncControllerProvider), client);
}

String _breadcrumb() => SafeEventLog.instance.lines
    .singleWhere((String line) => line.contains('fail:library'));

void main() {
  setUp(SafeEventLog.instance.clear);
  tearDown(SafeEventLog.instance.clear);

  test(
      'an answer that is not Jellyfin, on the sync and the probe alike, keeps '
      "the error's own message", () async {
    final (JellyfinSyncState state, FakeJellyfinClient client) =
        await _syncFailing(
      itemsError: JellyfinException.notJellyfin(),
      verifyError: JellyfinException.notJellyfin(),
    );

    expect(client.verifyCount, 1);
    expect(state.status, JellyfinSyncStatus.error);
    expect(state.failureReason, JellyfinSyncFailureReason.generic);
    expect(state.message, JellyfinException.notJellyfin().message);
    expect(state.needsSignIn, isFalse);
    expect(state.connectionOkButSyncFailed, isFalse);
    // The probe settled nothing either way.
    expect(_breadcrumb(), contains('category=notJellyfin'));
    expect(_breadcrumb(), contains('reachable=unknown auth=unknown'));
  });

  test(
      'an unreachable sync whose probe hits a server error still reads as '
      'unreachable', () async {
    final (JellyfinSyncState state, FakeJellyfinClient client) =
        await _syncFailing(
      itemsError: JellyfinException.notReachable(),
      verifyError: JellyfinException.serverError(502),
    );

    expect(client.verifyCount, 1);
    expect(state.status, JellyfinSyncStatus.error);
    expect(state.failureReason, JellyfinSyncFailureReason.serverUnreachable);
    expect(state.message, contains("Couldn't reach your Jellyfin server"));
    expect(state.needsSignIn, isFalse);
    expect(state.connectionOkButSyncFailed, isFalse);
    expect(_breadcrumb(), contains('category=notReachable'));
    expect(_breadcrumb(), contains('reachable=unknown'));
  });

  test(
      'an unusable library answer from a server the probe reaches keeps the '
      'library and offers a retry', () async {
    const List<Track> existing = <Track>[
      Track(id: 'j1', title: 'Old One', uri: 'jellyfin:j1'),
    ];
    final _RecordingRepository repository =
        _RecordingRepository(existing: existing);

    final (JellyfinSyncState state, FakeJellyfinClient client) =
        await _syncFailing(
      itemsError: JellyfinException.unsupportedResponse(),
      repository: repository,
    );

    expect(client.verifyCount, 1);
    expect(state.status, JellyfinSyncStatus.error);
    expect(state.failureReason, JellyfinSyncFailureReason.librarySyncFailed);
    expect(state.connectionOkButSyncFailed, isTrue);
    expect(state.needsSignIn, isFalse);
    expect(state.message, contains('still here'));
    expect(repository.upsertCount, 0);
    expect(await repository.getAllTracks(), existing);
    expect(_breadcrumb(), contains('category=unsupportedResponse'));
    expect(_breadcrumb(), contains('reachable=yes auth=yes'));
  });
}
