import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/artwork_disk_cache.dart';

/// Bytes that start like a PNG, which is all the cache checks before saving a
/// cover.
const List<int> _cover = <int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4];

void main() {
  group('ArtworkDiskCache', () {
    late Directory dir;
    late List<Uri> fetchedUrls;
    late List<int>? Function(Uri url) fetch;

    ArtworkDiskCache build({Uri Function(Uri key)? resolveFetchUrl}) {
      return ArtworkDiskCache(
        directory: dir,
        resolveFetchUrl: resolveFetchUrl,
        fetch: (Uri url) async {
          fetchedUrls.add(url);
          return fetch(url);
        },
      );
    }

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('artwork_disk_cache_test');
      fetchedUrls = <Uri>[];
      fetch = (Uri url) => _cover;
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('a miss returns null and fetches nothing on its own', () async {
      final cache = build();
      expect(cache.cachedFile(Uri.parse('https://server.example/cover.jpg')),
          isNull);
      expect(fetchedUrls, isEmpty);
    });

    test('cache miss fetches and stores the image', () async {
      final cache = build();
      final key = Uri.parse('https://server.example/cover.jpg');

      await cache.warm(key);

      expect(fetchedUrls, [key]);
      final File? cached = cache.cachedFile(key);
      expect(cached, isNotNull);
      expect(await cached!.readAsBytes(), _cover);
    });

    test('a cache hit avoids a second network fetch', () async {
      final cache = build();
      final key = Uri.parse('https://server.example/cover.jpg');
      await cache.warm(key);
      expect(fetchedUrls, hasLength(1));

      // A fresh instance over the same directory, so this is a genuine restart
      // scenario, not just in-memory memoization.
      final reopened = build();
      final File? cached = reopened.cachedFile(key);
      expect(cached, isNotNull);

      // Warming again must not re-fetch: the file is already there.
      await reopened.warm(key);
      expect(fetchedUrls, hasLength(1));
    });

    test('concurrent warms of the same key share one fetch', () async {
      final cache = build();
      final key = Uri.parse('https://server.example/cover.jpg');

      await Future.wait(<Future<void>>[
        cache.warm(key),
        cache.warm(key),
        cache.warm(key),
      ]);

      expect(fetchedUrls, hasLength(1));
    });

    test('a missing cache entry refetches safely', () async {
      final cache = build();
      final key = Uri.parse('https://server.example/cover.jpg');
      expect(cache.cachedFile(key), isNull);

      await cache.warm(key);
      expect(cache.cachedFile(key), isNotNull);
    });

    test('a corrupt (0-byte) cache entry is treated as a miss and refetched',
        () async {
      final cache = build();
      final key = Uri.parse('https://server.example/cover.jpg');

      // Simulate a truncated/corrupt prior write.
      if (!await dir.exists()) await dir.create(recursive: true);
      final File corrupt = File(
        '${dir.path}/${_sha256Hex('https://server.example/cover.jpg')}.img',
      );
      await corrupt.writeAsBytes(<int>[]);

      expect(cache.cachedFile(key), isNull);

      await cache.warm(key);
      final File? healed = cache.cachedFile(key);
      expect(healed, isNotNull);
      expect(await healed!.readAsBytes(), _cover);
    });

    test('a failed fetch caches nothing and never throws', () async {
      fetch = (Uri url) => null;
      final cache = build();
      final key = Uri.parse('https://server.example/cover.jpg');

      await cache.warm(key);

      expect(cache.cachedFile(key), isNull);
    });

    test('an unresolved reference (e.g. signed out) is never fetched',
        () async {
      // resolveFetchUrl returns the reference itself (unresolved), which is
      // not http(s) — the cache must skip fetching rather than attempt (and
      // fail) an unsupported request.
      final cache = build(resolveFetchUrl: (Uri key) => key);
      final key = Uri.parse('subsonic-cover:al-123');

      await cache.warm(key);

      expect(fetchedUrls, isEmpty);
      expect(cache.cachedFile(key), isNull);
    });

    test(
        'no token or authenticated URL is persisted: the cache key and file '
        'name are derived only from the credential-free reference', () async {
      final key = Uri.parse('subsonic-cover:al-123');
      final cache = build(
        resolveFetchUrl: (Uri k) => Uri.parse(
          'https://music.example.com/rest/getCoverArt.view'
          '?id=al-123&u=alice&t=super-secret-token&s=salt',
        ),
      );

      await cache.warm(key);

      final File? cached = cache.cachedFile(key);
      expect(cached, isNotNull);
      // The file name is a hash of the credential-free key, never the URL.
      expect(cached!.path, isNot(contains('super-secret-token')));
      expect(cached.path, isNot(contains('getCoverArt')));
      expect(cached.path, contains(_sha256Hex('subsonic-cover:al-123')));
      // The bytes on disk are exactly the image, no URL text embedded.
      expect(await cached.readAsBytes(), _cover);
      // Nothing else was written to the directory (no manifest/index file).
      final List<FileSystemEntity> entries = await dir.list().toList();
      expect(entries, hasLength(1));
    });

    test(
        'provider-specific references stay credential-free: the same '
        'reference caches to the same file regardless of a rotated token',
        () async {
      String token = 'token-one';
      final key = Uri.parse('plex-thumb:/library/metadata/1/thumb/1');
      final cache = build(
        resolveFetchUrl: (Uri k) => Uri.parse(
          'https://plex.example.com${k.path}?X-Plex-Token=$token',
        ),
      );

      await cache.warm(key);
      final File? first = cache.cachedFile(key);
      expect(first, isNotNull);
      final String firstPath = first!.path;

      // Force a re-fetch under a rotated token by deleting the cached file —
      // the resulting file must land at the exact same, token-independent path.
      await first.delete();
      token = 'token-two';
      await cache.warm(key);
      final File? second = cache.cachedFile(key);
      expect(second, isNotNull);
      expect(second!.path, firstPath);
    });
  });

  group('ArtworkDiskCache per server, fresh and bounded (#739)', () {
    late Directory dir;
    late List<Uri> fetchedUrls;
    late List<int>? Function(Uri url) fetch;
    late String? server;
    late DateTime now;

    ArtworkDiskCache build({int maxBytes = 1 << 20}) => ArtworkDiskCache(
          directory: dir,
          resolveFetchUrl: (Uri key) =>
              Uri.parse('https://$server.example/cover/${key.path}'),
          serverOf: (Uri key) => key.isScheme('subsonic-cover') ? server : '',
          fetch: (Uri url) async {
            fetchedUrls.add(url);
            return fetch(url);
          },
          maxBytes: maxBytes,
          now: () => now,
        );

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('artwork_disk_cache_739');
      fetchedUrls = <Uri>[];
      fetch = (Uri url) => <int>[..._cover, ...utf8.encode(url.host)];
      server = 'server-a';
      now = DateTime.now();
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    final Uri al12 = Uri.parse('subsonic-cover:al-12');

    test("another server's al-12 is another cover", () async {
      final ArtworkDiskCache cache = build();
      await cache.warm(al12);
      final List<int> fromA = await cache.cachedFile(al12)!.readAsBytes();

      server = 'server-b';
      expect(cache.cachedFile(al12), isNull);
      await cache.warm(al12);

      expect(fetchedUrls.map((Uri u) => u.host), <String>[
        'server-a.example',
        'server-b.example',
      ]);
      expect(await cache.cachedFile(al12)!.readAsBytes(), isNot(fromA));
      // And server A's is still there for when it is connected again.
      server = 'server-a';
      expect(await cache.cachedFile(al12)!.readAsBytes(), fromA);
    });

    test('signed out, a reference is neither read nor fetched', () async {
      final ArtworkDiskCache cache = build();
      await cache.warm(al12);
      server = null;

      expect(cache.cachedFile(al12), isNull);
      await cache.warm(al12);
      expect(fetchedUrls, hasLength(1));
    });

    test('a URL keeps the file name it had before servers were told apart',
        () async {
      final ArtworkDiskCache cache = build();
      final Uri jellyfin =
          Uri.parse('https://jf.example/Items/1/Images/Primary');

      await cache.warm(jellyfin);

      expect(
        cache.cachedFile(jellyfin)!.path,
        endsWith('${_sha256Hex(jellyfin.toString())}.img'),
      );
    });

    test('bytes that are not an image are never saved', () async {
      // An error page sent with an image content type.
      fetch = (Uri url) => utf8.encode('<html>502 Bad Gateway</html>');
      final ArtworkDiskCache cache = build();

      await cache.warm(al12);

      expect(cache.cachedFile(al12), isNull);
      expect(
          await dir.exists() ? await dir.list().toList() : <Object>[], isEmpty);
    });

    test('an old cover is still shown and fetched again in the background',
        () async {
      final ArtworkDiskCache cache = build();
      await cache.warm(al12);
      fetch = (Uri url) => <int>[..._cover, 9, 9, 9];

      now = now.add(
        ArtworkDiskCache.defaultRefreshAfter + const Duration(minutes: 1),
      );
      final File? stale = cache.cachedFile(al12);
      expect(stale, isNotNull);
      await cache.warm(al12);

      expect(fetchedUrls, hasLength(2));
      expect(await cache.cachedFile(al12)!.readAsBytes(),
          <int>[..._cover, 9, 9, 9]);
    });

    test('an old cover is kept when fetching it again fails', () async {
      final ArtworkDiskCache cache = build();
      await cache.warm(al12);
      final List<int> before = await cache.cachedFile(al12)!.readAsBytes();
      fetch = (Uri url) => null;

      now = now.add(const Duration(days: 365));
      await cache.warm(al12);

      expect(await cache.cachedFile(al12)!.readAsBytes(), before);
    });

    test('a fresh cover is not fetched again', () async {
      final ArtworkDiskCache cache = build();
      await cache.warm(al12);

      now = now.add(const Duration(days: 1));
      cache.cachedFile(al12);
      await cache.warm(al12);

      expect(fetchedUrls, hasLength(1));
    });

    test(
        "a switch while a warm looks at the disk never files the new server's "
        'cover as the old one\'s', () async {
      final ArtworkDiskCache cache = build();

      // Warmed under server A, then the account switches before the disk
      // check comes back.
      final Future<void> warming = cache.warm(al12);
      server = 'server-b';
      await warming;

      server = 'server-a';
      expect(cache.cachedFile(al12), isNull);
      expect(fetchedUrls, isEmpty);
    });

    test('past the cap, the covers fetched longest ago go first', () async {
      // Each cover is 1,000 bytes. Fetched with room to spare...
      fetch = (Uri url) => <int>[..._cover, ...List<int>.filled(992, 7)];
      final ArtworkDiskCache roomy = build();
      final List<Uri> covers = <Uri>[
        for (int i = 0; i < 6; i++) Uri.parse('subsonic-cover:al-$i'),
      ];
      for (int i = 0; i < covers.length; i++) {
        await roomy.warm(covers[i]);
        // In this order, a minute apart.
        roomy
            .cachedFile(covers[i])!
            .setLastModifiedSync(DateTime(2026, 10, 1, 12, i));
      }
      // ...then the next launch has room for four.
      final ArtworkDiskCache cache = build(maxBytes: 4000);

      await cache.trim();

      expect(
        <bool>[for (final Uri cover in covers) cache.cachedFile(cover) != null],
        <bool>[false, false, false, true, true, true],
      );
    });

    test('the cap is enforced after the first write on its own', () async {
      fetch = (Uri url) => <int>[..._cover, ...List<int>.filled(992, 7)];
      // Leftovers from an earlier run, already over the cap.
      await dir.create(recursive: true);
      for (int i = 0; i < 5; i++) {
        final File old = File('${dir.path}/old$i.img')
          ..writeAsBytesSync(List<int>.filled(1000, 1));
        old.setLastModifiedSync(DateTime(2020, 1, 1, 0, i));
      }
      final ArtworkDiskCache cache = build(maxBytes: 3000);

      await cache.warm(al12);
      // The trim runs in the background, from the first use on.
      for (int i = 0; i < 100 && _coverBytes(dir) > 3000; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(cache.cachedFile(al12), isNotNull);
      expect(_coverBytes(dir), lessThanOrEqualTo(3000));
    });

    test(
        'a cache already past the cap is brought under it at first use, with '
        'nothing written', () async {
      // Covers fetched before there was a cap: all fresh, so every one is a
      // hit and nothing is ever written again.
      fetch = (Uri url) => <int>[..._cover, ...List<int>.filled(992, 7)];
      final ArtworkDiskCache roomy = build();
      final List<Uri> covers = <Uri>[
        for (int i = 0; i < 6; i++) Uri.parse('subsonic-cover:al-$i'),
      ];
      for (int i = 0; i < covers.length; i++) {
        await roomy.warm(covers[i]);
        roomy
            .cachedFile(covers[i])!
            .setLastModifiedSync(now.subtract(Duration(minutes: 10 - i)));
      }
      fetchedUrls.clear();
      final ArtworkDiskCache cache = build(maxBytes: 4000);

      expect(cache.cachedFile(covers.last), isNotNull);
      for (int i = 0; i < 100 && _coverBytes(dir) > 4000; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(_coverBytes(dir), lessThanOrEqualTo(4000));
      expect(fetchedUrls, isEmpty);
      // The ones fetched last stay.
      expect(cache.cachedFile(covers.last), isNotNull);
    });
  });
}

/// The bytes the covers in [dir] take.
int _coverBytes(Directory dir) => <int>[
      for (final FileSystemEntity entity in dir.listSync())
        if (entity is File && entity.path.endsWith('.img')) entity.lengthSync(),
    ].fold(0, (int sum, int size) => sum + size);

String _sha256Hex(String input) {
  // Mirrors ArtworkDiskCache's private hashing without depending on it, so a
  // change to the private implementation that keeps the *contract* (a stable,
  // credential-free, content-addressed file name) doesn't need this test to
  // reach into private state.
  const String alphabet = '0123456789abcdef';
  final List<int> bytes = _sha256(input);
  final StringBuffer buffer = StringBuffer();
  for (final int byte in bytes) {
    buffer.write(alphabet[(byte >> 4) & 0xf]);
    buffer.write(alphabet[byte & 0xf]);
  }
  return buffer.toString();
}

// Uses the same `crypto` package the production code uses, rather than a
// local shim.
List<int> _sha256(String input) => sha256.convert(utf8.encode(input)).bytes;
