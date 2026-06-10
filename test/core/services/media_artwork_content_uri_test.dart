import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/media_artwork_content_uri.dart';

void main() {
  group('mediaArtworkContentUri', () {
    test('maps a cached file to a content:// URI under the FileProvider', () {
      final file = File('/data/user/0/io.github.thezupzup.linthra/cache/'
          'media_session_artwork/abc123.img');

      final Uri uri = mediaArtworkContentUri(file);

      expect(uri.scheme, 'content');
      expect(uri.host, kMediaArtworkAuthority);
      // <provider-name>/<filename> — the platform reads this through the session.
      expect(uri.pathSegments, <String>[kMediaArtworkPathName, 'abc123.img']);
      expect(
        uri.toString(),
        'content://io.github.thezupzup.linthra.mediaartwork/'
        'media_artwork/abc123.img',
      );
    });

    test('carries only the hashed filename — no directory, credential, or URL',
        () {
      // Even if the file lives under a path with sensitive-looking segments,
      // only the basename (a hash) reaches the URI.
      final file = File('/cache/media_session_artwork/'
          'deadbeefcafe0123456789.img');

      final Uri uri = mediaArtworkContentUri(file);
      final String text = uri.toString().toLowerCase();

      // The directory is dropped; only provider name + hashed basename remain.
      expect(uri.pathSegments.last, 'deadbeefcafe0123456789.img');
      for (final String secret in <String>[
        'getcoverart',
        'token',
        'salt',
        'u=',
        't=',
        's=',
        'http',
        'password',
      ]) {
        expect(text, isNot(contains(secret)),
            reason: 'content URI leaked "$secret"');
      }
    });

    test('the authority is fixed (debug == release, matches the manifest)', () {
      // A hard-coded authority — independent of applicationId/build flavor — so
      // it always matches android:authorities in AndroidManifest.xml.
      expect(
          kMediaArtworkAuthority, 'io.github.thezupzup.linthra.mediaartwork');
      expect(kMediaArtworkPathName, 'media_artwork');
    });
  });

  // The Dart content:// URI is hand-built to match the native FileProvider, so
  // the manifest provider + the granting subclass must stay in lockstep with the
  // Dart constants. A drift would make audio_service / Android Auto unable to
  // resolve or read the cover, silently breaking the feature — these guard it.
  group('the native FileProvider + grant match the Dart side', () {
    late String manifest;

    setUpAll(() {
      manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    });

    test('the manifest provider uses the matching authority', () {
      expect(
          manifest, contains('android:authorities="$kMediaArtworkAuthority"'));
    });

    test('the manifest binds the granting subclass, not the plain FileProvider',
        () {
      // The plain androidx FileProvider would leave the content:// URI unreadable
      // from Android Auto's / SystemUI's process; the subclass grants them read
      // access, which is the whole point.
      expect(manifest, contains('android:name=".MediaArtworkFileProvider"'));
      expect(
        manifest,
        isNot(contains('android:name="androidx.core.content.FileProvider"')),
      );
    });

    test('the provider stays non-exported with uri-permission grants enabled',
        () {
      // exported="false" keeps it non-public; grantUriPermissions="true" is what
      // lets the explicit per-URI read grants to the media hosts take effect.
      expect(manifest, contains('android:exported="false"'));
      expect(manifest, contains('android:grantUriPermissions="true"'));
    });

    test('the granting subclass grants READ-ONLY and never write', () {
      final File provider = File(
        'android/app/src/main/kotlin/io/github/thezupzup/linthra/'
        'MediaArtworkFileProvider.kt',
      );
      expect(provider.existsSync(), isTrue,
          reason: 'MediaArtworkFileProvider.kt must exist for the grant');
      final String src = provider.readAsStringSync();
      expect(src, contains('package io.github.thezupzup.linthra'));
      expect(src, contains(': FileProvider()'));
      // Read access only — never write — and only ever for these cover URIs.
      expect(src, contains('FLAG_GRANT_READ_URI_PERMISSION'));
      expect(src, isNot(contains('FLAG_GRANT_WRITE_URI_PERMISSION')));
    });
  });
}
