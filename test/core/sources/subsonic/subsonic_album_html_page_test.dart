// One Subsonic album answered with a web page fails that album only.
//
// A reverse proxy can answer a single request with an HTML page and a 200
// (a login wall, a WAF block on one album's id, an error page served with
// the wrong status). The client reads that as "not a Subsonic server", which
// is never transient, so the walk doesn't retry it. What decides the rest is
// the ping that follows: a server that still answers it is fine, so only the
// album failed (#740) and every other album is still delivered, with the
// walk left incomplete so nothing is pruned. When the ping gets the page as
// well, the whole server is behind it, and the walk ends with that.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/subsonic/subsonic_catalog_walk.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';
import 'package:linthra/core/sources/subsonic/subsonic_music_source.dart';

import 'synthetic_navidrome.dart';

const SubsonicSession _session = SubsonicSession(
  baseUrl: 'https://music.example.com',
  username: 'alice',
  salt: 'salt1',
  token: 'secret-token',
);

/// The production retry count, without the waits.
const List<Duration> _noWait = <Duration>[Duration.zero, Duration.zero];

const String _webPage = '<!DOCTYPE html><html><head><title>Access denied'
    '</title></head><body>Request blocked</body></html>';

/// A [SyntheticNavidrome] behind a proxy that answers `getAlbum` for
/// [pageAlbum], and the ping too when [pagePing] is set, with an HTML page
/// and a 200. Every request still reaches the server's counters.
class _ProxiedNavidrome extends SyntheticNavidrome {
  _ProxiedNavidrome({
    required super.albums,
    required this.pageAlbum,
    this.pagePing = false,
  });

  final int pageAlbum;
  final bool pagePing;

  @override
  Future<http.Response> handle(http.Request request) async {
    final http.Response answer = await super.handle(request);
    final String method = request.url.pathSegments.last.replaceAll('.view', '');
    final bool page = (method == 'getAlbum' &&
            request.url.queryParameters['id'] == 'al-$pageAlbum') ||
        (method == 'ping' && pagePing);
    if (!page) return answer;
    return http.Response(
      _webPage,
      200,
      headers: const <String, String>{'content-type': 'text/html'},
    );
  }
}

Future<SubsonicCatalogWalk> _walk(
  SyntheticNavidrome server,
  List<List<Track>> batches,
) =>
    SubsonicMusicSource(session: _session, client: server.client()).walkTracks(
      batchSize: 20,
      retryDelays: _noWait,
      onBatch: (List<Track> batch) async {
        batches.add(List<Track>.of(batch));
        return true;
      },
    );

Set<String> _uris(List<List<Track>> batches) => <String>{
      for (final List<Track> batch in batches)
        for (final Track track in batch) track.uri,
    };

void main() {
  test(
      'an album answered with a web page is left out after one attempt and '
      'one ping; the rest are delivered, the walk not complete', () async {
    final _ProxiedNavidrome server =
        _ProxiedNavidrome(albums: 20, pageAlbum: 7);
    final List<List<Track>> batches = <List<Track>>[];

    final SubsonicCatalogWalk walk = await _walk(server, batches);

    expect(walk.failedAlbumCount, 1);
    expect(walk.missingAlbumCount, 0);
    expect(walk.isComplete, isFalse, reason: 'nothing may be pruned');
    // The next walk would get the same page.
    expect(walk.worthResuming, isFalse);
    expect(
      _uris(batches),
      server.urisFor('alice', exceptAlbums: <int>{7}),
    );
    // One getAlbum per album: the page is not retried.
    expect(server.albumCalls, 20);
    expect(server.calls['ping'], 1);
  });

  test('a ping answered with the same page ends the walk as notSubsonic',
      () async {
    final _ProxiedNavidrome server =
        _ProxiedNavidrome(albums: 20, pageAlbum: 7, pagePing: true);
    final List<List<Track>> batches = <List<Track>>[];

    await expectLater(
      _walk(server, batches),
      throwsA(isA<SubsonicException>().having(
        (SubsonicException e) => e.kind,
        'kind',
        SubsonicErrorKind.notSubsonic,
      )),
    );
    // Albums 0 to 6 were read, two to a batch: the three full batches were
    // handed out before the walk ended, and nothing after album 7 was asked
    // for.
    expect(server.albumCalls, 8);
    expect(server.calls['ping'], 1);
    expect(_uris(batches), hasLength(60));
    expect(
      server.urisFor('alice').containsAll(_uris(batches)),
      isTrue,
    );
  });
}
