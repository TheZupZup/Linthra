import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/play_history.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/play_history_repository.dart';
import 'package:linthra/core/repositories/playlist_repository.dart';
import 'package:linthra/core/repositories/song_origin_legacy_store.dart';
import 'package:linthra/core/services/song_origins.dart';
import 'package:linthra/core/sources/subsonic/subsonic_account_fingerprint.dart';
import 'package:linthra/core/sources/subsonic/subsonic_api.dart';
import 'package:linthra/data/repositories/in_memory_play_history_store.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/in_memory_song_origin_legacy_store.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_session_store.dart';
import 'package:linthra/data/repositories/play_history_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/data/repositories/song_origins_provider.dart';
import 'package:linthra/data/repositories/subsonic_session_store_provider.dart';
import 'package:linthra/features/player/song_origins_binding.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_controller.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_providers.dart';

import '../../core/sources/subsonic/fake_subsonic_client.dart';

/// The app's binding for #795: Subsonic references follow the signed-in
/// account, read from the real settings controller.

/// A keyring that is locked: the saved sign-in can't be read.
class _LockedSessionStore extends InMemorySubsonicSessionStore {
  @override
  Future<SubsonicSession?> read() async => throw StateError('keyring locked');
}

const SubsonicSession _alice = SubsonicSession(
  baseUrl: 'https://a.example.com',
  username: 'alice',
  salt: 's',
  token: 't',
);

const Track _song = Track(id: '48211', title: 'Song', uri: 'subsonic:48211');

void main() {
  late SongOriginLegacyStore legacy;
  late InMemoryPlaylistStore playlists;
  late InMemoryPlayHistoryStore history;

  setUp(() {
    legacy = InMemorySongOriginLegacyStore();
    playlists = InMemoryPlaylistStore();
    history = InMemoryPlayHistoryStore();
  });

  /// One launch of the app, with [restored] as the saved Subsonic sign-in.
  Future<ProviderContainer> launch(
    SubsonicSession? restored, {
    bool keyringLocked = false,
  }) async {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        subsonicClientProvider.overrideWithValue(FakeSubsonicClient(
          serverInfo: const SubsonicServerInfo(apiVersion: '1.16.1'),
        )),
        subsonicSessionStoreProvider.overrideWithValue(
          keyringLocked
              ? _LockedSessionStore()
              : InMemorySubsonicSessionStore(initialSession: restored),
        ),
        songOriginLegacyStoreProvider.overrideWithValue(legacy),
        playlistStoreProvider.overrideWithValue(playlists),
        playHistoryStoreProvider.overrideWithValue(history),
        songOriginsOverride,
      ],
    );
    addTearDown(container.dispose);
    await container
        .read(subsonicSettingsControllerProvider.notifier)
        .ensureLoaded();
    final SongOrigins origins = container.read(songOriginsProvider);
    await (origins as SessionSongOrigins).settleLegacy();
    return container;
  }

  Future<void> signIn(ProviderContainer container, String url) async {
    final SubsonicSettingsController subsonic =
        container.read(subsonicSettingsControllerProvider.notifier);
    await subsonic.clear();
    expect(
      await subsonic.signIn(url: url, username: 'alice', password: 'pw'),
      isTrue,
    );
    await pumpEventQueue();
  }

  test(
      'origins follow the signed-in account, and older references stay with '
      'the one restored first', () async {
    final ProviderContainer first = await launch(_alice);
    final SongOrigins origins = first.read(songOriginsProvider);
    final String alice = subsonicAccountFingerprint(_alice);
    expect(origins.current('subsonic:1'), alice);
    expect(origins.legacy('subsonic:1'), alice);
    expect(origins.binds('jellyfin:1'), isFalse);

    final PlaylistRepository repo = first.read(playlistRepositoryProvider);
    final Playlist mix = await repo.createPlaylist('Mix');
    await repo.addTracks(mix.id, <String>['subsonic:48211']);
    final PlayHistoryRepository plays =
        first.read(playHistoryRepositoryProvider);
    await plays.recordCompletion(_song);

    // Another server, same user name.
    await signIn(first, 'https://b.example.com');
    expect(origins.current('subsonic:1'), isNot(alice));
    final Playlist onB = (await repo.getPlaylistById(mix.id))!;
    expect(repo.entriesHere(onB), isEmpty);
    expect(plays.current.hasPlayed('subsonic:48211'), isFalse);
    first.dispose();

    // Next launch restores B. What was settled first stays settled.
    final ProviderContainer second = await launch(
      const SubsonicSession(
        baseUrl: 'https://b.example.com',
        username: 'alice',
        salt: 's',
        token: 't',
      ),
    );
    expect(second.read(songOriginsProvider).legacy('subsonic:1'), alice);
    final PlayHistory onBAgain =
        await second.read(playHistoryRepositoryProvider).historyStream.first;
    expect(onBAgain.hasPlayed('subsonic:48211'), isFalse);
  });

  test('signed out at the first launch, older references are nobody\'s',
      () async {
    final ProviderContainer container = await launch(null);
    expect(
      container.read(songOriginsProvider).legacy('subsonic:1'),
      noSongOrigin,
    );

    // Signing in afterwards, to any server, never claims them.
    await signIn(container, 'https://a.example.com');
    expect(
      container.read(songOriginsProvider).legacy('subsonic:1'),
      noSongOrigin,
    );
  });

  test(
      'a keyring locked at the first launch settles nothing for Subsonic, '
      'and the next launch that reads the sign-in does', () async {
    final ProviderContainer locked = await launch(null, keyringLocked: true);
    expect(locked.read(songOriginsProvider).legacy('subsonic:1'), isNull);
    locked.dispose();

    final ProviderContainer unlocked = await launch(_alice);
    expect(
      unlocked.read(songOriginsProvider).legacy('subsonic:1'),
      subsonicAccountFingerprint(_alice),
    );
  });
}
