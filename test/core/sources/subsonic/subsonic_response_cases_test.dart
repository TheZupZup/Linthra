import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/lyrics.dart';
import 'package:linthra/core/models/music_folder.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/subsonic/http_subsonic_client.dart';
import 'package:linthra/core/sources/subsonic/subsonic_api.dart';
import 'package:linthra/core/sources/subsonic/subsonic_auth.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';
import 'package:linthra/core/sources/subsonic/subsonic_folder_browser_source.dart';

/// Replays test/fixtures/subsonic_response_cases.txt: generated server
/// answers (well formed, odd and broken: repeated keys, numbers sent as
/// strings, a single entry for a list of one, a byte order mark, bytes that
/// aren't UTF-8, HTML, a body cut short), each through the public call that
/// reads it, with what the Dart client answered before reading moved to the
/// Rust core. A change here is a library, a playlist or a set of lyrics that
/// reads differently after an update.
void main() {
  test('every recorded answer reads the same', () async {
    final List<String> lines =
        File('test/fixtures/subsonic_response_cases.txt').readAsLinesSync();
    expect(lines, hasLength(greaterThan(500)));
    for (final String line in lines) {
      final Map<String, Object?> c = jsonDecode(line) as Map<String, Object?>;
      final String kind = c['kind']! as String;
      final Uint8List body = c.containsKey('body')
          ? Uint8List.fromList(utf8.encode(c['body']! as String))
          : base64.decode(c['bytes']! as String);
      expect(
        jsonDecode(jsonEncode(await run(kind, body))),
        c['result'],
        reason: line,
      );
    }
  });
}

const SubsonicSession _session = SubsonicSession(
  baseUrl: 'https://music.example.com',
  username: 'alice',
  salt: 'salt1',
  token: 'tok1',
);

String? iso(DateTime? d) => d?.toIso8601String();

Future<Object?> run(String kind, Uint8List body) async {
  final List<String> methods = <String>[];
  http.Response answer(http.Request request) {
    methods.add(request.method);
    final String path = request.url.path;
    if (kind == 'legacyLyrics' && path.endsWith('getLyricsBySongId.view')) {
      return http.Response(
          '{"subsonic-response":{"status":"failed","error":{"code":70}}}', 200);
    }
    if (kind == 'formPost' &&
        !path.endsWith('getOpenSubsonicExtensions.view')) {
      return http.Response('{"subsonic-response":{"status":"ok"}}', 200);
    }
    return http.Response.bytes(body, 200);
  }

  final MockClient mock = MockClient((http.Request r) async => answer(r));
  final HttpSubsonicClient client = HttpSubsonicClient(httpClient: mock);
  final SubsonicFolderBrowserSource folders =
      SubsonicFolderBrowserSource(session: _session, httpClient: mock);
  List<Object?> track(Track t) => <Object?>[
        t.id,
        t.uri,
        t.title,
        t.artistName,
        t.albumName,
        t.albumId,
        t.trackNumber,
        t.duration.inMicroseconds,
        t.artworkUri?.toString(),
        iso(t.serverAddedAt),
      ];
  List<Object?> listing(MusicFolderListing l) => <Object?>[
        <Object?>[
          for (final MusicFolder f in l.folders) <Object?>[f.id, f.name]
        ],
        <Object?>[for (final Track t in l.tracks) track(t)],
      ];
  List<Object?>? lyrics(Lyrics? l) => l == null
      ? null
      : <Object?>[
          for (final LyricLine line in l.lines)
            <Object?>[line.text, line.start?.inMicroseconds],
        ];
  try {
    switch (kind) {
      case 'ping':
        final SubsonicServerInfo info = await client.ping(_session.baseUrl,
            username: 'alice',
            credentials: const SubsonicCredentials(salt: 's', token: 't'));
        return <Object?>[info.apiVersion, info.type, info.serverVersion];
      case 'artists':
        return <Object?>[
          for (final SubsonicArtistDto a in await client.getArtists(_session))
            <Object?>[a.id, a.name, a.albumCount, a.coverArt],
        ];
      case 'albumList':
        final SubsonicAlbumPage page =
            await client.getAlbumListPage(_session, size: 500, offset: 0);
        return <Object?>[
          page.entryCount,
          <Object?>[
            for (final SubsonicAlbumDto a in page.albums)
              <Object?>[
                a.id,
                a.name,
                a.artist,
                a.songCount,
                a.year,
                iso(a.dateCreated),
                a.coverArt
              ],
          ],
        ];
      case 'albumSongs':
        return <Object?>[
          for (final SubsonicSongDto s
              in await client.getAlbumSongs(_session, 'al-1'))
            <Object?>[
              s.id,
              s.title,
              s.album,
              s.albumId,
              s.artist,
              s.track,
              s.durationSeconds,
              iso(s.dateCreated),
              s.coverArt
            ],
        ];
      case 'starred':
        return (await client.getStarredSongIds(_session)).toList();
      case 'playlists':
        return <Object?>[
          for (final SubsonicPlaylistDto p
              in await client.getPlaylists(_session))
            <Object?>[p.id, p.name],
        ];
      case 'playlistSongIds':
        return await client.getPlaylistSongIds(_session, 'pl-1');
      case 'createPlaylist':
        return await client.createPlaylist(_session, name: 'Mix');
      case 'formPost':
        await client.setPlaylistSongs(_session, 'pl-1',
            <String>[for (int i = 0; i < 400; i++) 'song-$i']);
        return methods.last;
      case 'structuredLyrics':
        return lyrics(await client.fetchLyrics(_session, 's-1'));
      case 'legacyLyrics':
        return lyrics(
            await client.fetchLyrics(_session, 's-1', artist: 'a', title: 't'));
      case 'musicFolders':
        return <Object?>[
          for (final MusicFolder f in await folders.fetchRootFolders())
            <Object?>[f.id, f.name],
        ];
      case 'indexes':
        return listing(await folders.fetchFolder('music-folder:1'));
      case 'directory':
        return listing(await folders.fetchFolder('directory:1'));
    }
    throw StateError(kind);
  } on SubsonicException catch (e) {
    return 'error:${e.kind.name}';
  }
}
