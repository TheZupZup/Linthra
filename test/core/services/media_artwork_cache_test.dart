import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/media_artwork_cache.dart';
import 'package:linthra/core/services/media_artwork_content_uri.dart';
import 'package:path/path.dart' as p;

/// A credential-free Subsonic cover reference (what the catalog persists).
final Uri _reference = Uri.parse('subsonic-cover:al-123');

/// The authenticated getCoverArt URL the live session would mint — it carries
/// the username, salt, and token, and must never end up in a filename or be
/// returned/persisted by the cache.
final Uri _authUrl = Uri.parse(
  'https://music.example.com/rest/getCoverArt.view'
  '?id=al-123&u=alice&t=the-secret-token&s=the-salt&v=1.16.1&c=Linthra&f=json',
);

const List<int> _imageBytes = <int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4];

void main() {
  late Directory tempRoot;
  late Directory cacheDir;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('media_artwork_cache');
    cacheDir = Directory(p.join(tempRoot.path, 'media_session_artwork'));
  });

  tearDown(() async {
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  Future<Directory> directory() async => cacheDir;

  List<File> cachedFiles() {
    if (!cacheDir.existsSync()) return <File>[];
    return cacheDir.listSync(recursive: true).whereType<File>().toList();
  }

  /// The on-disk cache file a returned `content://` URI points at (its last path
  /// segment is the hashed filename, written under [cacheDir]).
  File fileFor(Uri contentUri) =>
      File(p.join(cacheDir.path, contentUri.pathSegments.last));

  group('MediaArtworkCache.resolve', () {
    test('fetches the cover and returns a content:// URI over the cached bytes',
        () async {
      Uri? fetchedUrl;
      final cache = MediaArtworkCache(
        resolveUrl: (Uri reference) =>
            reference == _reference ? _authUrl : null,
        fetch: (Uri url) async {
          fetchedUrl = url;
          return _imageBytes;
        },
        directory: directory,
      );

      final Uri? result = await cache.resolve(_reference);

      expect(result, isNotNull);
      // A FileProvider content:// URI the platform session can read — not a
      // file: path (which Android Auto's process couldn't read).
      expect(result!.isScheme('content'), isTrue);
      expect(result.host, kMediaArtworkAuthority);
      expect(result.pathSegments.first, kMediaArtworkPathName);
      // The bytes are on disk under the private cache dir.
      final File file = fileFor(result);
      expect(await file.exists(), isTrue);
      expect(await file.readAsBytes(), _imageBytes);
      // The authenticated URL was used once, only to fetch.
      expect(fetchedUrl, _authUrl);
    });

    test('the content URI carries no credential, server URL, or auth query',
        () async {
      final cache = MediaArtworkCache(
        resolveUrl: (Uri reference) => _authUrl,
        fetch: (Uri url) async => _imageBytes,
        directory: directory,
      );

      final Uri? result = await cache.resolve(_reference);
      final String uri = result!.toString().toLowerCase();
      final String name = result.pathSegments.last;

      for (final String secret in <String>[
        'alice',
        'the-secret-token',
        'the-salt',
        'music.example.com',
        'getcoverart',
        'rest',
        'u=',
        't=',
        's=',
        'http',
        'view',
      ]) {
        expect(uri, isNot(contains(secret.toLowerCase())),
            reason: 'content URI leaked "$secret"');
      }
      // The filename is exactly the SHA-256 of the *credential-free* reference.
      final String expected =
          '${sha256.convert(utf8.encode(_reference.toString()))}.img';
      expect(name, expected);
    });

    test('never persists the authenticated URL in the cached bytes or path',
        () async {
      final cache = MediaArtworkCache(
        resolveUrl: (Uri reference) => _authUrl,
        fetch: (Uri url) async => _imageBytes,
        directory: directory,
      );

      final Uri? result = await cache.resolve(_reference);

      // The returned content URI and the on-disk file path are credential-free.
      final String full = '${result!}\n${fileFor(result).path}'.toLowerCase();
      expect(full, isNot(contains('the-secret-token')));
      expect(full, isNot(contains('the-salt')));
      expect(full, isNot(contains('getcoverart')));
    });

    test('a signed-out reference (null URL) yields null without fetching',
        () async {
      int fetchCalls = 0;
      final cache = MediaArtworkCache(
        resolveUrl: (Uri reference) => null, // signed out / not resolvable
        fetch: (Uri url) async {
          fetchCalls++;
          return _imageBytes;
        },
        directory: directory,
      );

      expect(await cache.resolve(_reference), isNull);
      expect(fetchCalls, 0);
      expect(cachedFiles(), isEmpty);
    });

    test('a failed download yields null and writes no file', () async {
      final cache = MediaArtworkCache(
        resolveUrl: (Uri reference) => _authUrl,
        fetch: (Uri url) async => null, // transport error / non-image body
        directory: directory,
      );

      expect(await cache.resolve(_reference), isNull);
      expect(cachedFiles(), isEmpty);
    });

    test('an empty body yields null', () async {
      final cache = MediaArtworkCache(
        resolveUrl: (Uri reference) => _authUrl,
        fetch: (Uri url) async => const <int>[],
        directory: directory,
      );

      expect(await cache.resolve(_reference), isNull);
      expect(cachedFiles(), isEmpty);
    });

    test('a fetch that throws resolves to null (never blocks the caller)',
        () async {
      final cache = MediaArtworkCache(
        resolveUrl: (Uri reference) => _authUrl,
        fetch: (Uri url) async => throw const SocketException('offline'),
        directory: directory,
      );

      expect(await cache.resolve(_reference), isNull);
    });

    test('a second resolve reuses the cached file without re-fetching',
        () async {
      int fetchCalls = 0;
      final cache = MediaArtworkCache(
        resolveUrl: (Uri reference) => _authUrl,
        fetch: (Uri url) async {
          fetchCalls++;
          return _imageBytes;
        },
        directory: directory,
      );

      final Uri? first = await cache.resolve(_reference);
      final Uri? second = await cache.resolve(_reference);

      expect(second, first);
      expect(fetchCalls, 1);
    });

    test('concurrent resolves share a single fetch', () async {
      int fetchCalls = 0;
      final cache = MediaArtworkCache(
        resolveUrl: (Uri reference) => _authUrl,
        fetch: (Uri url) async {
          fetchCalls++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return _imageBytes;
        },
        directory: directory,
      );

      final List<Uri?> results = await Future.wait(<Future<Uri?>>[
        cache.resolve(_reference),
        cache.resolve(_reference),
      ]);

      expect(results[0], isNotNull);
      expect(results[0], results[1]);
      expect(fetchCalls, 1);
    });

    test('a pre-existing cache file is reused on a cold cache (disk hit)',
        () async {
      // Pre-write the file as if a previous run had cached it.
      final String key =
          sha256.convert(utf8.encode(_reference.toString())).toString();
      await cacheDir.create(recursive: true);
      final File seeded = File(p.join(cacheDir.path, '$key.img'));
      await seeded.writeAsBytes(_imageBytes, flush: true);

      int fetchCalls = 0;
      final cache = MediaArtworkCache(
        resolveUrl: (Uri reference) => _authUrl,
        fetch: (Uri url) async {
          fetchCalls++;
          return _imageBytes;
        },
        directory: directory,
      );

      final Uri? result = await cache.resolve(_reference);
      // Reused straight from disk as the content:// URI over the seeded file.
      expect(result, mediaArtworkContentUri(seeded));
      expect(result!.isScheme('content'), isTrue);
      // No fetch, and the credential was never read.
      expect(fetchCalls, 0);
    });

    test('a failed download can be retried (no negative caching)', () async {
      int attempt = 0;
      final cache = MediaArtworkCache(
        resolveUrl: (Uri reference) => _authUrl,
        fetch: (Uri url) async {
          attempt++;
          return attempt == 1 ? null : _imageBytes; // first fails, then works
        },
        directory: directory,
      );

      expect(await cache.resolve(_reference), isNull);
      final Uri? retried = await cache.resolve(_reference);
      expect(retried, isNotNull);
      expect(attempt, 2);
    });
  });

  group('MediaArtworkCache.cached', () {
    test('is null before a reference is resolved, then the cached file after',
        () async {
      final cache = MediaArtworkCache(
        resolveUrl: (Uri reference) => _authUrl,
        fetch: (Uri url) async => _imageBytes,
        directory: directory,
      );

      // Synchronous, side-effect-free: nothing fetched yet.
      expect(cache.cached(_reference), isNull);

      final Uri? resolved = await cache.resolve(_reference);
      // Now the warmed cover is available synchronously for the media handler.
      expect(cache.cached(_reference), isNotNull);
      expect(cache.cached(_reference), resolved);
      expect(cache.cached(_reference)!.isScheme('content'), isTrue);
    });

    test('stays null for a reference whose fetch failed', () async {
      final cache = MediaArtworkCache(
        resolveUrl: (Uri reference) => _authUrl,
        fetch: (Uri url) async => null, // failed download
        directory: directory,
      );

      await cache.resolve(_reference);
      expect(cache.cached(_reference), isNull);
    });

    test('is null for a different reference than the one resolved', () async {
      final cache = MediaArtworkCache(
        resolveUrl: (Uri reference) => _authUrl,
        fetch: (Uri url) async => _imageBytes,
        directory: directory,
      );

      await cache.resolve(_reference);
      expect(cache.cached(Uri.parse('subsonic-cover:other')), isNull);
    });
  });

  group('MediaArtworkCache.coverReady', () {
    test('emits the reference the moment a cover first caches', () async {
      final cache = MediaArtworkCache(
        resolveUrl: (Uri reference) => _authUrl,
        fetch: (Uri url) async => _imageBytes,
        directory: directory,
      );
      final List<Uri> ready = <Uri>[];
      final sub = cache.coverReady.listen(ready.add);
      addTearDown(sub.cancel);

      await cache.resolve(_reference);
      await pumpEventQueue();

      // Lets a now-playing item refresh immediately instead of on the next tick.
      expect(ready, <Uri>[_reference]);
    });

    test('does not emit when the fetch fails (no cover to show)', () async {
      final cache = MediaArtworkCache(
        resolveUrl: (Uri reference) => _authUrl,
        fetch: (Uri url) async => null, // failed download
        directory: directory,
      );
      final List<Uri> ready = <Uri>[];
      final sub = cache.coverReady.listen(ready.add);
      addTearDown(sub.cancel);

      await cache.resolve(_reference);
      await pumpEventQueue();

      expect(ready, isEmpty);
    });

    test('emits once even across repeat resolves (a memo hit never re-emits)',
        () async {
      final cache = MediaArtworkCache(
        resolveUrl: (Uri reference) => _authUrl,
        fetch: (Uri url) async => _imageBytes,
        directory: directory,
      );
      final List<Uri> ready = <Uri>[];
      final sub = cache.coverReady.listen(ready.add);
      addTearDown(sub.cancel);

      await cache.resolve(_reference);
      await cache.resolve(_reference); // served from the memo — no re-emit
      await pumpEventQueue();

      expect(ready, <Uri>[_reference]);
    });

    test('a late emit after dispose does not throw', () async {
      final cache = MediaArtworkCache(
        resolveUrl: (Uri reference) => _authUrl,
        fetch: (Uri url) async => _imageBytes,
        directory: directory,
      );
      await cache.dispose();
      // resolve still works (writes the file) and must not throw on the closed
      // ready controller.
      expect(await cache.resolve(_reference), isNotNull);
    });
  });
}
