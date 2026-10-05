import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/services/artwork_disk_cache.dart';
import 'package:linthra/core/sources/plex/plex_artwork.dart';
import 'package:linthra/core/sources/plex/plex_track_mapper.dart';
import 'package:linthra/core/sources/subsonic/subsonic_artwork.dart';
import 'package:linthra/shared/widgets/artwork_image.dart';

const _subsonicSession = SubsonicSession(
  baseUrl: 'https://music.example.com',
  username: 'alice',
  salt: 'the-salt',
  token: 'the-secret-token',
);

/// Bytes that start like a PNG, which is all the disk cache checks before
/// saving a cover (#739).
const List<int> _coverBytes = <int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3];

void main() {
  // The resolver and the disk cache are process-globals on the single artwork
  // seam; always clear them so one test can't leak its hook into the next.
  tearDown(() {
    installArtworkReferenceResolver(null);
    installArtworkDiskCache(null);
  });

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

  // The same regression guard for the full production chain: main() installs
  // Subsonic *then* Plex, each owning one scheme and passing the rest through.
  // Prove a plex-thumb reference resolves only with a Plex session, falls back
  // safely without one, and that adding Plex changed nothing for Jellyfin,
  // Subsonic, or local covers.
  group('the production Subsonic→Plex resolver chain (as main() installs it)',
      () {
    const PlexSession plexSession = PlexSession(
      baseUrl: 'https://plex.example.com:32400',
      token: 'plex-secret-token',
      machineIdentifier: 'machine-1',
    );

    /// Installs the chain exactly as `main()` composes it; passing `null`
    /// mirrors that provider being signed out.
    void installChain({SubsonicSession? subsonic, PlexSession? plex}) {
      installArtworkReferenceResolver((Uri reference) {
        if (subsonic != null) {
          final Uri? resolved = SubsonicArtwork.resolve(reference, subsonic);
          if (resolved != null) return resolved;
        }
        if (plex != null) {
          final Uri? resolved = PlexArtwork.resolve(reference, plex);
          if (resolved != null) return resolved;
        }
        return null;
      });
    }

    Uri plexReference(String thumbPath) =>
        Uri(scheme: PlexTrackMapper.artworkScheme, path: thumbPath);

    test('a plex-thumb reference resolves to an authenticated cover URL', () {
      installChain(subsonic: _subsonicSession, plex: plexSession);

      final provider = artworkImageProvider(
        plexReference('/library/metadata/123/thumb/1670000000'),
      );

      expect(provider, isA<NetworkImage>());
      final Uri resolved = Uri.parse((provider as NetworkImage).url);
      expect(resolved.host, 'plex.example.com');
      expect(resolved.path, '/library/metadata/123/thumb/1670000000');
      expect(resolved.queryParameters['X-Plex-Token'], 'plex-secret-token');
      // The Subsonic resolver ahead of Plex in the chain didn't capture it.
      expect(resolved.path, isNot(contains('getCoverArt')));
    });

    test(
        'signed out of Plex, a plex-thumb reference falls back to the raw '
        'reference (the placeholder path) — never a stale URL', () {
      installChain(subsonic: _subsonicSession, plex: null);

      final provider = artworkImageProvider(
        plexReference('/library/metadata/123/thumb/1670000000'),
      );

      // Unresolved references load as a NetworkImage of the unloadable
      // reference itself; the caller's errorBuilder shows the placeholder.
      // No token, no server address — nothing stale to leak.
      expect(provider, isA<NetworkImage>());
      final String url = (provider as NetworkImage).url;
      expect(url, 'plex-thumb:/library/metadata/123/thumb/1670000000');
      expect(url, isNot(contains('plex-secret-token')));
      expect(url, isNot(contains('plex.example.com')));
    });

    test('each scheme resolves against its own server, never the other', () {
      installChain(subsonic: _subsonicSession, plex: plexSession);

      final Uri subsonicResolved = Uri.parse(
        (artworkImageProvider(SubsonicArtwork.reference('al-7'))
                as NetworkImage)
            .url,
      );
      final Uri plexResolved = Uri.parse(
        (artworkImageProvider(plexReference('/library/metadata/1/thumb/2'))
                as NetworkImage)
            .url,
      );

      expect(subsonicResolved.host, 'music.example.com');
      expect(subsonicResolved.toString(), isNot(contains('X-Plex-Token')));
      expect(plexResolved.host, 'plex.example.com');
      expect(plexResolved.toString(), isNot(contains('the-secret-token')));
    });

    test('Jellyfin http and local file: covers load unchanged', () {
      installChain(subsonic: _subsonicSession, plex: plexSession);

      const String jellyfin =
          'https://music.example.com/Items/track-1/Images/Primary';
      final jellyfinProvider = artworkImageProvider(Uri.parse(jellyfin));
      expect(jellyfinProvider, isA<NetworkImage>());
      expect((jellyfinProvider as NetworkImage).url, jellyfin);

      final fileProvider = artworkImageProvider(
        Uri.parse('file:///data/app/cache/linthra_local_artwork/abc.img'),
      );
      expect(fileProvider, isA<FileImage>());
    });
  });

  // Issue #356: persistent artwork caching. No [ArtworkDiskCache] installed is
  // covered by every group above (they never install one) — this group covers
  // the seam's behaviour once one *is* installed.
  group('artworkImageProvider with an installed disk cache', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('artwork_image_cache_test');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('a cache hit returns a FileImage — no NetworkImage, no resolver call',
        () async {
      bool resolverCalled = false;
      installArtworkReferenceResolver((Uri ref) {
        resolverCalled = true;
        return Uri.parse('https://should-not-be-used.example');
      });
      final cache = ArtworkDiskCache(
        directory: dir,
        fetch: (Uri url) async => _coverBytes,
      );
      installArtworkDiskCache(cache);
      final key = Uri.parse('https://server.example/Items/1/Images/Primary');
      await cache.warm(key);

      final provider = artworkImageProvider(key);

      expect(provider, isA<FileImage>());
      expect(resolverCalled, isFalse);
    });

    test(
        'a cache miss still returns a NetworkImage exactly as before, and '
        'warms the cache in the background for next time', () async {
      final cache = ArtworkDiskCache(
        directory: dir,
        fetch: (Uri url) async => _coverBytes,
      );
      installArtworkDiskCache(cache);
      final key = Uri.parse('https://server.example/Items/1/Images/Primary');

      final provider = artworkImageProvider(key);

      // The render itself is unaffected by the miss — same type, same URL as
      // with no disk cache installed at all.
      expect(provider, isA<NetworkImage>());
      expect((provider as NetworkImage).url, key.toString());

      // The background warm this call fired is fire-and-forget; warm() itself
      // de-dupes concurrent calls for the same key, so awaiting it again here
      // returns the exact in-flight future the provider started, letting the
      // test wait for it deterministically instead of guessing event-loop
      // turns.
      await cache.warm(key);
      final File? cached = cache.cachedFile(key);
      expect(cached, isNotNull);
      expect(artworkImageProvider(key), isA<FileImage>());
    });

    test('a corrupt cache entry falls back to a fresh NetworkImage fetch',
        () async {
      await dir.create(recursive: true);
      final key = Uri.parse('https://server.example/Items/1/Images/Primary');
      final File corrupt = File('${dir.path}/anything.img');
      // A cache hit is only ever a file whose *hashed* name ArtworkDiskCache
      // itself would produce; this stray/corrupt file must simply be ignored
      // (a miss), never mistaken for this key's cache entry.
      await corrupt.writeAsBytes(<int>[]);
      installArtworkDiskCache(
        ArtworkDiskCache(directory: dir, fetch: (Uri url) async => null),
      );

      final provider = artworkImageProvider(key);

      expect(provider, isA<NetworkImage>());
      expect((provider as NetworkImage).url, key.toString());
    });

    test(
        'a Subsonic reference miss warms via the resolved (authenticated) '
        'URL but caches under the credential-free reference', () async {
      installArtworkReferenceResolver(
        (Uri ref) => SubsonicArtwork.resolve(ref, _subsonicSession),
      );
      final List<Uri> fetchedUrls = <Uri>[];
      final cache = ArtworkDiskCache(
        directory: dir,
        resolveFetchUrl: (Uri ref) =>
            SubsonicArtwork.resolve(ref, _subsonicSession) ?? ref,
        fetch: (Uri url) async {
          fetchedUrls.add(url);
          return _coverBytes;
        },
      );
      installArtworkDiskCache(cache);
      final reference = SubsonicArtwork.reference('al-7');

      artworkImageProvider(reference);
      // Awaits the same in-flight warm the provider's fire-and-forget call
      // started (warm() de-dupes by key), rather than guessing event-loop
      // turns.
      await cache.warm(reference);

      // The fetch went out to the authenticated getCoverArt URL...
      expect(fetchedUrls, hasLength(1));
      expect(fetchedUrls.single.toString(), contains('getCoverArt'));
      expect(fetchedUrls.single.toString(), contains('the-secret-token'));
      // ...but the cache is keyed by the credential-free reference, so a later
      // render of the *same reference* is a hit regardless of the token.
      expect(cache.cachedFile(reference), isNotNull);
      expect(artworkImageProvider(reference), isA<FileImage>());
    });
  });
}
