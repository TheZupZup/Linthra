// A Jellyfin library walk whose later page isn't Jellyfin's answer fails.
//
// A reverse proxy or Cloudflare can answer any single request with a 200 of
// its own: an HTML challenge page, or JSON of a shape that isn't the `/Items`
// envelope. On the first page that reads as "not a Jellyfin server"; on a
// later one it has to fail the same way, after exactly the pages asked for.
// Returned instead, the pages read so far would replace the whole catalog.
// A 2xx is the server's settled answer, so the page retry (meant for 5xx,
// 408, 429 and transport failures) doesn't repeat it.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/sources/jellyfin/http_jellyfin_client.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';

const JellyfinSession _session = JellyfinSession(
  baseUrl: 'https://music.example.com',
  userId: 'user-1',
  accessToken: 'tok-abc',
  deviceId: 'device-1',
);

/// A four-track library served two per page, with three attempts per page
/// and no waits: page 0 answers normally, every later page with [laterPage].
/// Records the StartIndex of each request in [starts].
HttpJellyfinClient _walkClient(
  List<int> starts,
  http.Response Function() laterPage,
) =>
    HttpJellyfinClient(
      httpClient: MockClient((http.Request request) async {
        final int start =
            int.parse(request.url.queryParameters['StartIndex'] ?? '0');
        starts.add(start);
        if (start != 0) return laterPage();
        return http.Response(
          jsonEncode(<String, dynamic>{
            'Items': <Map<String, dynamic>>[
              <String, dynamic>{'Id': 't1', 'Name': 'One'},
              <String, dynamic>{'Id': 't2', 'Name': 'Two'},
            ],
            'TotalRecordCount': 4,
          }),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      }),
      itemPageSize: 2,
      maxItemFetchAttempts: 3,
      retryBackoff: Duration.zero,
      pageGap: Duration.zero,
    );

Matcher get _throwsNotJellyfin => throwsA(isA<JellyfinException>().having(
      (JellyfinException e) => e.kind,
      'kind',
      JellyfinErrorKind.notJellyfin,
    ));

void main() {
  test(
      'a 200 HTML challenge page on the second page fails the walk as '
      'notJellyfin, unretried', () async {
    final List<int> starts = <int>[];
    final HttpJellyfinClient client = _walkClient(
      starts,
      () => http.Response(
        '<!DOCTYPE html><html><head><title>Just a moment...</title></head>'
        '<body>Checking your browser</body></html>',
        200,
        headers: const <String, String>{'content-type': 'text/html'},
      ),
    );

    await expectLater(
      client.fetchItems(_session, kind: JellyfinItemKind.audio),
      _throwsNotJellyfin,
    );
    expect(starts, <int>[0, 2]);
  });

  test(
      'a JSON array body on the second page fails the walk as notJellyfin, '
      'unretried', () async {
    final List<int> starts = <int>[];
    final HttpJellyfinClient client = _walkClient(
      starts,
      () => http.Response(
        jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{'Id': 't3', 'Name': 'Three'},
          <String, dynamic>{'Id': 't4', 'Name': 'Four'},
        ]),
        200,
        headers: const <String, String>{'content-type': 'application/json'},
      ),
    );

    await expectLater(
      client.fetchItems(_session, kind: JellyfinItemKind.audio),
      _throwsNotJellyfin,
    );
    expect(starts, <int>[0, 2]);
  });
}
