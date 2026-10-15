import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audiobookshelf_session.dart';
import 'package:linthra/core/repositories/secure_storage_exception.dart';
import 'package:linthra/data/repositories/secure_audiobookshelf_session_store.dart';

// The Audiobookshelf session holds two secrets, an access token and a refresh
// token, and the production store keeps them in the platform keyring through
// SecureSessionStorage. The Jellyfin, Subsonic and Plex stores are driven
// through that keyring channel in secure_session_storage_test.dart; this does
// the same for Audiobookshelf: both tokens go to the keyring under the one
// provider key and nowhere else, survive a restart, are removed on sign-out,
// and a keyring that cannot be read is reported rather than mistaken for a
// signed-out user. Fixtures mirror secure_session_storage_test.dart.

/// The real plugin channel (see secure_session_storage_test.dart for why the
/// channel, and not the plugin class, is what these tests drive).
const MethodChannel _channel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// Channels a plaintext fallback would have to go through. Nothing in the
/// credential path may touch them.
const MethodChannel _sharedPreferences =
    MethodChannel('plugins.flutter.io/shared_preferences');
const MethodChannel _pathProvider =
    MethodChannel('plugins.flutter.io/path_provider');

const String _key = 'audiobookshelf_session_v1';

const AudiobookshelfSession _session = AudiobookshelfSession(
  baseUrl: 'https://audiobooks.example.com',
  userId: 'user-1',
  accessToken: 'abs-access-token-do-not-leak',
  refreshToken: 'abs-refresh-token-do-not-leak',
  userName: 'alice',
  defaultLibraryId: 'lib-1',
  serverVersion: '2.26.0',
);

/// The plugin's keyring warm-up failing: a locked keyring, or an unlock
/// prompt the user dismissed. Verbatim from the Linux plugin.
final PlatformException _lockedKeyring = PlatformException(
  code: 'Libsecret error',
  message: 'Failed to unlock the keyring',
);

/// A Secret Service that is not there at all.
final PlatformException _noSecretService = PlatformException(
  code: 'Libsecret error',
  message: 'The name org.freedesktop.secrets was not provided by any '
      '.service files (org.freedesktop.DBus.Error.ServiceUnknown)',
);

/// A stand-in for the Secret Service behind the plugin channel: one keyring
/// item per key, `read` of an absent key returns null, and a libsecret failure
/// surfaces as a `PlatformException` from every method.
class _FakeKeyring {
  final Map<String, String> items = <String, String>{};
  final List<String> methods = <String>[];

  PlatformException? failure;

  Future<Object?> handle(MethodCall call) async {
    methods.add(call.method);
    final PlatformException? error = failure;
    if (error != null) {
      throw error;
    }
    final Map<Object?, Object?> arguments =
        (call.arguments as Map<Object?, Object?>?) ?? <Object?, Object?>{};
    final String? key = arguments['key'] as String?;
    switch (call.method) {
      case 'read':
        return items[key];
      case 'write':
        items[key!] = arguments['value']! as String;
        return null;
      case 'delete':
        items.remove(key);
        return null;
      case 'containsKey':
        return items.containsKey(key);
      default:
        throw MissingPluginException('unexpected method ${call.method}');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeKeyring keyring;
  late List<String> fallbackChannelCalls;

  setUp(() {
    keyring = _FakeKeyring();
    fallbackChannelCalls = <String>[];
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, keyring.handle);
    for (final MethodChannel channel in <MethodChannel>[
      _sharedPreferences,
      _pathProvider,
    ]) {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        fallbackChannelCalls.add('${channel.name}#${call.method}');
        return null;
      });
    }
  });

  tearDown(() {
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final MethodChannel channel in <MethodChannel>[
      _channel,
      _sharedPreferences,
      _pathProvider,
    ]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  group('SecureAudiobookshelfSessionStore through the keyring channel', () {
    test('both tokens reach the keyring under the provider key, and only it',
        () async {
      const SecureAudiobookshelfSessionStore store =
          SecureAudiobookshelfSessionStore();
      await store.write(_session);

      expect(keyring.items.keys, <String>[_key]);
      expect(fallbackChannelCalls, isEmpty);

      final Map<String, dynamic> stored =
          jsonDecode(keyring.items[_key]!) as Map<String, dynamic>;
      expect(stored['accessToken'], _session.accessToken);
      expect(stored['refreshToken'], _session.refreshToken);
    });

    test('a fresh instance restores the session with both tokens', () async {
      const SecureAudiobookshelfSessionStore store =
          SecureAudiobookshelfSessionStore();
      await store.write(_session);

      // A restart is a fresh store instance reading the same keyring.
      const SecureAudiobookshelfSessionStore afterRestart =
          SecureAudiobookshelfSessionStore();
      final AudiobookshelfSession? restored = await afterRestart.read();

      expect(restored, _session);
      expect(restored!.accessToken, _session.accessToken);
      expect(restored.refreshToken, _session.refreshToken);
      expect(fallbackChannelCalls, isEmpty);
    });

    test('clear() signs out clean', () async {
      const SecureAudiobookshelfSessionStore store =
          SecureAudiobookshelfSessionStore();
      await store.write(_session);

      await store.clear();

      expect(keyring.items, isEmpty);
      expect(await store.read(), isNull);
      // Only its own key: no readAll/deleteAll over the user's keyring.
      expect(keyring.methods, <String>['write', 'delete', 'read']);
    });

    test('a locked keyring is reported, not mistaken for a signed-out user',
        () async {
      const SecureAudiobookshelfSessionStore store =
          SecureAudiobookshelfSessionStore();
      await store.write(_session);
      keyring.failure = _lockedKeyring;

      await expectLater(
        store.read(),
        throwsA(
          isA<SecureStorageException>().having(
            (SecureStorageException error) => error.failure,
            'failure',
            SecureStorageFailure.locked,
          ),
        ),
      );
    });

    test('an unavailable Secret Service fails every operation, storing nothing',
        () async {
      keyring.failure = _noSecretService;
      const SecureAudiobookshelfSessionStore store =
          SecureAudiobookshelfSessionStore();

      await expectLater(
          store.write(_session), throwsA(isA<SecureStorageException>()));
      await expectLater(store.read(), throwsA(isA<SecureStorageException>()));
      await expectLater(store.clear(), throwsA(isA<SecureStorageException>()));

      expect(keyring.items, isEmpty);
      expect(fallbackChannelCalls, isEmpty);
    });

    test('a write failure carries neither token onward', () async {
      keyring.failure = PlatformException(
        code: 'Libsecret error',
        message: 'could not store ${_session.accessToken}',
        details: _session.refreshToken,
      );
      const SecureAudiobookshelfSessionStore store =
          SecureAudiobookshelfSessionStore();

      Object? thrown;
      try {
        await store.write(_session);
      } catch (error) {
        thrown = error;
      }

      expect(thrown, isA<SecureStorageException>());
      expect(thrown.toString(), isNot(contains(_session.accessToken)));
      expect(thrown.toString(), isNot(contains(_session.refreshToken!)));
    });

    test('a corrupt record reads as signed out', () async {
      const SecureAudiobookshelfSessionStore store =
          SecureAudiobookshelfSessionStore();
      for (final String corrupt in <String>[
        'not json',
        '[]',
        '{"baseUrl":"https://audiobooks.example.com"}',
        '{"baseUrl":"https://a.example.com","userId":"u","accessToken":7}',
      ]) {
        keyring.items[_key] = corrupt;

        expect(await store.read(), isNull, reason: corrupt);
      }
    });
  });
}
