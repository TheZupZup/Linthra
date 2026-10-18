import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/sources/subsonic/subsonic_folder_browser_source.dart';

void main() {
  const SubsonicSession session = SubsonicSession(
    baseUrl: 'https://music.example.test',
    username: 'listener',
    salt: 'salt-value',
    token: 'secret-token',
    serverType: 'navidrome',
  );

  test('walks music folder to index without exposing credentials in ids',
      () async {
    final MockClient client = MockClient((http.Request request) async {
      expect(request.url.queryParameters['u'], 'listener');
      expect(request.url.queryParameters['s'], 'salt-value');
      expect(request.url.queryParameters['t'], 'secret-token');
      switch (request.url.path) {
        case '/rest/getMusicFolders.view':
          return _ok(<String, Object>{
            'musicFolders': <String, Object>{
              'musicFolder': <Object>[
                <String, Object>{'id': '1', 'name': 'Main Music'},
              ],
            },
          });
        case '/rest/getIndexes.view':
          expect(request.url.queryParameters['musicFolderId'], '1');
          return _ok(<String, Object>{
            'indexes': <String, Object>{
              'index': <Object>[
                <String, Object>{
                  'name': 'A',
                  'artist': <Object>[
                    <String, Object>{'id': 'artist-1', 'name': 'An Artist'},
                  ],
                },
              ],
            },
          });
        default:
          fail('Unexpected path: ${request.url.path}');
      }
    });
    final SubsonicFolderBrowserSource source = SubsonicFolderBrowserSource(
      session: session,
      httpClient: client,
    );
    addTearDown(source.close);

    final roots = await source.fetchRootFolders();
    final listing = await source.fetchFolder(roots.single.id);

    expect(roots.single.id, 'music-folder:1');
    expect(listing.folders.single.id, 'directory:artist-1');
    expect(roots.single.id, isNot(contains('secret-token')));
    expect(listing.folders.single.id, isNot(contains('secret-token')));
  });

  test('maps child directories and songs from getMusicDirectory', () async {
    final MockClient client = MockClient((http.Request request) async {
      expect(request.url.path, '/rest/getMusicDirectory.view');
      expect(request.url.queryParameters['id'], 'artist-1');
      return _ok(<String, Object>{
        'directory': <String, Object>{
          'child': <Object>[
            <String, Object>{
              'id': 'album-1',
              'title': 'An Album',
              'isDir': true,
            },
            <String, Object>{
              'id': 'song-1',
              'title': 'A Song',
              'album': 'An Album',
              'artist': 'An Artist',
              'track': 1,
              'duration': 180,
              'isDir': false,
            },
          ],
        },
      });
    });
    final SubsonicFolderBrowserSource source = SubsonicFolderBrowserSource(
      session: session,
      httpClient: client,
    );
    addTearDown(source.close);

    final listing = await source.fetchFolder('directory:artist-1');

    expect(listing.folders.single.id, 'directory:album-1');
    expect(listing.tracks.single.title, 'A Song');
    expect(listing.tracks.single.uri, 'subsonic:song-1');
  });

  test('a legacy session browses with the hex-encoded password only', () async {
    final List<Uri> requested = <Uri>[];
    final MockClient client = MockClient((http.Request request) async {
      requested.add(request.url);
      return _ok(<String, Object>{
        'musicFolders': <String, Object>{'musicFolder': <Object>[]},
      });
    });

    await SubsonicFolderBrowserSource(
      session: const SubsonicSession(
        baseUrl: 'https://cloud.example.test',
        username: 'listener',
        isLegacy: true,
        password: 'api-key',
      ),
      httpClient: client,
    ).fetchRootFolders();

    final Map<String, String> query = requested.single.queryParameters;
    expect(query['p'], 'enc:6170692d6b6579');
    expect(query.containsKey('t'), isFalse);
    expect(query.containsKey('s'), isFalse);
  });
}

http.Response _ok(Map<String, Object> payload) {
  return http.Response(
    jsonEncode(<String, Object>{
      'subsonic-response': <String, Object>{
        'status': 'ok',
        'version': '1.16.1',
        ...payload,
      },
    }),
    200,
  );
}
