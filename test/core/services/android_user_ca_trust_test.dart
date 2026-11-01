import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/android_user_ca_trust.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('linthra_user_ca_test');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('converts DER certificate bytes to PEM', () {
    final Uint8List certificate = Uint8List.fromList(
      <int>[0, 255, 128, 1],
    );

    expect(
      derCertificateToPem(certificate),
      '-----BEGIN CERTIFICATE-----\n'
      'AP+AAQ==\n'
      '-----END CERTIFICATE-----\n',
    );
  });

  test('wraps PEM certificate lines at 64 characters', () {
    final Uint8List certificate = Uint8List(49);

    final List<String> lines =
        derCertificateToPem(certificate).trimRight().split('\n');

    expect(lines, hasLength(4));
    expect(lines[1].length, 64);
    expect(lines[2].length, 4);
  });

  test('reads certificates from the Android channel', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'getUserCaCertificates');

      return <Uint8List>[
        Uint8List.fromList(<int>[1, 2, 3]),
      ];
    });

    final List<Uint8List> certificates =
        await readAndroidUserCas(channel: channel);

    expect(certificates, hasLength(1));
    expect(certificates.single, orderedEquals(<int>[1, 2, 3]));
  });

  test('returns an empty list when Android has no user CAs', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      return null;
    });

    final List<Uint8List> certificates =
        await readAndroidUserCas(channel: channel);

    expect(certificates, isEmpty);
  });

  test('reports errors when the Android CA store fails', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      throw PlatformException(code: 'ca_store_unavailable');
    });

    await expectLater(
      readAndroidUserCas(channel: channel),
      throwsA(isA<PlatformException>()),
    );
  });
}
