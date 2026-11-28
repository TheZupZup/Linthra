// The Kotlin half of rustls-platform-verifier is built from source in the
// Android app (android/app/src/main/kotlin/org/rustls/platformverifier/), so
// it has to be the release the Rust half is: the Rust crate calls into it by
// name over JNI, and a mismatch breaks TLS on Android with no compile error.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the vendored Android verifier is the release Cargo pins', () {
    final String manifest =
        File('native/linthra_core/Cargo.toml').readAsStringSync();
    final RegExpMatch? pinned =
        RegExp(r'^rustls-platform-verifier = "=([0-9.]+)"$', multiLine: true)
            .firstMatch(manifest);
    expect(pinned, isNotNull,
        reason: 'Cargo.toml must pin rustls-platform-verifier with "="');
    final String version = pinned!.group(1)!;

    final String lock =
        File('native/linthra_core/Cargo.lock').readAsStringSync();
    expect(
      lock,
      contains('name = "rustls-platform-verifier"\nversion = "$version"'),
    );

    final String kotlin = File(
      'android/app/src/main/kotlin/org/rustls/platformverifier/'
      'CertificateVerifier.kt',
    ).readAsStringSync();
    expect(
      kotlin,
      contains(
          'Vendored, unmodified, from rustls-platform-verifier v/$version'),
    );
  });

  test('the app initializes it in every process', () {
    final String manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android:name=".LinthraApplication"'));
    final String app = File(
      'android/app/src/main/kotlin/io/github/thezupzup/linthra/'
      'LinthraApplication.kt',
    ).readAsStringSync();
    expect(app, contains('NativeTls.initialize(this)'));
  });
}
