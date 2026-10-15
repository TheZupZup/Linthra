// A Plex section that fails on a later page fails as a whole.
//
// `fetchSectionItems` reads a section page by page and retries nothing. When
// the first page lands and the second does not (the connection drops, a
// proxy answers with its own HTML page), the walk must throw the typed
// failure for that page, after exactly the two pages it asked for. Returning
// the first page instead would hand the sync half a section to replace the
// whole catalog with, and the prune after it would drop the rest. A server
// error on that page is driven end to end, through the sync, in
// plex_partial_scan_failure_test.dart.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/sources/plex/http_plex_client.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_client.dart';
import 'package:linthra/core/sources/plex/plex_endpoints.dart';
import 'package:linthra/core/sources/plex/plex_exception.dart';

const String _base = 'https://plex.example.com:32400';
const String _token = 'super-secret-plex-token';

const PlexClientIdentity _identity = PlexClientIdentity(
  clientIdentifier: 'install-uuid-1',
  product: 'Linthra',
  version: '0.1.5',
  platform: 'Android',
  device: 'Pixel',
);

/// A four-track section served two per page: page 0 answers normally, and
/// every later page answers with [laterPage]. Records the start offset of
/// each request in [starts].
HttpPlexClient _sectionClient(
  List<String?> starts,
  Future<http.Response> Function() laterPage,
) =>
    HttpPlexClient(
      identity: _identity,
      pageSize: 2,
      httpClient: MockClient((http.Request request) async {
        final String? start =
            request.url.queryParameters[PlexEndpoints.containerStartParam];
        starts.add(start);
        if (start != '0') return laterPage();
        return http.Response(
          jsonEncode(<String, dynamic>{
            'MediaContainer': <String, dynamic>{
              'size': 2,
              'totalSize': 4,
              'offset': 0,
              'Metadata': <dynamic>[
                <String, dynamic>{'ratingKey': '1', 'type': 'track'},
                <String, dynamic>{'ratingKey': '2', 'type': 'track'},
              ],
            },
          }),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      }),
    );

Future<List<PlexMetadata>> _walk(HttpPlexClient client) =>
    client.fetchSectionItems(
      baseUrl: _base,
      token: _token,
      sectionKey: '3',
      itemType: PlexMetadataType.track,
    );

Matcher _throwsKind(PlexErrorKind kind) => throwsA(
      isA<PlexException>().having((PlexException e) => e.kind, 'kind', kind),
    );

void main() {
  group('a section walk whose second page fails', () {
    test(
        'a dropped connection fails the walk as notReachable after two '
        'requests', () async {
      final List<String?> starts = <String?>[];
      final HttpPlexClient client = _sectionClient(
        starts,
        () async => throw http.ClientException('Connection reset by peer'),
      );

      await expectLater(_walk(client), _throwsKind(PlexErrorKind.notReachable));
      expect(starts, <String>['0', '2']);
    });

    test('a 200 HTML page fails the walk as notPlex after two requests',
        () async {
      // A captive portal or a proxy's error page, sent with a 200.
      final List<String?> starts = <String?>[];
      final HttpPlexClient client = _sectionClient(
        starts,
        () async => http.Response(
          '<html><body>Please sign in to the network</body></html>',
          200,
          headers: const <String, String>{'content-type': 'text/html'},
        ),
      );

      await expectLater(_walk(client), _throwsKind(PlexErrorKind.notPlex));
      expect(starts, <String>['0', '2']);
    });
  });
}
