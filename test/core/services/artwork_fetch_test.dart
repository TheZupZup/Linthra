import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/services/artwork_disk_cache.dart';
import 'package:linthra/core/services/artwork_fetch.dart';
import 'package:linthra/core/services/media_artwork_cache.dart';
import 'package:linthra/core/sources/subsonic/subsonic_artwork.dart';

/// Bytes that start like a PNG, which is all the caches check before saving.
const List<int> _cover = <int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4];

final Uri _reference = SubsonicArtwork.reference('al-1');

/// The cover URL a legacy password session resolves the reference to.
final Uri _passwordCover = SubsonicArtwork.resolve(
  _reference,
  const SubsonicSession.password(
    baseUrl: 'https://cloud.example.com',
    username: 'alice',
    password: 'app-password',
  ),
)!;

/// And the one a salt + token session does, which loads as it always has.
final Uri _tokenCover = SubsonicArtwork.resolve(
  _reference,
  const SubsonicSession(
    baseUrl: 'https://music.example.com',
    username: 'alice',
    salt: 'salt',
    token: 'token',
  ),
)!;

http.Response _redirect() => http.Response('', 302, headers: <String, String>{
      'location': 'http://elsewhere.example.net/steal',
    });

void main() {
  late List<http.Request> requests;
  setUp(() => requests = <http.Request>[]);

  MockClient answering(http.Response Function() answer) =>
      MockClient((http.Request request) async {
        requests.add(request);
        return answer();
      });

  group('getCover', () {
    test('a password cover is not fetched through a redirect', () async {
      final http.Response response =
          await getCover(answering(_redirect), _passwordCover);

      expect(coverMayFollowRedirects(_passwordCover), isFalse);
      expect(response.statusCode, 302);
      expect(requests.single.url, _passwordCover);
      expect(requests.single.followRedirects, isFalse);
    });

    test('a token cover loads as it always has', () async {
      await getCover(
        answering(() => http.Response.bytes(_cover, 200)),
        _tokenCover,
      );

      expect(coverMayFollowRedirects(_tokenCover), isTrue);
      expect(requests.single.followRedirects, isTrue);
    });
  });

  group('the artwork caches', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('artwork_fetch_test');
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('the disk cache keeps nothing a redirect answered', () async {
      final ArtworkDiskCache cache = ArtworkDiskCache(
        directory: dir,
        resolveFetchUrl: (_) => _passwordCover,
        httpClient: answering(_redirect),
      );

      await cache.warm(_reference);

      expect(requests.single.followRedirects, isFalse);
      expect(cache.cachedFile(_reference), isNull);
    });

    test('the disk cache still keeps a password cover served directly',
        () async {
      final ArtworkDiskCache cache = ArtworkDiskCache(
        directory: dir,
        resolveFetchUrl: (_) => _passwordCover,
        httpClient: answering(() => http.Response.bytes(_cover, 200,
            headers: const <String, String>{'content-type': 'image/png'})),
      );

      await cache.warm(_reference);

      expect(requests.single.followRedirects, isFalse);
      expect(cache.cachedFile(_reference), isNotNull);
    });

    test('the media session cache gets no cover from a redirect', () async {
      final MediaArtworkCache cache = MediaArtworkCache(
        resolveUrl: (_) => _passwordCover,
        directory: () async => dir,
        httpClient: answering(_redirect),
      );
      addTearDown(cache.dispose);

      expect(await cache.resolve(_reference), isNull);
      expect(requests.single.url, _passwordCover);
      expect(requests.single.followRedirects, isFalse);
    });
  });
}
