import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_music_source.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_controller.dart';

import '../../core/sources/jellyfin/fake_jellyfin_client.dart';

// The stream URL the prebufferer warms carries the account's token. These
// run the real provider graph (prebufferer, shared cache, cache-backed
// resolver, Jellyfin resolver) and change who is signed in between the warm
// and the play, the way signing out or into another account does.

const JellyfinSession _alice = JellyfinSession(
  baseUrl: 'https://music.example.com',
  userId: 'user-alice',
  accessToken: 'alice-token',
  deviceId: 'device-1',
  userName: 'alice',
  serverName: 'Home',
);

const JellyfinSession _bob = JellyfinSession(
  baseUrl: 'https://music.example.com',
  userId: 'user-bob',
  accessToken: 'bob-token',
  deviceId: 'device-1',
  userName: 'bob',
  serverName: 'Home',
);

/// Who is signed in to Jellyfin right now; null when signed out.
final _signedIn = StateProvider<JellyfinSession?>((ref) => _alice);

/// A client whose session check can be held open, so sign-out can land after
/// a warm has read the session it mints with and before it stores the URL.
class _GatedClient extends FakeJellyfinClient {
  Completer<void>? gate;
  final Completer<void> reached = Completer<void>();

  @override
  Future<void> verifySession(JellyfinSession session) async {
    final Completer<void>? pending = gate;
    if (pending != null) {
      if (!reached.isCompleted) reached.complete();
      await pending.future;
    }
    return super.verifySession(session);
  }
}

const Track _next = Track(id: 'item-2', title: 'Next', uri: 'jellyfin:item-2');

void main() {
  late ProviderContainer container;
  late _GatedClient client;

  setUp(() {
    client = _GatedClient();
    container = ProviderContainer(
      overrides: <Override>[
        jellyfinMusicSourceProvider.overrideWith((ref) {
          final JellyfinSession? session = ref.watch(_signedIn);
          return session == null
              ? null
              : JellyfinMusicSource(session: session, client: client);
        }),
      ],
    );
  });

  tearDown(() => container.dispose());

  Future<void> warmNextTrack() =>
      container.read(remoteStreamPrebuffererProvider).preload(_next);

  Future<ResolvedPlayable> play(Track track) =>
      container.read(remoteCacheResolverProvider).resolve(track);

  test('a URL warmed before sign-out is not played after it', () async {
    await warmNextTrack();
    container.read(_signedIn.notifier).state = null;

    await expectLater(
      play(_next),
      throwsA(isA<PlaybackResolutionException>().having(
        (PlaybackResolutionException e) => e.kind,
        'kind',
        PlaybackResolutionErrorKind.notSignedIn,
      )),
    );
  });

  test("a URL warmed for one account is not played for the next", () async {
    await warmNextTrack();
    container.read(_signedIn.notifier).state = _bob;

    final ResolvedPlayable played = await play(_next);

    expect(played.uri.toString(), isNot(contains('alice-token')));
    expect(played.uri.toString(), contains('bob-token'));
  });

  test('a warm still resolving at sign-out is not kept for later', () async {
    // The warm has read the session it mints with; sign-out lands before it
    // stores its URL. Signing back in as someone else must not find it.
    client.gate = Completer<void>();
    final Future<void> warming = warmNextTrack();
    await client.reached.future;
    container.read(_signedIn.notifier).state = null;
    client.gate!.complete();
    client.gate = null;
    await warming;
    container.read(_signedIn.notifier).state = _bob;

    final ResolvedPlayable played = await play(_next);

    expect(played.uri.toString(), isNot(contains('alice-token')));
  });

  test('a URL warmed for the account still signed in is served', () async {
    // Control: the cache keeps doing its job for the same account.
    await warmNextTrack();

    final ResolvedPlayable played = await play(_next);

    expect(played.uri.toString(), contains('alice-token'));
  });
}
