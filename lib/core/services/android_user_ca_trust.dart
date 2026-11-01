import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

const MethodChannel _channel =
    MethodChannel('io.github.thezupzup.linthra/user_cas');

// Reads user-installed CA certificates from Android.
Future<List<Uint8List>> readAndroidUserCas({
  MethodChannel channel = _channel,
}) async {
  return await channel.invokeListMethod<Uint8List>(
        'getUserCaCertificates',
      ) ??
      <Uint8List>[];
}

// Load user-installed Android CAs into Dart's TLS trust store.
Future<void> trustAndroidUserCas() async {
  if (!Platform.isAndroid) return;

  final List<Uint8List> certificates = await readAndroidUserCas();

  for (final Uint8List certificate in certificates) {
    final String pem = derCertificateToPem(certificate);

    SecurityContext.defaultContext
        .setTrustedCertificatesBytes(utf8.encode(pem));
  }
}

// Convert a DER certificate to PEM format.
String derCertificateToPem(Uint8List certificate) {
  final String encoded = base64.encode(certificate);
  final List<String> lines = <String>[];

  for (int i = 0; i < encoded.length; i += 64) {
    final int end = i + 64 < encoded.length ? i + 64 : encoded.length;

    lines.add(encoded.substring(i, end));
  }

  return '-----BEGIN CERTIFICATE-----\n'
      '${lines.join('\n')}\n'
      '-----END CERTIFICATE-----\n';
}
