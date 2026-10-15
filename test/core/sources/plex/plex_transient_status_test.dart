// A Plex rate limit (429) or request timeout (408) is a server error.
//
// HttpPlexClient._checkStatus mapped every 4xx other than 401/403/404 to
// notPlex, so a reverse proxy rate-limiting a large section walk told the
// user "That server didn't respond like a Plex Media Server. Double-check the
// server address". Jellyfin and Subsonic map 408/429 to serverError on
// purpose: both are transient, not a wrong address.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/sources/plex/http_plex_client.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_client.dart';
import 'package:linthra/core/sources/plex/plex_exception.dart';

void main() {
  for (final int status in <int>[429, 408]) {
    test('a $status on a section page is a transient server error', () async {
      final HttpPlexClient client = HttpPlexClient(
        identity: const PlexClientIdentity(
          clientIdentifier: 'install-1',
          product: 'Linthra',
          version: '0.0.0',
          platform: 'Linux',
          device: 'Test',
        ),
        httpClient: MockClient((_) async => http.Response('slow down', status)),
      );

      await expectLater(
        client.fetchSectionItems(
          baseUrl: 'https://plex.example.com:32400',
          token: 'tok',
          sectionKey: '5',
          itemType: PlexMetadataType.track,
        ),
        throwsA(isA<PlexException>().having(
          (PlexException e) => e.kind,
          'kind',
          PlexErrorKind.serverError,
        )),
      );
    });
  }
}
