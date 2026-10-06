import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/library_grouping.dart';
import 'package:linthra/core/catalog/source_priority.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/core/sources/source_availability.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_session_store.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/jellyfin_session_store_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/library/library_controller.dart';
import 'package:linthra/features/library/source_preference_controller.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_availability_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_providers.dart';

import '../../core/sources/jellyfin/fake_jellyfin_client.dart';

// The variant of "a playback attempt from a previous sign-in cannot hide the
// library of the server signed in now" (jellyfin_availability_test.dart) where
// the listener signs back in through the *same* address: same server, same
// user, a new token. The attempt still carries the old session.

const JellyfinSession _saved = JellyfinSession(
  baseUrl: 'http://192.168.22.1:8096',
  userId: 'user-1',
  accessToken: 'old-token',
  deviceId: 'device-1',
  userName: 'alice',
  serverName: 'Home',
);

const Track _hello = Track(
  id: '101',
  title: 'Hello',
  uri: 'jellyfin:101',
  artistName: 'Adele',
  albumName: '25',
  duration: Duration(minutes: 3),
);

/// A server where every request made with [hangingToken] waits until the test
/// answers it: a request on a connection that died, which only gives up at its
/// timeout. Requests with any other token answer at once.
class _HangingTokenClient extends FakeJellyfinClient {
  _HangingTokenClient(this.hangingToken);

  final String hangingToken;
  final List<Completer<void>> hanging = <Completer<void>>[];
  bool hang = false;

  @override
  Future<void> verifySession(JellyfinSession session) async {
    if (hang && session.accessToken == hangingToken) {
      final Completer<void> answer = Completer<void>();
      hanging.add(answer);
      await answer.future;
      throw JellyfinException.notReachable();
    }
    return super.verifySession(session);
  }
}

class _FixedPreference extends SourcePreferenceController {
  @override
  SourcePriority build() => const SourcePriority(<String>['jellyfin']);
}

Future<void> _settle(ProviderContainer container) async {
  for (int i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  await container.read(libraryControllerProvider.notifier).refresh();
}

void main() {
  test(
      'a playback attempt made with the token before a re-sign-in cannot hide '
      'the library once the same account is signed in again', () async {
    final InMemoryMusicLibraryRepository repository =
        InMemoryMusicLibraryRepository();
    await repository.upsertCatalog(
      sourceId: 'jellyfin',
      tracks: const <Track>[_hello],
      albums: groupAlbums(const <Track>[_hello]),
      artists: groupArtists(const <Track>[_hello]),
    );
    final _HangingTokenClient client = _HangingTokenClient('old-token');
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[
        musicLibraryRepositoryProvider.overrideWithValue(repository),
        jellyfinSessionStoreProvider.overrideWithValue(
          InMemoryJellyfinSessionStore(initialSession: _saved),
        ),
        jellyfinClientProvider.overrideWithValue(client),
        librarySourcePriorityProvider.overrideWith(_FixedPreference.new),
        jellyfinAvailabilityPollIntervalProvider.overrideWithValue(null),
      ],
    );
    addTearDown(c.dispose);
    c.listen(jellyfinAvailabilityProvider, (_, __) {});
    c.listen(libraryControllerProvider, (_, __) {});
    await _settle(c);
    expect(c.read(jellyfinAvailabilityProvider).status,
        SourceAvailability.available);

    // A track is started with the saved session; its connection hangs.
    client.hang = true;
    final Future<Object?> playing = c
        .read(remoteSourceRouterProvider)
        .resolve(_hello)
        .then<Object?>((_) => null, onError: (Object error) => error);
    await Future<void>.delayed(Duration.zero);
    expect(client.hanging, hasLength(1));

    // Meanwhile the listener signs out and back in through the same address.
    // The sign-in mints a new token, and the server answers it.
    await c.read(jellyfinSettingsControllerProvider.notifier).clear();
    expect(
      await c.read(jellyfinSettingsControllerProvider.notifier).signIn(
            url: 'http://192.168.22.1:8096',
            username: 'alice',
            password: 'pw',
          ),
      isTrue,
    );
    await _settle(c);
    expect(
      c.read(jellyfinSettingsControllerProvider.notifier).session!.accessToken,
      isNot('old-token'),
    );
    expect(c.read(jellyfinAvailabilityProvider).status,
        SourceAvailability.available);

    // The old connection finally gives up.
    client.hanging.single.complete();
    expect(await playing, isA<PlaybackResolutionException>());
    await _settle(c);

    expect(
      c.read(jellyfinAvailabilityProvider).status,
      SourceAvailability.available,
      reason: 'the server answered the session signed in now; what a request '
          'on the previous session learned says nothing about it',
    );
  });
}
