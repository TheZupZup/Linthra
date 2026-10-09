import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:linthra/core/services/local_network/local_network_access.dart';
import 'package:linthra/core/services/local_network/local_network_permission.dart';

/// A scripted Android permission: [status] is what Android reports, and each
/// [request] answers with the next entry of [answers] (and records itself).
class FakeLocalNetworkPermission implements LocalNetworkPermission {
  FakeLocalNetworkPermission(this.current,
      {List<LocalNetworkPermissionStatus>? answers})
      : answers = answers ?? <LocalNetworkPermissionStatus>[];

  LocalNetworkPermissionStatus current;
  final List<LocalNetworkPermissionStatus> answers;
  int statusReads = 0;
  int requests = 0;
  int settingsOpened = 0;
  Completer<void>? gate;

  @override
  Future<LocalNetworkPermissionStatus> status() async {
    statusReads++;
    return current;
  }

  @override
  Future<LocalNetworkPermissionStatus> request() async {
    requests++;
    final Completer<void>? wait = gate;
    if (wait != null) await wait.future;
    if (answers.isNotEmpty) current = answers.removeAt(0);
    return current;
  }

  @override
  Future<void> openAppSettings() async => settingsOpened++;
}

/// Resolves the hosts these tests use without touching real DNS.
Future<List<InternetAddress>> fakeLookup(String host) async {
  lookups.add(host);
  switch (host) {
    case 'jellyfin.home.example':
      return <InternetAddress>[InternetAddress('192.168.1.20')];
    case 'music.example.com':
      return <InternetAddress>[InternetAddress('203.0.113.7')];
  }
  throw const SocketException('no such host');
}

final List<String> lookups = <String>[];

final Uri lanServer = Uri.parse('http://192.168.1.20:8096');
final Uri lanByName = Uri.parse('https://jellyfin.home.example');
final Uri internetServer = Uri.parse('https://music.example.com');

LocalNetworkAccess accessWith(
  FakeLocalNetworkPermission permission, {
  bool Function()? visible,
  void Function()? onGranted,
  DateTime Function()? now,
  bool vpn = false,
}) =>
    LocalNetworkAccess(
      permission: permission,
      lookup: fakeLookup,
      isVpnUp: () async => vpn,
      isAppVisible: visible,
      onGranted: onGranted,
      now: now,
    );

void main() {
  setUp(lookups.clear);

  group('where the permission does not apply', () {
    test('nothing is blocked, asked or even looked up', () async {
      for (final LocalNetworkPermissionStatus status
          in <LocalNetworkPermissionStatus>[
        LocalNetworkPermissionStatus.notRequired,
        LocalNetworkPermissionStatus.granted,
        LocalNetworkPermissionStatus.unknown,
      ]) {
        final FakeLocalNetworkPermission permission =
            FakeLocalNetworkPermission(status);
        final LocalNetworkAccess access = accessWith(permission);
        expect(
          await access.blockerFor(lanServer,
              prompt: LocalNetworkPrompt.userAction),
          isNull,
          reason: status.name,
        );
        expect(permission.requests, 0, reason: status.name);
      }
      expect(lookups, isEmpty,
          reason: 'before Android 17 a check must cost nothing');
    });

    test('"not required" is read from Android once and kept', () async {
      final FakeLocalNetworkPermission permission =
          FakeLocalNetworkPermission(LocalNetworkPermissionStatus.notRequired);
      final LocalNetworkAccess access = accessWith(permission);
      for (int i = 0; i < 5; i++) {
        await access.blockerFor(lanServer);
      }
      access.onAppShown();
      await access.blockerFor(lanServer);
      expect(permission.statusReads, 1);
    });

    test('"unknown" (no activity yet) is asked again next time', () async {
      final FakeLocalNetworkPermission permission =
          FakeLocalNetworkPermission(LocalNetworkPermissionStatus.unknown);
      final LocalNetworkAccess access = accessWith(permission);
      await access.blockerFor(lanServer);
      permission.current = LocalNetworkPermissionStatus.denied;
      expect(await access.blockerFor(lanServer),
          LocalNetworkPermissionStatus.denied);
    });
  });

  group('on Android 17 without the permission', () {
    test('an internet server is never blocked and never prompts', () async {
      final FakeLocalNetworkPermission permission = FakeLocalNetworkPermission(
          LocalNetworkPermissionStatus.notRequested,
          answers: <LocalNetworkPermissionStatus>[
            LocalNetworkPermissionStatus.granted,
          ]);
      final LocalNetworkAccess access = accessWith(permission);
      expect(
          await access.blockerFor(internetServer,
              prompt: LocalNetworkPrompt.userAction),
          isNull);
      expect(permission.requests, 0);
    });

    test('an address that does not resolve is let through to fail on its own',
        () async {
      final FakeLocalNetworkPermission permission =
          FakeLocalNetworkPermission(LocalNetworkPermissionStatus.denied);
      final LocalNetworkAccess access = accessWith(permission);
      expect(
          await access.blockerFor(Uri.parse('http://typo.invalid'),
              prompt: LocalNetworkPrompt.userAction),
          isNull);
      expect(permission.requests, 0);
    });

    test('a LAN server is blocked without a prompt from background work',
        () async {
      final FakeLocalNetworkPermission permission =
          FakeLocalNetworkPermission(LocalNetworkPermissionStatus.notRequested);
      final LocalNetworkAccess access = accessWith(permission);
      expect(await access.blockerFor(lanServer),
          LocalNetworkPermissionStatus.notRequested);
      expect(await access.blockerFor(lanByName),
          LocalNetworkPermissionStatus.notRequested,
          reason: 'a name that resolves to the LAN is the LAN too');
      expect(permission.requests, 0,
          reason: 'a sync or a probe must never raise a dialog');
    });

    test('a user action asks, and a grant lets the connection go ahead',
        () async {
      int grants = 0;
      final FakeLocalNetworkPermission permission = FakeLocalNetworkPermission(
          LocalNetworkPermissionStatus.notRequested,
          answers: <LocalNetworkPermissionStatus>[
            LocalNetworkPermissionStatus.granted,
          ]);
      final LocalNetworkAccess access =
          accessWith(permission, onGranted: () => grants++);
      expect(
          await access.blockerFor(lanServer,
              prompt: LocalNetworkPrompt.userAction),
          isNull);
      expect(permission.requests, 1);
      expect(grants, 1, reason: 'whatever was held back gets to retry');
      // And it is remembered: nothing is asked again.
      expect(await access.blockerFor(lanServer), isNull);
      expect(permission.requests, 1);
    });

    test('a refusal blocks, and a later user action may ask again', () async {
      final FakeLocalNetworkPermission permission = FakeLocalNetworkPermission(
          LocalNetworkPermissionStatus.notRequested,
          answers: <LocalNetworkPermissionStatus>[
            LocalNetworkPermissionStatus.denied,
            LocalNetworkPermissionStatus.granted,
          ]);
      final LocalNetworkAccess access = accessWith(permission);
      expect(
          await access.blockerFor(lanServer,
              prompt: LocalNetworkPrompt.userAction),
          LocalNetworkPermissionStatus.denied);
      expect(
          await access.blockerFor(lanServer,
              prompt: LocalNetworkPrompt.userAction),
          isNull,
          reason: 'granted after an earlier denial');
      expect(permission.requests, 2);
    });

    test('a permanent refusal never asks; it can only point at settings',
        () async {
      final FakeLocalNetworkPermission permission = FakeLocalNetworkPermission(
          LocalNetworkPermissionStatus.permanentlyDenied);
      final LocalNetworkAccess access = accessWith(permission);
      expect(
          await access.blockerFor(lanServer,
              prompt: LocalNetworkPrompt.userAction),
          LocalNetworkPermissionStatus.permanentlyDenied);
      expect(permission.requests, 0);
      await access.openAppSettings();
      expect(permission.settingsOpened, 1);
    });

    test('playback asks at most once per session', () async {
      final FakeLocalNetworkPermission permission = FakeLocalNetworkPermission(
          LocalNetworkPermissionStatus.notRequested,
          answers: <LocalNetworkPermissionStatus>[
            LocalNetworkPermissionStatus.denied,
            LocalNetworkPermissionStatus.granted,
          ]);
      final LocalNetworkAccess access = accessWith(permission);
      for (int i = 0; i < 4; i++) {
        expect(
            await access.blockerFor(lanServer,
                prompt: LocalNetworkPrompt.oncePerSession),
            LocalNetworkPermissionStatus.denied);
      }
      expect(permission.requests, 1,
          reason: 'every track of a queue must not re-ask');
    });

    test('nothing is asked while the app is off screen', () async {
      bool visible = false;
      final FakeLocalNetworkPermission permission = FakeLocalNetworkPermission(
          LocalNetworkPermissionStatus.notRequested,
          answers: <LocalNetworkPermissionStatus>[
            LocalNetworkPermissionStatus.granted,
          ]);
      final LocalNetworkAccess access =
          accessWith(permission, visible: () => visible);
      // Android Auto or a headset starts a LAN track with the phone locked.
      expect(
          await access.blockerFor(lanServer,
              prompt: LocalNetworkPrompt.oncePerSession),
          LocalNetworkPermissionStatus.notRequested);
      expect(permission.requests, 0);
      // The once-per-session prompt was not spent on it.
      visible = true;
      expect(
          await access.blockerFor(lanServer,
              prompt: LocalNetworkPrompt.oncePerSession),
          isNull);
      expect(permission.requests, 1);
    });

    test('overlapping checks share one dialog', () async {
      final FakeLocalNetworkPermission permission = FakeLocalNetworkPermission(
          LocalNetworkPermissionStatus.notRequested,
          answers: <LocalNetworkPermissionStatus>[
            LocalNetworkPermissionStatus.granted,
          ]);
      permission.gate = Completer<void>();
      final LocalNetworkAccess access = accessWith(permission);
      final List<Future<LocalNetworkPermissionStatus?>> checks =
          <Future<LocalNetworkPermissionStatus?>>[
        for (int i = 0; i < 3; i++)
          access.blockerFor(lanServer, prompt: LocalNetworkPrompt.userAction),
      ];
      await Future<void>.delayed(Duration.zero);
      permission.gate!.complete();
      expect(await Future.wait(checks), <Object?>[null, null, null]);
      expect(permission.requests, 1);
    });

    test('a grant made in Android settings is picked up on return', () async {
      final FakeLocalNetworkPermission permission = FakeLocalNetworkPermission(
          LocalNetworkPermissionStatus.permanentlyDenied);
      final LocalNetworkAccess access = accessWith(permission);
      expect(await access.blockerFor(lanServer),
          LocalNetworkPermissionStatus.permanentlyDenied);
      permission.current = LocalNetworkPermissionStatus.granted;
      expect(await access.blockerFor(lanServer),
          LocalNetworkPermissionStatus.permanentlyDenied,
          reason: 'cached while the app stayed in front');
      access.onAppShown();
      expect(await access.blockerFor(lanServer), isNull);
    });

    test('a failing permission channel blocks nothing', () async {
      final LocalNetworkAccess access = LocalNetworkAccess(
        permission: _ThrowingPermission(),
        lookup: fakeLookup,
        isVpnUp: () async => false,
      );
      expect(
          await access.blockerFor(lanServer,
              prompt: LocalNetworkPrompt.userAction),
          isNull);
    });

    test('a host lookup is reused for a while, then made again', () async {
      DateTime now = DateTime(2026, 10, 9, 12);
      final FakeLocalNetworkPermission permission =
          FakeLocalNetworkPermission(LocalNetworkPermissionStatus.denied);
      final LocalNetworkAccess access = accessWith(permission, now: () => now);
      for (int i = 0; i < 10; i++) {
        await access.blockerFor(lanByName);
      }
      expect(lookups, <String>['jellyfin.home.example']);
      now = now.add(const Duration(minutes: 3));
      await access.blockerFor(lanByName);
      expect(lookups, hasLength(2));
    });
  });

  // Android guards Wi-Fi and Ethernet only. A tailnet address (100.64/10) or
  // a home LAN reached over WireGuard goes through the VPN and needs no
  // permission, so refusing it here would break a connection that works.
  group('behind a VPN', () {
    final Uri tailnetServer = Uri.parse('http://100.101.102.103:4533');

    test('a private address is let through, not refused', () async {
      for (final LocalNetworkPermissionStatus status
          in <LocalNetworkPermissionStatus>[
        LocalNetworkPermissionStatus.notRequested,
        LocalNetworkPermissionStatus.denied,
        LocalNetworkPermissionStatus.permanentlyDenied,
      ]) {
        final FakeLocalNetworkPermission permission =
            FakeLocalNetworkPermission(status);
        final _RecordingClient inner = _RecordingClient();
        final http.Client client =
            LocalNetworkGuardedClient(inner, accessWith(permission, vpn: true));
        await client.get(tailnetServer.resolve('/rest/ping'));
        await client.get(lanServer.resolve('/System/Info/Public'));
        expect(inner.sent, hasLength(2), reason: status.name);
        expect(permission.requests, 0, reason: status.name);
      }
    });

    test('a user action may still ask, and a refusal does not block', () async {
      // The VPN may leave the LAN outside the tunnel, where the permission
      // is needed, so the dialog still has its place.
      final FakeLocalNetworkPermission permission = FakeLocalNetworkPermission(
          LocalNetworkPermissionStatus.notRequested,
          answers: <LocalNetworkPermissionStatus>[
            LocalNetworkPermissionStatus.denied,
          ]);
      final LocalNetworkAccess access = accessWith(permission, vpn: true);
      expect(
        await access.blockerFor(tailnetServer,
            prompt: LocalNetworkPrompt.userAction),
        isNull,
      );
      expect(permission.requests, 1);
    });

    test('without one, the same address is refused as before', () async {
      final LocalNetworkAccess access = accessWith(
          FakeLocalNetworkPermission(LocalNetworkPermissionStatus.denied));
      expect(await access.blockerFor(tailnetServer),
          LocalNetworkPermissionStatus.denied);
    });

    test('a probe that fails counts as no VPN', () async {
      final LocalNetworkAccess access = LocalNetworkAccess(
        permission:
            FakeLocalNetworkPermission(LocalNetworkPermissionStatus.denied),
        lookup: fakeLookup,
        isVpnUp: () async => throw const SocketException('no interfaces'),
      );
      expect(await access.blockerFor(lanServer),
          LocalNetworkPermissionStatus.denied);
    });
  });

  group('messages', () {
    test('say what to do and never name the server', () {
      for (final LocalNetworkPermissionStatus status
          in LocalNetworkPermissionStatus.values) {
        final String message = LocalNetworkAccess.messageFor(status);
        expect(message.toLowerCase(), contains('local network'));
        expect(message, isNot(contains('192.168')));
        expect(message, isNot(contains('http')));
      }
      expect(
          LocalNetworkAccess.messageFor(
              LocalNetworkPermissionStatus.permanentlyDenied),
          contains('Nearby devices'));
    });
  });

  group('LocalNetworkGuardedClient', () {
    test('refuses a blocked request at once, without a prompt', () async {
      final FakeLocalNetworkPermission permission =
          FakeLocalNetworkPermission(LocalNetworkPermissionStatus.notRequested);
      final _RecordingClient inner = _RecordingClient();
      final http.Client client =
          LocalNetworkGuardedClient(inner, accessWith(permission));
      await expectLater(
        client.get(lanServer.resolve('/System/Info/Public')),
        throwsA(isA<LocalNetworkBlockedException>()
            .having((LocalNetworkBlockedException e) => e.status, 'status',
                LocalNetworkPermissionStatus.notRequested)
            .having((LocalNetworkBlockedException e) => e.uri, 'uri', isNull)),
      );
      expect(inner.sent, isEmpty);
      expect(permission.requests, 0);
    });

    test('is still an http.ClientException, so clients map it unchanged', () {
      expect(LocalNetworkBlockedException(LocalNetworkPermissionStatus.denied),
          isA<http.ClientException>());
    });

    test('passes internet requests and allowed requests through', () async {
      final FakeLocalNetworkPermission permission =
          FakeLocalNetworkPermission(LocalNetworkPermissionStatus.denied);
      final _RecordingClient inner = _RecordingClient();
      final LocalNetworkAccess access = accessWith(permission);
      final http.Client client = LocalNetworkGuardedClient(inner, access);
      await client.get(internetServer.resolve('/rest/ping'));
      expect(inner.sent, hasLength(1));

      permission.current = LocalNetworkPermissionStatus.granted;
      access.onAppShown();
      await client.get(lanServer.resolve('/System/Info/Public'));
      expect(inner.sent, hasLength(2));
    });
  });
}

class _ThrowingPermission implements LocalNetworkPermission {
  @override
  Future<LocalNetworkPermissionStatus> status() async =>
      throw StateError('channel broke');
  @override
  Future<LocalNetworkPermissionStatus> request() async =>
      throw StateError('channel broke');
  @override
  Future<void> openAppSettings() async {}
}

class _RecordingClient extends http.BaseClient {
  final List<http.BaseRequest> sent = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent.add(request);
    return http.StreamedResponse(const Stream<List<int>>.empty(), 200);
  }
}
