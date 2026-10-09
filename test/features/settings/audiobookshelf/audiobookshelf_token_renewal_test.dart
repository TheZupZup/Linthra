import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audiobookshelf_session.dart';
import 'package:linthra/core/repositories/audiobookshelf_session_store.dart';
import 'package:linthra/core/repositories/secure_storage_exception.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_api.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_exception.dart';
import 'package:linthra/data/repositories/audiobookshelf_session_store_provider.dart';
import 'package:linthra/features/audiobooks/audiobooks_library_controller.dart';
import 'package:linthra/features/audiobooks/audiobooks_library_state.dart';
import 'package:linthra/features/settings/audiobookshelf/audiobookshelf_settings_controller.dart';
import 'package:linthra/features/settings/audiobookshelf/audiobookshelf_settings_providers.dart';
import 'package:linthra/features/settings/audiobookshelf/audiobookshelf_settings_state.dart';

import '../../../core/sources/audiobookshelf/fake_audiobookshelf_client.dart';

// Signed in on Audiobookshelf 2.26 or later: the access token has expired,
// the refresh token is still good.
const _expired = AudiobookshelfSession(
  baseUrl: 'https://audiobooks.example.com',
  userId: 'user-1',
  accessToken: 'tok-1',
  refreshToken: 'refresh-1',
  userName: 'alice',
  defaultLibraryId: 'lib-books',
  serverVersion: '2.31.0',
);

const _renewal = AudiobookshelfAuthResult(
  userId: 'user-1',
  accessToken: 'tok-2',
  refreshToken: 'refresh-2',
  userName: 'alice',
);

const _bookLibrary = AudiobookshelfLibraryDto(
  id: 'lib-books',
  name: 'Audiobooks',
  mediaType: 'book',
);

const SecureStorageException _lockedWrite = SecureStorageException(
  operation: SecureStorageOperation.write,
  failure: SecureStorageFailure.locked,
);

/// A keyring that can be made to refuse writes, and that survives a
/// "restart" (a new container handed the same store).
class _Keyring implements AudiobookshelfSessionStore {
  _Keyring(this.saved);

  AudiobookshelfSession? saved;
  bool refuseWrites = false;
  int writes = 0;

  @override
  Future<AudiobookshelfSession?> read() async => saved;

  @override
  Future<void> write(AudiobookshelfSession session) async {
    writes++;
    if (refuseWrites) throw _lockedWrite;
    saved = session;
  }

  @override
  Future<void> clear() async {
    saved = null;
  }
}

/// A server whose access token [_expired] carries has run out.
FakeAudiobookshelfClient _server() {
  final client = FakeAudiobookshelfClient(
    libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
  )
    ..acceptedAccessTokens = <String>{}
    ..refreshResult = _renewal;
  return client;
}

Future<(ProviderContainer, AudiobookshelfSettingsController)> _start(
  FakeAudiobookshelfClient client,
  _Keyring keyring,
) async {
  final container = ProviderContainer(
    overrides: <Override>[
      audiobookshelfClientProvider.overrideWithValue(client),
      audiobookshelfSessionStoreProvider.overrideWithValue(keyring),
    ],
  );
  addTearDown(container.dispose);
  final AudiobookshelfSettingsController connection =
      container.read(audiobookshelfSettingsControllerProvider.notifier);
  await connection.ensureLoaded();
  return (container, connection);
}

Future<List<AudiobookshelfLibraryDto>> _listLibraries(
  AudiobookshelfSettingsController connection,
  FakeAudiobookshelfClient client,
) =>
    connection.authorized(connection.session!, client.fetchLibraries);

/// Every secret the tests hand out, for checking none of them leaks.
const List<String> _secrets = <String>[
  'tok-1',
  'tok-2',
  'refresh-1',
  'refresh-2',
];

void _expectNoSecret(String text) {
  for (final String secret in _secrets) {
    expect(text, isNot(contains(secret)));
  }
}

void main() {
  test(
      'an expired access token is renewed once, saved, and the request '
      'retried', () async {
    final FakeAudiobookshelfClient client = _server();
    final _Keyring keyring = _Keyring(_expired);
    final (ProviderContainer container, AudiobookshelfSettingsController c) =
        await _start(client, keyring);

    await c.refreshLibraries();

    final AudiobookshelfSettingsState state =
        container.read(audiobookshelfSettingsControllerProvider);
    expect(state.errorMessage, isNull);
    expect(state.libraries.single.id, 'lib-books');
    expect(client.refreshCalls, <String>['refresh-1']);
    expect(client.requestTokens, <String>['tok-1', 'tok-2']);
    // The new pair replaced the old one, on disk and in memory.
    expect(keyring.saved!.accessToken, 'tok-2');
    expect(keyring.saved!.refreshToken, 'refresh-2');
    expect(c.session!.accessToken, 'tok-2');
    expect(c.session!.isSameAccountAs(_expired), isTrue);
    expect(c.session!.userName, 'alice');
    expect(c.session!.serverVersion, '2.31.0');
  });

  test('a restart after a renewal goes straight to the saved pair', () async {
    final FakeAudiobookshelfClient client = _server();
    final _Keyring keyring = _Keyring(_expired);
    final (_, AudiobookshelfSettingsController first) =
        await _start(client, keyring);
    await _listLibraries(first, client);

    // Linthra restarts with the same keyring.
    final (_, AudiobookshelfSettingsController second) =
        await _start(client, keyring);
    client.requestTokens.clear();
    await _listLibraries(second, client);

    expect(client.requestTokens, <String>['tok-2']);
    expect(client.refreshCalls, <String>['refresh-1']);
  });

  test('ten requests that hit the expiry together share one renewal', () async {
    final FakeAudiobookshelfClient client = _server();
    final _Keyring keyring = _Keyring(_expired);
    final (_, AudiobookshelfSettingsController c) =
        await _start(client, keyring);

    final Completer<void> held = Completer<void>();
    client.refreshGate = held;
    final List<Future<List<AudiobookshelfLibraryDto>>> requests =
        <Future<List<AudiobookshelfLibraryDto>>>[
      for (int i = 0; i < 10; i++) _listLibraries(c, client),
    ];
    await pumpEventQueue();
    // Every request got its 401; one renewal is out for all of them.
    expect(client.refreshCalls, hasLength(1));

    held.complete();
    final List<List<AudiobookshelfLibraryDto>> answers =
        await Future.wait(requests);

    expect(answers, everyElement(hasLength(1)));
    expect(client.refreshCalls, <String>['refresh-1']);
    expect(keyring.writes, 1);
    expect(keyring.saved!.accessToken, 'tok-2');
  });

  test('two requests that hit the expiry together share one renewal', () async {
    final FakeAudiobookshelfClient client = _server();
    final _Keyring keyring = _Keyring(_expired);
    final (_, AudiobookshelfSettingsController c) =
        await _start(client, keyring);

    await Future.wait(<Future<Object?>>[
      _listLibraries(c, client),
      _listLibraries(c, client),
    ]);

    expect(client.refreshCalls, <String>['refresh-1']);
  });

  test('a 401 that lands after the renewal retries with the new tokens',
      () async {
    final FakeAudiobookshelfClient client = _server();
    final _Keyring keyring = _Keyring(_expired);
    final (_, AudiobookshelfSettingsController c) =
        await _start(client, keyring);

    // A slow request goes out with the old token and is still out while
    // another one renews.
    final Completer<void> slow = Completer<void>();
    final List<String> slowTokens = <String>[];
    final Future<String> late =
        c.authorized(c.session!, (AudiobookshelfSession session) async {
      slowTokens.add(session.accessToken);
      if (slowTokens.length == 1) await slow.future;
      await client.fetchLibraries(session);
      return session.accessToken;
    });
    await _listLibraries(c, client);
    expect(client.refreshCalls, <String>['refresh-1']);

    slow.complete();
    expect(await late, 'tok-2');
    // It retried with the tokens already renewed instead of trading in the
    // spent refresh token again.
    expect(slowTokens, <String>['tok-1', 'tok-2']);
    expect(client.refreshCalls, <String>['refresh-1']);
  });

  test('a retry that is turned down too does not loop', () async {
    final FakeAudiobookshelfClient client = _server();
    final _Keyring keyring = _Keyring(_expired);
    final (_, AudiobookshelfSettingsController c) =
        await _start(client, keyring);

    int attempts = 0;
    await expectLater(
      c.authorized(c.session!, (AudiobookshelfSession session) async {
        attempts++;
        throw AudiobookshelfException.unauthorized();
      }),
      throwsA(isA<AudiobookshelfException>().having(
          (AudiobookshelfException e) => e.kind,
          'kind',
          AudiobookshelfErrorKind.unauthorized)),
    );

    expect(attempts, 2);
    expect(client.refreshCalls, hasLength(1));
  });

  test('a refused refresh token asks for the password, and only once',
      () async {
    final FakeAudiobookshelfClient client = _server()
      ..refreshError = AudiobookshelfException.unauthorized();
    final _Keyring keyring = _Keyring(_expired);
    final (ProviderContainer container, AudiobookshelfSettingsController c) =
        await _start(client, keyring);

    await c.refreshLibraries();
    AudiobookshelfSettingsState state =
        container.read(audiobookshelfSettingsControllerProvider);
    expect(state.errorKind, AudiobookshelfErrorKind.unauthorized);
    expect(
        state.errorMessage, AudiobookshelfException.sessionExpired().message);
    // Still connected, so the card has no password field: the message says
    // to sign out first. The saved session is left as it was.
    expect(state.errorMessage, contains('Sign out in Settings, then sign in'));
    expect(state.phase, AudiobookshelfConnectionPhase.connected);
    expect(keyring.saved, _expired);

    // The next request doesn't trade the refused token in again.
    await c.refreshLibraries();
    state = container.read(audiobookshelfSettingsControllerProvider);
    expect(
        state.errorMessage, AudiobookshelfException.sessionExpired().message);
    expect(client.refreshCalls, <String>['refresh-1']);
  });

  test('a server older than 2.26 has no refresh token to try', () async {
    final FakeAudiobookshelfClient client = _server();
    final _Keyring keyring = _Keyring(const AudiobookshelfSession(
      baseUrl: 'https://audiobooks.example.com',
      userId: 'user-1',
      accessToken: 'tok-1',
      serverVersion: '2.17.0',
    ));
    final (ProviderContainer container, AudiobookshelfSettingsController c) =
        await _start(client, keyring);

    await c.refreshLibraries();

    expect(
      container.read(audiobookshelfSettingsControllerProvider).errorMessage,
      AudiobookshelfException.sessionExpired().message,
    );
    expect(client.refreshCalls, isEmpty);
  });

  test('a 403 is a missing permission, not an expired token', () async {
    final FakeAudiobookshelfClient client = _server();
    final _Keyring keyring = _Keyring(_expired);
    final (_, AudiobookshelfSettingsController c) =
        await _start(client, keyring);

    await expectLater(
      c.authorized(
        c.session!,
        (_) async => throw AudiobookshelfException.unauthorized(
          statusCode: 403,
        ),
      ),
      throwsA(isA<AudiobookshelfException>().having(
          (AudiobookshelfException e) => e.statusCode, 'statusCode', 403)),
    );
    expect(client.refreshCalls, isEmpty);
  });

  test('a renewal that cannot reach the server leaves the session alone',
      () async {
    final FakeAudiobookshelfClient client = _server()
      ..refreshError = AudiobookshelfException.notReachable();
    final _Keyring keyring = _Keyring(_expired);
    final (ProviderContainer container, AudiobookshelfSettingsController c) =
        await _start(client, keyring);

    await c.refreshLibraries();
    expect(
      container.read(audiobookshelfSettingsControllerProvider).errorKind,
      AudiobookshelfErrorKind.notReachable,
    );
    expect(keyring.saved, _expired);
    expect(c.session, _expired);

    // Back online: the same refresh token was never spent, so it works.
    client.refreshError = null;
    await c.refreshLibraries();
    expect(
      container.read(audiobookshelfSettingsControllerProvider).errorMessage,
      isNull,
    );
    expect(keyring.saved!.accessToken, 'tok-2');
  });

  group('a keyring that refuses the renewed pair', () {
    test(
        'the new tokens are used, the card says so, and a later request '
        'saves them', () async {
      final FakeAudiobookshelfClient client = _server();
      final _Keyring keyring = _Keyring(_expired)..refuseWrites = true;
      final (ProviderContainer container, AudiobookshelfSettingsController c) =
          await _start(client, keyring);

      final List<AudiobookshelfLibraryDto> libraries =
          await _listLibraries(c, client);

      expect(libraries.single.id, 'lib-books');
      expect(c.session!.accessToken, 'tok-2');
      expect(keyring.saved, _expired);
      final AudiobookshelfSettingsState state =
          container.read(audiobookshelfSettingsControllerProvider);
      expect(state.phase, AudiobookshelfConnectionPhase.connected);
      expect(state.errorMessage, contains('sign in again after restarting'));
      _expectNoSecret(state.errorMessage!);

      // Still refused: the request isn't held up or failed by it.
      await _listLibraries(c, client);
      await pumpEventQueue();
      expect(keyring.saved, _expired);

      keyring.refuseWrites = false;
      await _listLibraries(c, client);
      await pumpEventQueue();
      expect(keyring.saved!.accessToken, 'tok-2');
      expect(keyring.saved!.refreshToken, 'refresh-2');
      expect(client.refreshCalls, <String>['refresh-1']);
    });

    test(
        'the warning outlives the library refresh that renewed, until the '
        'pair is saved', () async {
      final FakeAudiobookshelfClient client = _server();
      final _Keyring keyring = _Keyring(_expired)..refuseWrites = true;
      final (ProviderContainer container, AudiobookshelfSettingsController c) =
          await _start(client, keyring);

      // The refresh is what hits the expiry, renews, and then succeeds.
      await c.refreshLibraries();
      AudiobookshelfSettingsState state =
          container.read(audiobookshelfSettingsControllerProvider);
      expect(state.libraries.single.id, 'lib-books');
      expect(state.errorMessage, contains('sign in again after restarting'));

      // Another refresh that works, with the pair still unsaved.
      await c.refreshLibraries();
      await pumpEventQueue();
      state = container.read(audiobookshelfSettingsControllerProvider);
      expect(state.errorMessage, contains('sign in again after restarting'));

      keyring.refuseWrites = false;
      await c.refreshLibraries();
      await pumpEventQueue();
      expect(keyring.saved!.accessToken, 'tok-2');
      state = container.read(audiobookshelfSettingsControllerProvider);
      expect(state.errorMessage, isNull);
    });

    test('a refresh that fails meanwhile shows its error beside the warning',
        () async {
      final FakeAudiobookshelfClient client = _server();
      final _Keyring keyring = _Keyring(_expired)..refuseWrites = true;
      final (ProviderContainer container, AudiobookshelfSettingsController c) =
          await _start(client, keyring);
      await c.refreshLibraries();

      // The pair is still unsaved when the next refresh can't get through.
      client.librariesError = AudiobookshelfException.notReachable();
      await c.refreshLibraries();
      await pumpEventQueue();

      final AudiobookshelfSettingsState state =
          container.read(audiobookshelfSettingsControllerProvider);
      expect(
        state.errorMessage,
        contains(AudiobookshelfException.notReachable().message),
      );
      expect(state.errorMessage, contains('sign in again after restarting'));
      expect(state.errorKind, AudiobookshelfErrorKind.notReachable);
      _expectNoSecret(state.errorMessage!);
    });

    test('once the pair is saved, only the warning leaves that error',
        () async {
      final FakeAudiobookshelfClient client = _server();
      final _Keyring keyring = _Keyring(_expired)..refuseWrites = true;
      final (ProviderContainer container, AudiobookshelfSettingsController c) =
          await _start(client, keyring);
      await c.refreshLibraries();
      client.librariesError = AudiobookshelfException.notReachable();
      await c.refreshLibraries();
      await pumpEventQueue();

      // The keyring is back, and a request from the audiobook browser is what
      // gets the pair saved.
      keyring.refuseWrites = false;
      client.librariesError = null;
      await _listLibraries(c, client);
      await pumpEventQueue();

      expect(keyring.saved!.accessToken, 'tok-2');
      final AudiobookshelfSettingsState state =
          container.read(audiobookshelfSettingsControllerProvider);
      expect(
        state.errorMessage,
        AudiobookshelfException.notReachable().message,
      );
      expect(state.errorKind, AudiobookshelfErrorKind.notReachable);
    });

    test(
        'a restart before it is saved asks for the password rather than '
        'failing quietly', () async {
      final FakeAudiobookshelfClient client = _server();
      final _Keyring keyring = _Keyring(_expired)..refuseWrites = true;
      final (_, AudiobookshelfSettingsController first) =
          await _start(client, keyring);
      await _listLibraries(first, client);

      // The old pair is what the disk has. On 2.26 its refresh token died
      // with the renewal.
      final (ProviderContainer container, AudiobookshelfSettingsController c) =
          await _start(client, keyring);
      await c.refreshLibraries();

      expect(
        container.read(audiobookshelfSettingsControllerProvider).errorMessage,
        AudiobookshelfException.sessionExpired().message,
      );
      expect(client.refreshCalls, <String>['refresh-1', 'refresh-1']);
    });
  });

  test('a sign-out while the server renews keeps the account off the disk',
      () async {
    final FakeAudiobookshelfClient client = _server();
    final _Keyring keyring = _Keyring(_expired);
    final (_, AudiobookshelfSettingsController c) =
        await _start(client, keyring);

    final Completer<void> held = Completer<void>();
    client.refreshGate = held;
    final Future<List<AudiobookshelfLibraryDto>> request =
        _listLibraries(c, client);
    await pumpEventQueue();
    expect(client.refreshCalls, hasLength(1));

    await c.clear();
    held.complete();
    await expectLater(request, throwsA(isA<AudiobookshelfException>()));
    await pumpEventQueue();

    expect(c.session, isNull);
    expect(keyring.saved, isNull);
  });

  test(
      'another account signed in while the server renews keeps its own '
      'tokens', () async {
    final FakeAudiobookshelfClient client = _server()
      ..serverStatus = const AudiobookshelfServerStatus(
        serverVersion: '2.31.0',
        isInitialized: true,
      )
      ..authResult = const AudiobookshelfAuthResult(
        userId: 'user-2',
        accessToken: 'bob-tok',
        refreshToken: 'bob-refresh',
        userName: 'bob',
      );
    final _Keyring keyring = _Keyring(_expired);
    final (_, AudiobookshelfSettingsController c) =
        await _start(client, keyring);

    final Completer<void> held = Completer<void>();
    client.refreshGate = held;
    final Future<List<AudiobookshelfLibraryDto>> request =
        _listLibraries(c, client);
    await pumpEventQueue();

    await c.clear();
    await c.signIn(
      url: 'https://audiobooks.example.com',
      username: 'bob',
      password: 'hunter2',
    );
    held.complete();
    await expectLater(request, throwsA(isA<AudiobookshelfException>()));
    await pumpEventQueue();

    expect(c.session!.userId, 'user-2');
    expect(c.session!.accessToken, 'bob-tok');
    expect(keyring.saved!.accessToken, 'bob-tok');
  });

  test('renewed tokens for another user are never adopted', () async {
    final FakeAudiobookshelfClient client = _server()
      ..refreshResult = const AudiobookshelfAuthResult(
        userId: 'user-9',
        accessToken: 'tok-9',
        refreshToken: 'refresh-9',
      );
    final _Keyring keyring = _Keyring(_expired);
    final (_, AudiobookshelfSettingsController c) =
        await _start(client, keyring);

    await expectLater(
      _listLibraries(c, client),
      throwsA(isA<AudiobookshelfException>()),
    );
    expect(c.session, _expired);
    expect(keyring.saved, _expired);
  });

  test('no token reaches an error the user can see', () async {
    final FakeAudiobookshelfClient client = _server()
      ..refreshError = AudiobookshelfException.unauthorized();
    final _Keyring keyring = _Keyring(_expired);
    final (ProviderContainer container, AudiobookshelfSettingsController c) =
        await _start(client, keyring);

    Object? caught;
    try {
      await _listLibraries(c, client);
    } catch (error) {
      caught = error;
    }
    _expectNoSecret('$caught');
    await c.refreshLibraries();
    final AudiobookshelfSettingsState state =
        container.read(audiobookshelfSettingsControllerProvider);
    _expectNoSecret('${state.errorMessage} ${state.statusMessage}');
    _expectNoSecret('${c.session}');
  });

  test(
      "a listing from before a sign-out doesn't land on the next sign-in, "
      'even to the same account', () async {
    final FakeAudiobookshelfClient client = FakeAudiobookshelfClient(
      libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
      serverStatus: const AudiobookshelfServerStatus(
        serverVersion: '2.31.0',
        isInitialized: true,
      ),
      authResult: const AudiobookshelfAuthResult(
        userId: 'user-1',
        accessToken: 'tok-3',
        refreshToken: 'refresh-3',
        userName: 'alice',
      ),
    );
    final (ProviderContainer container, AudiobookshelfSettingsController c) =
        await _start(client, _Keyring(_expired));

    // A listing for the first sign-in is still out when the user signs out
    // and back in.
    final Completer<void> slow = Completer<void>();
    client.librariesGate = slow;
    final Future<void> stale = c.refreshLibraries();
    await pumpEventQueue();
    await c.clear();
    client.librariesGate = null;
    expect(
      await c.signIn(
        url: 'https://audiobooks.example.com',
        username: 'alice',
        password: 'hunter2',
      ),
      isTrue,
    );
    await pumpEventQueue();

    // Then the old one fails.
    client.librariesError = AudiobookshelfException.notReachable();
    slow.complete();
    await stale;

    final AudiobookshelfSettingsState state =
        container.read(audiobookshelfSettingsControllerProvider);
    expect(state.phase, AudiobookshelfConnectionPhase.connected);
    expect(state.errorMessage, isNull);
    expect(state.libraries.single.id, 'lib-books');
  });

  group('the audiobook browser', () {
    test('keeps loading across a renewal', () async {
      final FakeAudiobookshelfClient client = _server();
      client.itemsByLibrary['lib-books'] = <AudiobookshelfLibraryItemDto>[
        for (int i = 0; i < AudiobooksLibraryController.pageSize + 3; i++)
          AudiobookshelfLibraryItemDto(id: 'item-$i', title: 'Book $i'),
      ];
      final _Keyring keyring = _Keyring(_expired);
      final (ProviderContainer container, _) = await _start(client, keyring);
      final AudiobooksLibraryController browser =
          container.read(audiobooksLibraryControllerProvider.notifier);

      await browser.load();
      AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      // Renewed on the library list; the page that followed used the new
      // token, and the response wasn't mistaken for another account's.
      expect(state.errorMessage, isNull);
      expect(state.books, hasLength(AudiobooksLibraryController.pageSize));
      expect(state.hasMore, isTrue);

      await browser.loadMore();
      state = container.read(audiobooksLibraryControllerProvider);
      expect(state.books, hasLength(AudiobooksLibraryController.pageSize + 3));
      expect(client.refreshCalls, <String>['refresh-1']);
      expect(
        client.requestTokens,
        <String>['tok-1', 'tok-2', 'tok-2', 'tok-2'],
      );

      // Reopening the screen is not a different account: nothing reloads.
      await browser.load();
      expect(client.itemRequests, hasLength(2));
    });

    test('a page whose token expires mid-scroll is renewed, not dropped',
        () async {
      final FakeAudiobookshelfClient client = _server()
        ..acceptedAccessTokens = <String>{'tok-1'};
      client.itemsByLibrary['lib-books'] = <AudiobookshelfLibraryItemDto>[
        for (int i = 0; i < AudiobooksLibraryController.pageSize + 3; i++)
          AudiobookshelfLibraryItemDto(id: 'item-$i', title: 'Book $i'),
      ];
      final _Keyring keyring = _Keyring(_expired);
      final (ProviderContainer container, _) = await _start(client, keyring);
      final AudiobooksLibraryController browser =
          container.read(audiobooksLibraryControllerProvider.notifier);
      await browser.load();

      // The access token runs out between two pages.
      client.acceptedAccessTokens!.remove('tok-1');
      await browser.loadMore();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.errorMessage, isNull);
      expect(state.isLoadingMore, isFalse);
      expect(state.books, hasLength(AudiobooksLibraryController.pageSize + 3));
    });

    test('a refused renewal shows the sign-in prompt and keeps the books',
        () async {
      final FakeAudiobookshelfClient client = _server()
        ..acceptedAccessTokens = <String>{'tok-1'}
        ..refreshError = AudiobookshelfException.unauthorized();
      client.itemsByLibrary['lib-books'] = <AudiobookshelfLibraryItemDto>[
        for (int i = 0; i < AudiobooksLibraryController.pageSize + 3; i++)
          AudiobookshelfLibraryItemDto(id: 'item-$i', title: 'Book $i'),
      ];
      final _Keyring keyring = _Keyring(_expired);
      final (ProviderContainer container, _) = await _start(client, keyring);
      final AudiobooksLibraryController browser =
          container.read(audiobooksLibraryControllerProvider.notifier);
      await browser.load();

      client.acceptedAccessTokens!.clear();
      await browser.loadMore();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.errorKind, AudiobookshelfErrorKind.unauthorized);
      expect(state.books, hasLength(AudiobooksLibraryController.pageSize));
      expect(state.isLoadingMore, isFalse);
    });

    test(
        'signing out and back in to the same account loads the books again, '
        'even with the browser closed in between', () async {
      // Renewed tokens keep what was loaded. A new sign-in doesn't: it is
      // how a user picks up a library the server changed for them.
      final FakeAudiobookshelfClient client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
        serverStatus: const AudiobookshelfServerStatus(
          serverVersion: '2.31.0',
          isInitialized: true,
        ),
        authResult: const AudiobookshelfAuthResult(
          userId: 'user-1',
          accessToken: 'tok-3',
          refreshToken: 'refresh-3',
          userName: 'alice',
          defaultLibraryId: 'lib-books',
        ),
      );
      client.itemsByLibrary['lib-books'] = <AudiobookshelfLibraryItemDto>[
        const AudiobookshelfLibraryItemDto(id: 'item-a', title: 'Book A'),
      ];
      final (ProviderContainer container, AudiobookshelfSettingsController c) =
          await _start(client, _Keyring(_expired));
      final AudiobooksLibraryController browser =
          container.read(audiobooksLibraryControllerProvider.notifier);
      await browser.load();
      expect(
        container.read(audiobooksLibraryControllerProvider).books,
        hasLength(1),
      );

      await c.clear();
      client.itemsByLibrary['lib-books'] = <AudiobookshelfLibraryItemDto>[
        const AudiobookshelfLibraryItemDto(id: 'item-a', title: 'Book A'),
        const AudiobookshelfLibraryItemDto(id: 'item-b', title: 'Book B'),
      ];
      expect(
        await c.signIn(
          url: 'https://audiobooks.example.com',
          username: 'alice',
          password: 'hunter2',
        ),
        isTrue,
      );
      expect(c.session!.isSameAccountAs(_expired), isTrue);

      await browser.load();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.books.map((AudiobookSummary book) => book.title), <String>[
        'Book A',
        'Book B',
      ]);
      expect(client.requestTokens.last, 'tok-3');
    });
  });
}
