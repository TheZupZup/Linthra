import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/local_network/local_network_permission.dart';
import 'package:linthra/features/settings/local_network/local_network_access_card.dart';
import 'package:linthra/features/settings/local_network/local_network_providers.dart';

class _RecordingPermission implements LocalNetworkPermission {
  _RecordingPermission(this.current);

  LocalNetworkPermissionStatus current;
  int requests = 0;
  int settingsOpened = 0;

  @override
  Future<LocalNetworkPermissionStatus> status() async => current;

  @override
  Future<LocalNetworkPermissionStatus> request() async {
    requests++;
    return current;
  }

  @override
  Future<void> openAppSettings() async => settingsOpened++;
}

Future<void> _pump(
  WidgetTester tester, {
  required _RecordingPermission permission,
  required LocalNetworkPermissionStatus? needed,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        localNetworkPermissionProvider.overrideWithValue(permission),
        localNetworkAccessNeededProvider.overrideWith((ref) async => needed),
      ],
      child: const MaterialApp(
        home: Scaffold(body: LocalNetworkAccessCard()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('takes no space when nothing needs local network access',
      (WidgetTester tester) async {
    await _pump(
      tester,
      permission: _RecordingPermission(LocalNetworkPermissionStatus.granted),
      needed: null,
    );
    expect(find.text('Local network access'), findsNothing);
  });

  testWidgets('Allow asks Android, and only when pressed',
      (WidgetTester tester) async {
    final _RecordingPermission permission =
        _RecordingPermission(LocalNetworkPermissionStatus.notRequested);
    await _pump(
      tester,
      permission: permission,
      needed: LocalNetworkPermissionStatus.notRequested,
    );
    expect(find.text('Local network access'), findsOneWidget);
    expect(find.textContaining('Music on this device keeps playing'),
        findsOneWidget);
    expect(permission.requests, 0, reason: 'showing the card asks nothing');

    await tester.tap(find.text('Allow'));
    await tester.pumpAndSettle();
    expect(permission.requests, 1);
  });

  testWidgets('a permanent refusal offers Android settings instead',
      (WidgetTester tester) async {
    final _RecordingPermission permission =
        _RecordingPermission(LocalNetworkPermissionStatus.permanentlyDenied);
    await _pump(
      tester,
      permission: permission,
      needed: LocalNetworkPermissionStatus.permanentlyDenied,
    );
    expect(find.text('Allow'), findsNothing);
    await tester.tap(find.text('Open Android settings'));
    await tester.pumpAndSettle();
    expect(permission.settingsOpened, 1);
    expect(permission.requests, 0);
  });
}
