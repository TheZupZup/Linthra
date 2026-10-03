import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_music_source.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_providers.dart';

import '../../core/sources/jellyfin/fake_jellyfin_client.dart';
import 'fake_playback_controller.dart';

// The remote-control socket carries the token of the account it was opened
// for. This runs the real receiver, activator and command service against a
// loopback control socket and changes who is signed in while a Jellyfin track
// keeps playing, the way signing out or into another account does.

/// Who is signed in to Jellyfin right now; null when signed out.
final _signedIn = StateProvider<JellyfinSession?>((ref) => null);

typedef _Connection = ({String? token, Future<void> closed});

/// A loopback stand-in for a Jellyfin server's control WebSocket. It accepts
/// every connection and tells the test which token each one carries and when
/// the app closes it.
class _ControlServer {
  _ControlServer._(this._server) {
    _server.listen((HttpRequest request) async {
      final WebSocket socket = await WebSocketTransformer.upgrade(request);
      final Completer<void> closed = Completer<void>();
      socket.listen((_) {}, onDone: closed.complete);
      _connections.add((
        token: request.uri.queryParameters['ApiKey'],
        closed: closed.future,
      ));
    });
  }

  static Future<_ControlServer> start() async =>
      _ControlServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final StreamController<_Connection> _connections =
      StreamController<_Connection>.broadcast();

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  /// The next connection the app opens.
  Future<_Connection> get nextConnection => _connections.stream.first;

  Future<void> close() => _server.close(force: true);
}

const Duration _wait = Duration(seconds: 5);

const Track _song = Track(id: 'item-1', title: 'Song', uri: 'jellyfin:item-1');

void main() {
  test(
      'signing out closes the remote-control connection, and signing in as '
      'someone else connects for them', () async {
    final _ControlServer server = await _ControlServer.start();
    addTearDown(server.close);
    final JellyfinSession alice = JellyfinSession(
      baseUrl: server.baseUrl,
      userId: 'user-alice',
      accessToken: 'alice-token',
      deviceId: 'device-1',
    );
    final JellyfinSession bob = JellyfinSession(
      baseUrl: server.baseUrl,
      userId: 'user-bob',
      accessToken: 'bob-token',
      deviceId: 'device-2',
    );
    final FakeJellyfinClient client = FakeJellyfinClient();
    final FakePlaybackController engine = FakePlaybackController();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        jellyfinClientProvider.overrideWithValue(client),
        jellyfinMusicSourceProvider.overrideWith((ref) {
          final JellyfinSession? session = ref.watch(_signedIn);
          return session == null
              ? null
              : JellyfinMusicSource(session: session, client: client);
        }),
        localPlaybackControllerProvider.overrideWithValue(engine),
      ],
    );
    addTearDown(container.dispose);
    container.read(_signedIn.notifier).state = alice;
    // What main() reads after startup.
    container.read(remoteControlServiceProvider);
    container.read(remoteControlActivatorProvider);

    // A Jellyfin track plays: remote control connects as alice.
    final Future<_Connection> first = server.nextConnection;
    engine.emit(
      const PlaybackState(status: PlaybackStatus.playing, currentTrack: _song),
    );
    final _Connection aliceConnection = await first.timeout(_wait);
    expect(aliceConnection.token, 'alice-token');

    // Signed out while the track keeps playing.
    container.read(_signedIn.notifier).state = null;
    final bool closed = await aliceConnection.closed
        .then((_) => true)
        .timeout(_wait, onTimeout: () => false);
    expect(closed, isTrue,
        reason: "the signed-out account's connection stayed open");

    // Signed in as bob, still on the same track: remote control is his now.
    final Future<_Connection> next = server.nextConnection;
    container.read(_signedIn.notifier).state = bob;
    expect((await next.timeout(_wait)).token, 'bob-token');
  });
}
