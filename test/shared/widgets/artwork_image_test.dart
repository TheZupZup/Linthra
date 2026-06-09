import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/sources/subsonic/subsonic_artwork.dart';
import 'package:linthra/shared/widgets/artwork_image.dart';

const _subsonicSession = SubsonicSession(
  baseUrl: 'https://music.example.com',
  username: 'alice',
  salt: 'the-salt',
  token: 'the-secret-token',
);

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

      final provider = artworkImageProvider(Uri.parse('subsonic-cover:al-123'));
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
        (Uri ref) =>
            ref.scheme == 'subsonic-cover' ? Uri.parse('https://x') : null,
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
      final provider = artworkImageProvider(Uri.parse('subsonic-cover:al-123'));
      expect(provider, isA<NetworkImage>());
      expect((provider as NetworkImage).url, 'subsonic-cover:al-123');
    });
  });

  // The regression guard: install the *exact* resolver main() installs (the
  // real SubsonicArtwork.resolve bound to a session) and prove that adding the
  // Subsonic cover path did not change how Jellyfin network covers or local
  // file: covers are loaded — they are byte-for-byte what they were before.
  group(
      'the production Subsonic resolver leaves Jellyfin + local covers '
      'unchanged', () {
    setUp(() {
      installArtworkReferenceResolver(
        (Uri reference) => SubsonicArtwork.resolve(reference, _subsonicSession),
      );
    });

    test('a Jellyfin token-free primary-image URL still loads unchanged', () {
      // The Subsonic resolver returns null for a non-reference URI, so the
      // Jellyfin http URL falls through and loads exactly as before.
      const String jellyfin =
          'https://music.example.com/Items/track-1/Images/Primary';
      final provider = artworkImageProvider(Uri.parse(jellyfin));
      expect(provider, isA<NetworkImage>());
      expect((provider as NetworkImage).url, jellyfin);
    });

    test('a local embedded-cover file: URI still loads from disk unchanged',
        () {
      // file: is handled before the resolver is ever consulted, so local
      // embedded art is untouched.
      final provider = artworkImageProvider(
        Uri.parse('file:///data/app/cache/linthra_local_artwork/abc.img'),
      );
      expect(provider, isA<FileImage>());
      expect(
        (provider as FileImage).file.path,
        File('/data/app/cache/linthra_local_artwork/abc.img').path,
      );
    });

    test(
        'a Subsonic cover reference resolves to an authenticated getCoverArt '
        'URL', () {
      final provider = artworkImageProvider(SubsonicArtwork.reference('al-7'));
      expect(provider, isA<NetworkImage>());
      final Uri resolved = Uri.parse((provider as NetworkImage).url);
      expect(resolved.host, 'music.example.com');
      expect(resolved.path, '/rest/getCoverArt.view');
      expect(resolved.queryParameters['id'], 'al-7');
      expect(resolved.queryParameters['u'], 'alice');
      expect(resolved.queryParameters['t'], 'the-secret-token');
      expect(resolved.queryParameters['s'], 'the-salt');
    });
  });
}
