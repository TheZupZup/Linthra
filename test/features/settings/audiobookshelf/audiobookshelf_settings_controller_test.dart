import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/audiobookshelf_session.dart';
import 'package:linthra/core/repositories/audiobookshelf_session_store.dart';
import 'package:linthra/core/repositories/secure_storage_exception.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_api.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_exception.dart';
import 'package:linthra/core/sources/audiobookshelf/http_audiobookshelf_client.dart';
import 'package:linthra/data/repositories/audiobookshelf_session_store_provider.dart';
import 'package:linthra/data/repositories/in_memory_audiobookshelf_session_store.dart';
import 'package:linthra/features/settings/audiobookshelf/audiobookshelf_settings_controller.dart';
import 'package:linthra/features/settings/audiobookshelf/audiobookshelf_settings_providers.dart';
import 'package:linthra/features/settings/audiobookshelf/audiobookshelf_settings_state.dart';

import '../../../core/sources/audiobookshelf/fake_audiobookshelf_client.dart';

const _session = AudiobookshelfSession(
  baseUrl: 'https://audiobooks.example.com',
  userId: 'user-1',
  accessToken: 'tok-1',
  userName: 'alice',
  defaultLibraryId: 'lib-1',
  serverVersion: '2.17.0',
);

const _status = AudiobookshelfServerStatus(
  serverVersion: '2.17.0',
  isInitialized: true,
);

const _authResult = AudiobookshelfAuthResult(
  userId: 'user-1',
  accessToken: 'tok-1',
  refreshToken: 'refresh-1',
  userName: 'alice',
  defaultLibraryId: 'lib-1',
);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

http.Response _json(Map<String, dynamic> body) => http.Response(
      jsonEncode(body),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );

FakeAudiobookshelfClient _signInReadyClient({
  List<AudiobookshelfLibraryDto> libraries = const <AudiobookshelfLibraryDto>[],
}) {
  return FakeAudiobookshelfClient(
    serverStatus: _status,
    authResult: _authResult,
    libraries: libraries,
  );
}

/// A session store standing in for a platform keyring that cannot be used:
/// missing, locked, or refused by a sandbox. It fails exactly the way
/// `SecureAudiobookshelfSessionStore` does through `SecureSessionStorage` (a
/// typed [SecureStorageException]), so these tests exercise the controller's
/// real failure path rather than a generic thrown object.
class _UnusableKeyringStore implements AudiobookshelfSessionStore {
  _UnusableKeyringStore({
    AudiobookshelfSession? initialSession,
    this.readFailure,
    this.writeFailure,
    this.clearFailure,
  }) : _session = initialSession;

  AudiobookshelfSession? _session;
  final SecureStorageException? readFailure;
  final SecureStorageException? writeFailure;
  final SecureStorageException? clearFailure;

  @override
  Future<AudiobookshelfSession?> read() async {
    if (readFailure != null) throw readFailure!;
    return _session;
  }

  @override
  Future<void> write(AudiobookshelfSession session) async {
    if (writeFailure != null) throw writeFailure!;
    _session = session;
  }

  @override
  Future<void> clear() async {
    if (clearFailure != null) throw clearFailure!;
    _session = null;
  }
}

const SecureStorageException _lockedRead = SecureStorageException(
  operation: SecureStorageOperation.read,
  failure: SecureStorageFailure.locked,
);

const SecureStorageException _unavailableWrite = SecureStorageException(
  operation: SecureStorageOperation.write,
  failure: SecureStorageFailure.unavailable,
);

const SecureStorageException _lockedDelete = SecureStorageException(
  operation: SecureStorageOperation.delete,
  failure: SecureStorageFailure.locked,
);

ProviderContainer _container({
  FakeAudiobookshelfClient? client,
  AudiobookshelfSessionStore? store,
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      audiobookshelfClientProvider
          .overrideWithValue(client ?? FakeAudiobookshelfClient()),
      audiobookshelfSessionStoreProvider
          .overrideWithValue(store ?? InMemoryAudiobookshelfSessionStore()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('load', () {
    test('starts disconnected when nothing is persisted', () async {
      final container = _container();
      container.read(audiobookshelfSettingsControllerProvider);
      await _settle();

      expect(
        container.read(audiobookshelfSettingsControllerProvider).phase,
        AudiobookshelfConnectionPhase.disconnected,
      );
    });

    test('ensureLoaded restores a persisted session', () async {
      final container = _container(
        store: InMemoryAudiobookshelfSessionStore(initialSession: _session),
      );

      await container
          .read(audiobookshelfSettingsControllerProvider.notifier)
          .ensureLoaded();

      final state = container.read(audiobookshelfSettingsControllerProvider);
      expect(state.phase, AudiobookshelfConnectionPhase.connected);
      expect(state.username, 'alice');
      expect(state.baseUrl, 'https://audiobooks.example.com');
      expect(
        container
            .read(audiobookshelfSettingsControllerProvider.notifier)
            .session,
        isNotNull,
      );
    });

    test('reports an unusable keyring instead of silently signing out',
        () async {
      final container = _container(
        store: _UnusableKeyringStore(readFailure: _lockedRead),
      );

      await container
          .read(audiobookshelfSettingsControllerProvider.notifier)
          .ensureLoaded();

      final state = container.read(audiobookshelfSettingsControllerProvider);
      expect(state.phase, AudiobookshelfConnectionPhase.disconnected);
      expect(state.errorMessage, contains('Audiobookshelf'));
    });
  });

  group('testConnection', () {
    test('reports the reached server version without sending credentials',
        () async {
      final client = _signInReadyClient();
      final container = _container(client: client);
      final notifier =
          container.read(audiobookshelfSettingsControllerProvider.notifier);
      await _settle();

      final ok = await notifier.testConnection('audiobooks.example.com');

      expect(ok, isTrue);
      final state = container.read(audiobookshelfSettingsControllerProvider);
      expect(state.phase, AudiobookshelfConnectionPhase.tested);
      expect(state.statusMessage, contains('2.17.0'));
      // A test never authenticates, so no credential reached the client.
      expect(client.lastUsername, isNull);
      expect(client.lastPassword, isNull);
    });

    test('surfaces a friendly error on failure', () async {
      final container = _container(
        client: FakeAudiobookshelfClient(
          serverStatusError: AudiobookshelfException.notAudiobookshelf(),
        ),
      );
      final notifier =
          container.read(audiobookshelfSettingsControllerProvider.notifier);
      await _settle();

      final ok = await notifier.testConnection('example.com');

      expect(ok, isFalse);
      final state = container.read(audiobookshelfSettingsControllerProvider);
      expect(state.phase, AudiobookshelfConnectionPhase.disconnected);
      expect(state.errorKind, AudiobookshelfErrorKind.notAudiobookshelf);
      expect(state.errorMessage, isNotNull);
    });
  });

  group('signIn', () {
    test('persists the session and never exposes the password or tokens',
        () async {
      final store = InMemoryAudiobookshelfSessionStore();
      final client = _signInReadyClient();
      final container = _container(client: client, store: store);
      final notifier =
          container.read(audiobookshelfSettingsControllerProvider.notifier);
      await _settle();

      final ok = await notifier.signIn(
        url: 'audiobooks.example.com',
        username: 'alice',
        password: 'hunter2',
      );

      expect(ok, isTrue);
      final state = container.read(audiobookshelfSettingsControllerProvider);
      expect(state.phase, AudiobookshelfConnectionPhase.connected);
      expect(state.username, 'alice');

      final saved = await store.read();
      expect(saved, isNotNull);
      expect(saved!.accessToken, 'tok-1');
      // Only the session is stored — never the password.
      expect(saved.toJson().values.contains('hunter2'), isFalse);
      // And nothing secret rides in the state the UI renders.
      expect(state.statusMessage, isNot(contains('tok-1')));
      expect(state.statusMessage, isNot(contains('hunter2')));
    });

    test('reuses a status already confirmed for the same address', () async {
      final client = _signInReadyClient();
      final container = _container(client: client);
      final notifier =
          container.read(audiobookshelfSettingsControllerProvider.notifier);
      await _settle();

      await notifier.testConnection('audiobooks.example.com');
      await notifier.signIn(
        url: 'audiobooks.example.com',
        username: 'alice',
        password: 'hunter2',
      );

      expect(client.serverStatusCallCount, 1);
    });

    test('re-confirms the server when signing in to a different address',
        () async {
      final client = _signInReadyClient();
      final container = _container(client: client);
      final notifier =
          container.read(audiobookshelfSettingsControllerProvider.notifier);
      await _settle();

      await notifier.testConnection('audiobooks.example.com');
      await notifier.signIn(
        url: 'other.example.com',
        username: 'alice',
        password: 'hunter2',
      );

      expect(client.serverStatusCallCount, 2);
    });

    test('lists the account libraries once signed in', () async {
      final client = _signInReadyClient(
        libraries: const <AudiobookshelfLibraryDto>[
          AudiobookshelfLibraryDto(
            id: 'lib-1',
            name: 'Audiobooks',
            mediaType: 'book',
          ),
          AudiobookshelfLibraryDto(
            id: 'lib-2',
            name: 'Podcasts',
            mediaType: 'podcast',
          ),
        ],
      );
      final container = _container(client: client);
      final notifier =
          container.read(audiobookshelfSettingsControllerProvider.notifier);
      await _settle();

      await notifier.signIn(
        url: 'audiobooks.example.com',
        username: 'alice',
        password: 'hunter2',
      );
      await _settle();

      final state = container.read(audiobookshelfSettingsControllerProvider);
      expect(
        state.libraries.map((library) => library.name),
        <String>['Audiobooks', 'Podcasts'],
      );
      expect(state.isLoadingLibraries, isFalse);
    });

    test('signs in to a server older than 2.26 and lists its libraries',
        () async {
      // How 2.25.1 answers: no accessToken at sign-in, only the old token,
      // which it then takes as the bearer token.
      final List<String?> bearers = <String?>[];
      final client = HttpAudiobookshelfClient(
        httpClient: MockClient((http.Request request) async {
          switch (request.url.path) {
            case '/status':
              return _json(<String, dynamic>{
                'app': 'audiobookshelf',
                'serverVersion': '2.25.1',
                'isInit': true,
              });
            case '/login':
              return _json(<String, dynamic>{
                'user': <String, dynamic>{
                  'id': 'user-1',
                  'username': 'alice',
                  'token': 'legacy-jwt',
                },
                'userDefaultLibraryId': 'lib-1',
              });
            case '/api/libraries':
              bearers.add(request.headers['Authorization']);
              if (request.headers['Authorization'] != 'Bearer legacy-jwt') {
                return http.Response('', 401);
              }
              return _json(<String, dynamic>{
                'libraries': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'lib-1',
                    'name': 'Audiobooks',
                    'mediaType': 'book',
                  },
                ],
              });
          }
          return http.Response('', 404);
        }),
      );
      final store = InMemoryAudiobookshelfSessionStore();
      final container = ProviderContainer(
        overrides: <Override>[
          audiobookshelfClientProvider.overrideWithValue(client),
          audiobookshelfSessionStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);
      final notifier =
          container.read(audiobookshelfSettingsControllerProvider.notifier);
      await _settle();

      expect(await notifier.testConnection('audiobooks.example.com'), isTrue);
      final bool signedIn = await notifier.signIn(
        url: 'audiobooks.example.com',
        username: 'alice',
        password: 'hunter2',
      );
      await _settle();

      expect(signedIn, isTrue);
      final state = container.read(audiobookshelfSettingsControllerProvider);
      expect(state.phase, AudiobookshelfConnectionPhase.connected);
      expect(state.errorMessage, isNull);
      expect(
        state.libraries.map((library) => library.name),
        <String>['Audiobooks'],
      );
      expect(bearers, <String>['Bearer legacy-jwt']);
      expect((await store.read())!.refreshToken, isNull);
    });

    test('does not adopt a session the keyring refused to store', () async {
      final store = _UnusableKeyringStore(writeFailure: _unavailableWrite);
      final container = _container(client: _signInReadyClient(), store: store);
      final notifier =
          container.read(audiobookshelfSettingsControllerProvider.notifier);
      await _settle();

      final ok = await notifier.signIn(
        url: 'audiobooks.example.com',
        username: 'alice',
        password: 'hunter2',
      );

      expect(ok, isFalse);
      final state = container.read(audiobookshelfSettingsControllerProvider);
      expect(state.phase, AudiobookshelfConnectionPhase.disconnected);
      expect(state.errorMessage, isNotNull);
      expect(notifier.session, isNull);
    });

    test('keeps the current connection when a re-auth fails', () async {
      final client = _signInReadyClient();
      final container = _container(
        client: client,
        store: InMemoryAudiobookshelfSessionStore(initialSession: _session),
      );
      final notifier =
          container.read(audiobookshelfSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      client.authError = AudiobookshelfException.unauthorized();
      final ok = await notifier.signIn(
        url: 'audiobooks.example.com',
        username: 'alice',
        password: 'wrong',
      );

      expect(ok, isFalse);
      final state = container.read(audiobookshelfSettingsControllerProvider);
      expect(state.phase, AudiobookshelfConnectionPhase.connected);
      expect(state.errorMessage, isNotNull);
      expect(notifier.session, isNotNull);
    });
  });

  group('refreshLibraries', () {
    test('does nothing when not connected', () async {
      final client = _signInReadyClient();
      final container = _container(client: client);
      final notifier =
          container.read(audiobookshelfSettingsControllerProvider.notifier);
      await _settle();

      await notifier.refreshLibraries();

      expect(client.lastSession, isNull);
      expect(
        container.read(audiobookshelfSettingsControllerProvider).libraries,
        isEmpty,
      );
    });

    test('keeps the connection when the listing fails', () async {
      final client = _signInReadyClient();
      final container = _container(
        client: client,
        store: InMemoryAudiobookshelfSessionStore(initialSession: _session),
      );
      final notifier =
          container.read(audiobookshelfSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      client.librariesError = AudiobookshelfException.serverError(500);
      await notifier.refreshLibraries();

      final state = container.read(audiobookshelfSettingsControllerProvider);
      expect(state.phase, AudiobookshelfConnectionPhase.connected);
      expect(state.isLoadingLibraries, isFalse);
      expect(state.errorKind, AudiobookshelfErrorKind.serverError);
    });

    test('a later successful listing clears the earlier failure', () async {
      final client = _signInReadyClient(
        libraries: const <AudiobookshelfLibraryDto>[
          AudiobookshelfLibraryDto(id: 'lib-1', name: 'Audiobooks'),
        ],
      );
      final container = _container(
        client: client,
        store: InMemoryAudiobookshelfSessionStore(initialSession: _session),
      );
      final notifier =
          container.read(audiobookshelfSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      client.librariesError = AudiobookshelfException.serverError(500);
      await notifier.refreshLibraries();
      client.librariesError = null;
      await notifier.refreshLibraries();

      final state = container.read(audiobookshelfSettingsControllerProvider);
      expect(state.errorMessage, isNull);
      expect(state.errorKind, isNull);
      expect(state.libraries.single.name, 'Audiobooks');
    });
  });

  group('clear', () {
    test('signs out and forgets the session', () async {
      final store =
          InMemoryAudiobookshelfSessionStore(initialSession: _session);
      final container = _container(store: store);
      final notifier =
          container.read(audiobookshelfSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      await notifier.clear();

      expect(await store.read(), isNull);
      expect(notifier.session, isNull);
      final state = container.read(audiobookshelfSettingsControllerProvider);
      expect(state.phase, AudiobookshelfConnectionPhase.disconnected);
      expect(state.statusMessage, contains('Signed out'));
    });

    test('stays connected when the keyring refuses to delete', () async {
      final container = _container(
        store: _UnusableKeyringStore(
          initialSession: _session,
          clearFailure: _lockedDelete,
        ),
      );
      final notifier =
          container.read(audiobookshelfSettingsControllerProvider.notifier);
      await notifier.ensureLoaded();

      await notifier.clear();

      final state = container.read(audiobookshelfSettingsControllerProvider);
      expect(state.phase, AudiobookshelfConnectionPhase.connected);
      expect(state.errorMessage, isNotNull);
      expect(notifier.session, isNotNull);
    });
  });
}
