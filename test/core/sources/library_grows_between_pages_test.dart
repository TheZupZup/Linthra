// A library walked page by page can grow between two page requests: a
// server-side scan adds an item that sorts ahead of the page boundary, and
// every item after it moves down one place. The item that was last on the
// page already read is then first on the next page too. Listed twice, it
// would reach the catalog as two rows of one track; the walk has to list it
// once and still stop on the server's (new) total.
//
// The mirror of library_changes_between_pages_test.dart, which covers a
// library that shrinks.

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

/// A server-side library that gains an item at the front once the first page
/// has been served.
class _GrowingLibrary {
  _GrowingLibrary(int count)
      : items = <String>[for (int i = 0; i < count; i++) 't$i'];

  final List<String> items;
  int pagesServed = 0;

  /// Inserted at the front once the first page has been served.
  String? addAfterFirstPage;

  List<String> page(int start, int size) {
    final int from = start.clamp(0, items.length);
    final int to = (start + size).clamp(from, items.length);
    return items.sublist(from, to);
  }

  void served() {
    pagesServed++;
    if (pagesServed == 1 && addAfterFirstPage != null) {
      items.insert(0, addAfterFirstPage!);
    }
  }
}

void main() {
  test(
      'Jellyfin: an item added ahead of the page boundary between two pages '
      'does not list the item pushed across it twice', () async {
    const JellyfinSession session = JellyfinSession(
      baseUrl: 'https://music.example.com',
      userId: 'user-1',
      accessToken: 'tok',
      deviceId: 'device-1',
    );
    final _GrowingLibrary library = _GrowingLibrary(6)
      ..addAfterFirstPage = 'a-new';
    final List<int> starts = <int>[];
    final HttpJellyfinClient client = HttpJellyfinClient(
      httpClient: MockClient((http.Request request) async {
        final int start =
            int.parse(request.url.queryParameters['StartIndex'] ?? '0');
        final int limit = int.parse(request.url.queryParameters['Limit']!);
        starts.add(start);
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

    // t1 is served on the first page and again on the second; listed once.
    // The new item sorted ahead of what was read and is left for the next
    // sync.
    expect(
      listing.items.map((JellyfinItemDto i) => i.id).toList(),
      <String>['t0', 't1', 't2', 't3', 't4', 't5'],
    );
    expect(listing.skippedCount, 0);
    // No step back for a library that grew; the walk ends on the new total.
    expect(starts, <int>[0, 2, 4, 6]);
  });

  test(
      'Plex: an item added ahead of the page boundary between two pages does '
      'not list the item pushed across it twice', () async {
    final _GrowingLibrary library = _GrowingLibrary(6)
      ..addAfterFirstPage = 'a-new';
    final List<int> starts = <int>[];
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
        starts.add(start);
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

    expect(
      items.map((PlexMetadata m) => m.ratingKey).toList(),
      <String>['t0', 't1', 't2', 't3', 't4', 't5'],
    );
    expect(starts, <int>[0, 2, 4, 6]);
  });
}
