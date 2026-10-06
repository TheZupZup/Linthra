// A library walked page by page can change between two page requests: a
// server-side scan removes an item listed ahead of the page boundary, and
// every item after it moves up one place. Read naively, the item that moves
// across the boundary is never listed, although it is still on the server,
// and the sync then replaces the catalog without it. The server's own total
// says the library shrank, so the walk can tell.
//
// The same thing the Subsonic walk guards against for its album list (#752).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/sources/jellyfin/http_jellyfin_client.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/plex/http_plex_client.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_client.dart';
import 'package:linthra/core/sources/plex/plex_endpoints.dart';

/// A server-side library that can lose an item between two page requests.
class _ShrinkingLibrary {
  _ShrinkingLibrary(int count)
      : items = <String>[for (int i = 0; i < count; i++) 't$i'];

  final List<String> items;
  int pagesServed = 0;

  /// Removed once the first page has been served.
  String? removeAfterFirstPage;

  List<String> page(int start, int size) {
    final int from = start.clamp(0, items.length);
    final int to = (start + size).clamp(from, items.length);
    final List<String> served = items.sublist(from, to);
    return served;
  }

  void served() {
    pagesServed++;
    if (pagesServed == 1 && removeAfterFirstPage != null) {
      items.remove(removeAfterFirstPage);
    }
  }
}

void main() {
  group('Jellyfin item paging', () {
    const JellyfinSession session = JellyfinSession(
      baseUrl: 'https://music.example.com',
      userId: 'user-1',
      accessToken: 'tok',
      deviceId: 'device-1',
    );

    test(
        'an item removed ahead of the page boundary between two pages does '
        'not lose the item that moved across it', () async {
      final _ShrinkingLibrary library = _ShrinkingLibrary(6)
        ..removeAfterFirstPage = 't0';
      final HttpJellyfinClient client = HttpJellyfinClient(
        httpClient: MockClient((http.Request request) async {
          final int start =
              int.parse(request.url.queryParameters['StartIndex'] ?? '0');
          final int limit =
              int.parse(request.url.queryParameters['Limit'] ?? '2');
          final List<String> page = library.page(start, limit);
          final int total = library.items.length;
          library.served();
          return http.Response(
            jsonEncode(<String, dynamic>{
              'Items': <Map<String, dynamic>>[
                for (final String id in page)
                  <String, dynamic>{'Id': id, 'Name': 'Track $id'},
              ],
              'TotalRecordCount': total,
            }),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }),
        itemPageSize: 2,
        retryBackoff: Duration.zero,
        pageGap: Duration.zero,
      );

      final JellyfinItemListing listing =
          await client.fetchItems(session, kind: JellyfinItemKind.audio);
      final List<String> ids =
          listing.items.map((JellyfinItemDto i) => i.id).toList();

      // t1..t5 were on the server for the whole walk.
      expect(ids, containsAll(<String>['t1', 't2', 't3', 't4', 't5']));
      expect(ids.toSet(), hasLength(ids.length), reason: 'each listed once');
    });
  });

  group('Plex section paging', () {
    test(
        'an item removed ahead of the page boundary between two pages does '
        'not lose the item that moved across it', () async {
      final _ShrinkingLibrary library = _ShrinkingLibrary(6)
        ..removeAfterFirstPage = 't0';
      final HttpPlexClient client = HttpPlexClient(
        identity: const PlexClientIdentity(
          clientIdentifier: 'install-1',
          product: 'Linthra',
          version: '0.0.0',
          platform: 'Linux',
          device: 'Test',
        ),
        pageSize: 2,
        httpClient: MockClient((http.Request request) async {
          final int start = int.parse(
              request.url.queryParameters[PlexEndpoints.containerStartParam]!);
          final int size = int.parse(
              request.url.queryParameters[PlexEndpoints.containerSizeParam]!);
          final List<String> page = library.page(start, size);
          final int total = library.items.length;
          library.served();
          return http.Response(
            jsonEncode(<String, dynamic>{
              'MediaContainer': <String, dynamic>{
                'size': page.length,
                'totalSize': total,
                'offset': start,
                'Metadata': <Map<String, dynamic>>[
                  for (final String id in page)
                    <String, dynamic>{'ratingKey': id, 'type': 'track'},
                ],
              },
            }),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      final List<PlexMetadata> items = await client.fetchSectionItems(
        baseUrl: 'https://plex.example.com:32400',
        token: 'tok',
        sectionKey: '3',
        itemType: PlexMetadataType.track,
      );
      final List<String> keys =
          items.map((PlexMetadata m) => m.ratingKey).toList();

      // t1..t5 were on the server for the whole walk.
      expect(keys, containsAll(<String>['t1', 't2', 't3', 't4', 't5']));
      expect(keys.toSet(), hasLength(keys.length), reason: 'each listed once');
    });
  });
}
