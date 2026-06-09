import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/shared/widgets/artwork_image.dart';

void main() {
  // The resolver is a process-global on the single artwork seam; always clear it
  // so one test can't leak its hook into the next.
  tearDown(() => installArtworkReferenceResolver(null));

  group('artworkImageProvider', () {
    test('loads a file:// cover from disk with a FileImage', () {
      final provider = artworkImageProvider(
        Uri.parse('file:///data/app/cache/linthra_local_artwork/abc.img'),
      );
      expect(provider, isA<FileImage>());
      expect(
        (provider as FileImage).file.path,
        File('/data/app/cache/linthra_local_artwork/abc.img').path,
      );
    });

    test('loads an http(s) cover over the network with a NetworkImage', () {
      final http = artworkImageProvider(
        Uri.parse('http://server.example/Items/1/Images/Primary'),
      );
      expect(http, isA<NetworkImage>());
      expect(
        (http as NetworkImage).url,
        'http://server.example/Items/1/Images/Primary',
      );

      final https = artworkImageProvider(
        Uri.parse('https://music.example.com/Items/2/Images/Primary'),
      );
      expect(https, isA<NetworkImage>());
      expect(
        (https as NetworkImage).url,
        'https://music.example.com/Items/2/Images/Primary',
      );
    });
  });

  group('artworkImageProvider with an installed reference resolver', () {
    test('loads an installed resolver\'s resolved URL with a NetworkImage', () {
      installArtworkReferenceResolver((Uri ref) {
        if (ref.scheme != 'subsonic-cover') return null;
        return Uri.parse(
          'https://music.example.com/rest/getCoverArt.view'
          '?id=${ref.path}&u=alice&t=tok&s=salt',
        );
      });

      final provider =
          artworkImageProvider(Uri.parse('subsonic-cover:al-123'));
      expect(provider, isA<NetworkImage>());
      expect(
        (provider as NetworkImage).url,
        'https://music.example.com/rest/getCoverArt.view'
        '?id=al-123&u=alice&t=tok&s=salt',
      );
    });

    test('leaves a file: cover on disk even with a resolver installed', () {
      // The resolver is only consulted for non-file references; a local cover
      // must still load straight from disk.
      installArtworkReferenceResolver((Uri ref) => Uri.parse('https://x/y'));
      final provider = artworkImageProvider(Uri.parse('file:///cache/a.img'));
      expect(provider, isA<FileImage>());
    });

    test('passes a Jellyfin http URL through untouched (resolver returns null)',
        () {
      // A resolver that only owns subsonic-cover references returns null for a
      // plain http URL, which must then load unchanged.
      installArtworkReferenceResolver(
        (Uri ref) => ref.scheme == 'subsonic-cover' ? Uri.parse('https://x') : null,
      );
      final provider = artworkImageProvider(
        Uri.parse('https://server.example/Items/1/Images/Primary'),
      );
      expect(provider, isA<NetworkImage>());
      expect(
        (provider as NetworkImage).url,
        'https://server.example/Items/1/Images/Primary',
      );
    });

    test('an unresolved reference (signed out) falls back to the raw reference',
        () {
      // No resolver installed → the reference can't be turned into a real URL.
      // It still yields a NetworkImage (of the unloadable reference), which the
      // caller's errorBuilder turns into the calm placeholder — never a crash.
      final provider =
          artworkImageProvider(Uri.parse('subsonic-cover:al-123'));
      expect(provider, isA<NetworkImage>());
      expect((provider as NetworkImage).url, 'subsonic-cover:al-123');
    });
  });
}
