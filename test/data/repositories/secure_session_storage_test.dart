import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/repositories/secure_storage_exception.dart';
import 'package:linthra/data/repositories/secure_jellyfin_session_store.dart';
import 'package:linthra/data/repositories/secure_plex_session_store.dart';
import 'package:linthra/data/repositories/secure_session_storage.dart';
import 'package:linthra/data/repositories/secure_subsonic_session_store.dart';

/// The real plugin channel. `flutter_secure_storage_linux` registers no Dart
/// implementation of its own: on Linux the package talks to
/// `MethodChannelFlutterSecureStorage`, which is this channel, and the C++
/// plugin on the other side is a thin libsecret wrapper. Driving that channel
/// is therefore the closest a host test can get to the real Secret Service
/// path, and it keeps the failure semantics intact instead of stubbing out the
/// store the app actually calls.
const MethodChannel _channel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// Channels a plaintext fallback would have to go through. Nothing in the
/// credential path may touch them.
const MethodChannel _sharedPreferences =
    MethodChannel('plugins.flutter.io/shared_preferences');
const MethodChannel _pathProvider =
    MethodChannel('plugins.flutter.io/path_provider');

const JellyfinSession _jellyfin = JellyfinSession(
  baseUrl: 'https://jellyfin.example.com',
  userId: 'user-1',
  accessToken: 'jellyfin-token-do-not-leak',
  deviceId: 'device-1',
  userName: 'alice',
  serverName: 'Home',
);

const SubsonicSession _subsonic = SubsonicSession(
  baseUrl: 'https://navidrome.example.com',
  username: 'alice',
  salt: 'salt-do-not-leak',
  token: 'subsonic-token-do-not-leak',
  serverType: 'navidrome',
);

const PlexSession _plex = PlexSession(
  baseUrl: 'https://plex.example.com:32400',
  token: 'plex-token-do-not-leak',
  machineIdentifier: 'machine-abc',
  serverName: 'Living Room PMS',
);

/// The errors the Linux stack really produces, reproduced verbatim.
///
/// `flutter_secure_storage_linux` catches whatever libsecret threw and answers
/// the channel with `fl_method_error_response_new("Libsecret error", <text>)`,
/// so these are the exact `PlatformException`s Linthra sees when the Secret
/// Service is missing, locked, or blocked by a sandbox.
final PlatformException _noSecretService = PlatformException(
  code: 'Libsecret error',
  message: 'The name org.freedesktop.secrets was not provided by any '
      '.service files (org.freedesktop.DBus.Error.ServiceUnknown)',
);

/// The plugin's own keyring warm-up failing: a locked keyring, or an unlock
/// prompt the user dismissed.
final PlatformException _lockedKeyring = PlatformException(
  code: 'Libsecret error',
  message: 'Failed to unlock the keyring',
);

/// What a Flatpak's D-Bus proxy answers for a name the manifest does not
/// grant: the call is rejected rather than the service being absent.
final PlatformException _sandboxDenied = PlatformException(
  code: 'Libsecret error',
  message: 'GDBus.Error:org.freedesktop.DBus.Error.AccessDenied: '
      'Rejected send message',
);

/// A stand-in for the Secret Service behind the plugin channel.
///
/// It answers the same methods the C++ plugin does, with the same shapes: one
/// keyring item per key, `read` of an absent key returns null, and any
/// libsecret failure surfaces as a `PlatformException` from *every* method
/// (including `delete`, which the plugin cannot complete without first reading
/// the keyring back).
class _FakeKeyring {
  final Map<String, String> items = <String, String>{};
  final List<String> methods = <String>[];

  /// When set, every operation fails with it, the way libsecret fails when the
  /// service is missing, locked, or refused.
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
  late SecureSessionStorage storage;
  late List<String> fallbackChannelCalls;

  setUp(() {
    keyring = _FakeKeyring();
    storage = const SecureSessionStorage();
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

  group('SecureSessionStorage', () {
    test('writes, reads back, and deletes through the platform store',
        () async {
      await storage.write(key: 'k', value: 'v');
      expect(keyring.items['k'], 'v');

      expect(await storage.read(key: 'k'), 'v');

      await storage.delete(key: 'k');
      expect(keyring.items, isEmpty);
      expect(await storage.read(key: 'k'), isNull);
    });

    test('a missing Secret Service fails as unavailable on every operation',
        () async {
      keyring.failure = _noSecretService;

      for (final Future<void> Function() operation in <Future<void> Function()>[
        () => storage.read(key: 'k'),
        () => storage.write(key: 'k', value: 'v'),
        () => storage.delete(key: 'k'),
      ]) {
        await expectLater(
          operation(),
          throwsA(
            isA<SecureStorageException>().having(
              (SecureStorageException error) => error.failure,
              'failure',
              SecureStorageFailure.unavailable,
            ),
          ),
        );
      }
    });

    test('a locked keyring fails as locked, and says so', () async {
      keyring.failure = _lockedKeyring;

      await expectLater(
        storage.read(key: 'k'),
        throwsA(
          isA<SecureStorageException>()
              .having(
                (SecureStorageException error) => error.failure,
                'failure',
                SecureStorageFailure.locked,
              )
              .having(
                (SecureStorageException error) => error.operation,
                'operation',
                SecureStorageOperation.read,
              )
              .having(
                (SecureStorageException error) => error.remedy,
                'remedy',
                contains('Unlock'),
              ),
        ),
      );
    });

    test('a sandbox that denies the Secret Service name fails as denied',
        () async {
      keyring.failure = _sandboxDenied;

      await expectLater(
        storage.write(key: 'k', value: 'v'),
        throwsA(
          isA<SecureStorageException>().having(
            (SecureStorageException error) => error.failure,
            'failure',
            SecureStorageFailure.denied,
          ),
        ),
      );
    });

    test('an unrecognised platform error still fails safely, as unknown',
        () async {
      keyring.failure = PlatformException(
        code: 'Libsecret error',
        message: 'something libsecret has never said before',
      );

      await expectLater(
        storage.read(key: 'k'),
        throwsA(
          isA<SecureStorageException>().having(
            (SecureStorageException error) => error.failure,
            'failure',
            SecureStorageFailure.unknown,
          ),
        ),
      );
    });

    test('no secure-storage implementation at all reads as unavailable',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);

      await expectLater(
        storage.read(key: 'k'),
        throwsA(
          isA<SecureStorageException>().having(
            (SecureStorageException error) => error.failure,
            'failure',
            SecureStorageFailure.unavailable,
          ),
        ),
      );
    });

    test('the failure carries nothing from the platform error', () async {
      // A platform message that quotes back what was being stored is the
      // nightmare case: the exception must not carry it onward into a log, a
      // diagnostics report, or a crash reporter.
      keyring.failure = PlatformException(
        code: 'Libsecret error',
        message: 'could not store value jellyfin-token-do-not-leak',
        details: 'jellyfin-token-do-not-leak',
      );

      Object? thrown;
      try {
        await storage.write(key: 'k', value: 'jellyfin-token-do-not-leak');
      } catch (error) {
        thrown = error;
      }

      final SecureStorageException failure = thrown! as SecureStorageException;
      expect(failure.toString(), isNot(contains('jellyfin-token-do-not-leak')));
      expect(failure.remedy, isNot(contains('jellyfin-token-do-not-leak')));
      expect(failure.toString(), 'SecureStorageException(write: unknown)');
    });

    test('a failed write leaves nothing behind, anywhere', () async {
      keyring.failure = _noSecretService;

      await expectLater(
        storage.write(key: 'k', value: 'jellyfin-token-do-not-leak'),
        throwsA(isA<SecureStorageException>()),
      );

      // Not in the keyring (the write failed), and not in the two stores a
      // plaintext fallback would reach for instead.
      expect(keyring.items, isEmpty);
      expect(fallbackChannelCalls, isEmpty);
    });
  });

  group('provider session stores', () {
    test('Jellyfin: saves, restores after a restart, and signs out clean',
        () async {
      const SecureJellyfinSessionStore store = SecureJellyfinSessionStore();
      await store.write(_jellyfin);

      // The credential reached the platform store, and only it.
      expect(keyring.items.keys, <String>['jellyfin_session_v1']);
      expect(fallbackChannelCalls, isEmpty);

      // A restart is a fresh store instance reading the same keyring.
      const SecureJellyfinSessionStore afterRestart =
          SecureJellyfinSessionStore();
      expect(await afterRestart.read(), _jellyfin);
      expect((await afterRestart.read())!.accessToken, _jellyfin.accessToken);

      await afterRestart.clear();
      expect(keyring.items, isEmpty);
      expect(await afterRestart.read(), isNull);
    });

    test(
        'Navidrome/Subsonic: saves, restores after a restart, and signs out '
        'clean', () async {
      const SecureSubsonicSessionStore store = SecureSubsonicSessionStore();
      await store.write(_subsonic);
      expect(keyring.items.keys, <String>['subsonic_session_v1']);

      const SecureSubsonicSessionStore afterRestart =
          SecureSubsonicSessionStore();
      final SubsonicSession? restored = await afterRestart.read();
      expect(restored, _subsonic);
      expect(restored!.token, _subsonic.token);
      expect(restored.salt, _subsonic.salt);

      await afterRestart.clear();
      expect(keyring.items, isEmpty);
      expect(await afterRestart.read(), isNull);
    });

    test(
        'Subsonic legacy password sign-in: kept only in the keyring, restored '
        'after a restart, and gone after sign-out', () async {
      const SubsonicSession passwordSession = SubsonicSession.password(
        baseUrl: 'https://cloud.example.com/apps/music/subsonic',
        username: 'alice',
        password: 'app-password-do-not-leak',
        serverType: 'Nextcloud Music',
      );
      const SecureSubsonicSessionStore store = SecureSubsonicSessionStore();
      await store.write(passwordSession);
      expect(keyring.items.keys, <String>['subsonic_session_v1']);

      const SecureSubsonicSessionStore afterRestart =
          SecureSubsonicSessionStore();
      final SubsonicSession? restored = await afterRestart.read();
      expect(restored, passwordSession);
      expect(restored!.usesPassword, isTrue);

      await afterRestart.clear();
      expect(keyring.items, isEmpty);
      expect(await afterRestart.read(), isNull);
    });

    test('Plex: saves, restores after a restart, and signs out clean',
        () async {
      const SecurePlexSessionStore store = SecurePlexSessionStore();
      await store.write(_plex);
      expect(keyring.items.keys, <String>['plex_session_v1']);

      const SecurePlexSessionStore afterRestart = SecurePlexSessionStore();
      final PlexSession? restored = await afterRestart.read();
      expect(restored, _plex);
      expect(restored!.token, _plex.token);

      await afterRestart.clear();
      expect(keyring.items, isEmpty);
      expect(await afterRestart.read(), isNull);
    });

    test('a locked keyring is reported, not mistaken for a signed-out user',
        () async {
      // The important distinction: "there is no saved session" and "I could
      // not read the saved session" must not look the same, or a locked
      // keyring silently presents as a signed-out app and the next write
      // overwrites a credential that was fine.
      const SecureJellyfinSessionStore store = SecureJellyfinSessionStore();
      await store.write(_jellyfin);
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
      const SecurePlexSessionStore store = SecurePlexSessionStore();

      await expectLater(
          store.write(_plex), throwsA(isA<SecureStorageException>()));
      await expectLater(store.read(), throwsA(isA<SecureStorageException>()));
      await expectLater(store.clear(), throwsA(isA<SecureStorageException>()));

      expect(keyring.items, isEmpty);
      expect(fallbackChannelCalls, isEmpty);
    });

    test('a corrupt record still reads as signed out', () async {
      keyring.items['jellyfin_session_v1'] = 'not json';
      const SecureJellyfinSessionStore store = SecureJellyfinSessionStore();

      expect(await store.read(), isNull);
    });

    test('nothing but the provider key is read, written or deleted', () async {
      const SecureJellyfinSessionStore store = SecureJellyfinSessionStore();
      await store.write(_jellyfin);
      await store.read();
      await store.clear();

      // No readAll/deleteAll: Linthra touches its own keys and leaves the rest
      // of the user's keyring alone.
      expect(keyring.methods, <String>['write', 'read', 'delete']);
    });

    test('what is stored is the session JSON and nothing more', () async {
      const SecureJellyfinSessionStore store = SecureJellyfinSessionStore();
      await store.write(_jellyfin);

      final Object? stored = jsonDecode(keyring.items['jellyfin_session_v1']!);
      expect(stored, isA<Map<String, dynamic>>());
      expect(
        (stored! as Map<String, dynamic>).keys,
        containsAll(<String>['baseUrl', 'userId', 'accessToken']),
      );
    });
  });
}
