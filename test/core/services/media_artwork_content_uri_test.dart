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
}
