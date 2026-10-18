import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/artwork_disk_cache.dart';
import 'package:linthra/core/services/media_artwork_cache.dart';
import 'package:linthra/core/sources/subsonic/http_subsonic_client.dart';
import 'package:linthra/core/sources/subsonic/subsonic_artwork.dart';
import 'package:linthra/core/sources/subsonic/subsonic_auth.dart';
import 'package:linthra/core/sources/subsonic/subsonic_endpoints.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';
import 'package:linthra/core/sources/subsonic/subsonic_folder_browser_source.dart';
import 'package:linthra/core/sources/subsonic/subsonic_music_source.dart';
import 'package:linthra/core/sources/subsonic/subsonic_stream_source.dart';
import 'package:linthra/core/sources/subsonic/subsonic_track_downloader.dart';
import 'package:linthra/shared/widgets/artwork_image.dart';
import 'package:linthra/shared/widgets/unredirected_network_image.dart';

/// Answers every request with a valid `ping`-shaped Subsonic envelope (and
/// image-looking bytes for covers), recording what reached it.
class _Elsewhere {
  _Elsewhere._(this._server);

  static Future<_Elsewhere> start() async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final _Elsewhere self = _Elsewhere._(server);
    server.listen((HttpRequest request) async {
      self.seen.add(request.uri);
      if (request.uri.path.contains('getCoverArt')) {
        request.response
          ..headers.contentType = ContentType('image', 'png')
          ..add(<int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);
      } else {
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(<String, Object>{
            'subsonic-response': <String, Object>{
              'status': 'ok',
              'version': '1.16.1',
            },
          }));
      }
      await request.response.close();
    });
    return self;
  }

  final HttpServer _server;
  final List<Uri> seen = <Uri>[];

  /// A different host name for the same loopback server, so a redirect here is
  /// a redirect to another host, over plain http.
  String get origin => 'http://localhost:${_server.port}';

  Future<void> close() => _server.close(force: true);
}

/// The worst-case proxy: answers everything with a 302 to [_Elsewhere],
/// carrying the original path and query (password included) across.
class _RedirectingOrigin {
  _RedirectingOrigin._(this._server);

  static Future<_RedirectingOrigin> start(_Elsewhere target) async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final _RedirectingOrigin self = _RedirectingOrigin._(server);
    server.listen((HttpRequest request) async {
      self.requests++;
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(
          HttpHeaders.locationHeader,
          '${target.origin}${request.uri.path}?${request.uri.query}',
        );
      await request.response.close();
    });
    return self;
  }

  final HttpServer _server;
  int requests = 0;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);
}

class _FixedStreamSource implements SubsonicStreamSource {
  _FixedStreamSource(this.uri);

  final Uri uri;

  @override
  Future<void> verifyReachable() async {}

  @override
  Future<Uri?> resolvePlayableUri(Track track) async => uri;

  @override
  Future<Uri?> resolveDownloadUri(Track track) async => uri;
}

const Track _track = Track(id: 's1', title: 'One', uri: 'subsonic:s1');
const String _password = 'api-key-123';

Matcher get _refusedRedirect => throwsA(isA<SubsonicException>().having(
    (SubsonicException e) => e.kind,
    'kind',
    SubsonicErrorKind.insecureConnection));

void main() {
  late _Elsewhere elsewhere;
  late _RedirectingOrigin origin;
  late SubsonicSession legacy;
  late SubsonicSession token;

  setUp(() async {
    elsewhere = await _Elsewhere.start();
    origin = await _RedirectingOrigin.start(elsewhere);
    // Built directly: the https rule lives in sign-in and restore, and these
    // local servers speak plain http.
    legacy = SubsonicSession(
      baseUrl: origin.baseUrl,
      username: 'alice',
      isLegacy: true,
      password: _password,
    );
    token = SubsonicSession(
      baseUrl: origin.baseUrl,
      username: 'alice',
      salt: 'salt1',
      token: 'tok1',
    );
  });

  tearDown(() async {
    installArtworkReferenceResolver(null);
    await origin.close();
    await elsewhere.close();
  });

  /// Nothing carrying the password reached the other host.
  void expectPasswordStayedHome() {
    expect(origin.requests, greaterThan(0));
    expect(elsewhere.seen, isEmpty);
  }

  Uri cover(SubsonicSession session) =>
      SubsonicArtwork.resolve(SubsonicArtwork.reference('al-1'), session)!;

  group('a legacy password never follows a redirect', () {
    test('API requests', () async {
      final HttpSubsonicClient client =
          HttpSubsonicClient(httpClient: http.Client());

      await expectLater(
        client.ping(
          legacy.baseUrl,
          username: 'alice',
          credentials: const SubsonicCredentials.legacy(_password),
        ),
        _refusedRedirect,
      );
      await expectLater(client.getArtists(legacy), _refusedRedirect);
      expectPasswordStayedHome();
    });

    test('lyrics, which read a refused redirect as no lyrics', () async {
      final HttpSubsonicClient client =
          HttpSubsonicClient(httpClient: http.Client());

      expect(
        await client.fetchLyrics(legacy, 's1', artist: 'a', title: 't'),
        isNull,
      );
      expectPasswordStayedHome();
    });

    test('the stream check, so the audio engine never gets the URL', () async {
      final SubsonicMusicSource source = SubsonicMusicSource(
        session: legacy,
        client: HttpSubsonicClient(httpClient: http.Client()),
      );

      await expectLater(source.resolvePlayableUri(_track), _refusedRedirect);
      expectPasswordStayedHome();
    });

    test('folder browsing', () async {
      final SubsonicFolderBrowserSource browser = SubsonicFolderBrowserSource(
        session: legacy,
        httpClient: http.Client(),
      );

      await expectLater(browser.fetchRootFolders(), _refusedRedirect);
      expectPasswordStayedHome();
    });

    test('downloads', () async {
      final Uri download = SubsonicEndpoints.download(
        legacy.baseUrl,
        username: 'alice',
        credentials: const SubsonicCredentials.legacy(_password),
        songId: 's1',
      );
      final SubsonicTrackDownloader downloader = SubsonicTrackDownloader(
        () => _FixedStreamSource(download),
        httpClient: http.Client(),
      );

      await expectLater(downloader.fetch(_track), throwsStateError);
      expectPasswordStayedHome();
    });

    test('the artwork disk cache', () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('legacy_redirect_disk');
      addTearDown(() => dir.delete(recursive: true));
      final Uri reference = SubsonicArtwork.reference('al-1');
      final ArtworkDiskCache cache = ArtworkDiskCache(
        directory: dir,
        resolveFetchUrl: (_) => cover(legacy),
        httpClient: http.Client(),
      );

      await cache.warm(reference);

      expect(cache.cachedFile(reference), isNull);
      expectPasswordStayedHome();
    });

    test('the media session cover cache', () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('legacy_redirect_media');
      addTearDown(() => dir.delete(recursive: true));
      final MediaArtworkCache cache = MediaArtworkCache(
        resolveUrl: (_) => cover(legacy),
        directory: () async => dir,
        httpClient: http.Client(),
      );
      addTearDown(cache.dispose);

      expect(await cache.resolve(SubsonicArtwork.reference('al-1')), isNull);
      expectPasswordStayedHome();
    });

    test('the in-app cover', () async {
      installArtworkReferenceResolver(
          (Uri uri) => SubsonicArtwork.resolve(uri, legacy));
      final ImageProvider provider =
          artworkImageProvider(SubsonicArtwork.reference('al-1'));

      expect(provider, isA<UnredirectedNetworkImage>());
      expect(provider.toString(), isNot(contains(_password)));
      await expectLater(
        UnredirectedNetworkImage.fetch(
            (provider as UnredirectedNetworkImage).url),
        throwsA(isA<UnredirectedImageException>()),
      );
      expectPasswordStayedHome();
    });
  });

  group('token sign-in is unchanged', () {
    test('API requests still follow a redirect', () async {
      final HttpSubsonicClient client =
          HttpSubsonicClient(httpClient: http.Client());

      await client.ping(
        token.baseUrl,
        username: 'alice',
        credentials: const SubsonicCredentials(salt: 'salt1', token: 'tok1'),
      );

      expect(elsewhere.seen.single.queryParameters['t'], 'tok1');
    });

    test('the in-app cover still uses NetworkImage', () {
      installArtworkReferenceResolver(
          (Uri uri) => SubsonicArtwork.resolve(uri, token));

      expect(artworkImageProvider(SubsonicArtwork.reference('al-1')),
          isA<NetworkImage>());
    });
  });

  test('carriesPassword reads only a p parameter', () {
    bool carries(String url) =>
        SubsonicEndpoints.carriesPassword(Uri.parse(url));

    expect(carries('https://h/rest/ping.view?u=a&p=x'), isTrue);
    expect(carries('https://h/rest/ping.view?p=x&u=a'), isTrue);
    expect(carries('https://h/rest/ping.view?u=a&t=x&s=y'), isFalse);
    expect(carries('https://h/Items/1/Images/Primary?pp=1&np=2'), isFalse);
    expect(carries('https://h/cover?bad=%zz'), isFalse);
  });
}
