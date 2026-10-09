import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/local_network/local_network_permission.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel =
      MethodChannel('io.github.thezupzup.linthra/local_network');
  final List<String> calls = <String>[];

  void answer(Object? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call.method);
      return handler(call);
    });
  }

  setUp(calls.clear);
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  test('parses every status the Kotlin channel sends', () {
    const Map<String?, LocalNetworkPermissionStatus> expected =
        <String?, LocalNetworkPermissionStatus>{
      'notRequired': LocalNetworkPermissionStatus.notRequired,
      'granted': LocalNetworkPermissionStatus.granted,
      'notRequested': LocalNetworkPermissionStatus.notRequested,
      'denied': LocalNetworkPermissionStatus.denied,
      'permanentlyDenied': LocalNetworkPermissionStatus.permanentlyDenied,
      'somethingNew': LocalNetworkPermissionStatus.unknown,
      null: LocalNetworkPermissionStatus.unknown,
    };
    expected.forEach((String? raw, LocalNetworkPermissionStatus status) {
      expect(MethodChannelLocalNetworkPermission.parseStatus(raw), status);
    });
  });

  test('status and request go over the channel', () async {
    answer((MethodCall call) =>
        call.method == 'status' ? 'notRequested' : 'granted');
    const MethodChannelLocalNetworkPermission permission =
        MethodChannelLocalNetworkPermission();
    expect(
        await permission.status(), LocalNetworkPermissionStatus.notRequested);
    expect(await permission.request(), LocalNetworkPermissionStatus.granted);
    await permission.openAppSettings();
    expect(calls, <String>['status', 'request', 'openAppSettings']);
  });

  test('no channel (engine without an activity) reads as unknown', () async {
    const MethodChannelLocalNetworkPermission permission =
        MethodChannelLocalNetworkPermission();
    expect(await permission.status(), LocalNetworkPermissionStatus.unknown);
    expect(await permission.request(), LocalNetworkPermissionStatus.unknown);
    await permission.openAppSettings();
  });

  test('a request already in flight reports the current status', () async {
    answer((MethodCall call) {
      if (call.method == 'request') {
        throw PlatformException(code: 'permission_in_progress');
      }
      return 'denied';
    });
    const MethodChannelLocalNetworkPermission permission =
        MethodChannelLocalNetworkPermission();
    expect(await permission.request(), LocalNetworkPermissionStatus.denied);
  });

  test('the unsupported platform never needs it', () async {
    const UnsupportedLocalNetworkPermission permission =
        UnsupportedLocalNetworkPermission();
    expect(await permission.status(), LocalNetworkPermissionStatus.notRequired);
    expect(
        await permission.request(), LocalNetworkPermissionStatus.notRequired);
  });
}
