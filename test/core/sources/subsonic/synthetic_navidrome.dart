import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/sources/subsonic/http_subsonic_client.dart';
import 'package:linthra/core/sources/subsonic/subsonic_track_mapper.dart';

/// A fake Navidrome that serves a synthetic library of [albums] albums with
/// [songsPerAlbum] songs each, as real Subsonic JSON, so tests drive the real
/// [HttpSubsonicClient] (URL building, envelope parsing, error mapping) instead
/// of a hand-rolled client. Built for issue #680: tens of thousands of tracks
/// cost next to nothing to generate, and failures can be injected at exact
/// points of a walk.
///
/// Song ids embed the requesting username, so two accounts on the same server
/// see disjoint catalogs (an account switch is observable in the rows).
class SyntheticNavidrome {
  SyntheticNavidrome({
    required this.albums,
    this.songsPerAlbum = 10,
    this.ignoreOffset = false,
    Set<int>? missingAlbums,
    Set<int>? failingAlbumCalls,
    this.failAlbumCallsFrom,
    this.serverErrorAlbumCalls = const <int>{},
    this.rejectCredentialsFromAlbumCall,
    this.stallAtAlbumCall,
  })  : missingAlbums = missingAlbums ?? <int>{},
        failingAlbumCalls = failingAlbumCalls ?? <int>{};

  final int albums;
  final int songsPerAlbum;

  /// Serve the first page for every `offset`: the runaway-pagination case the
  /// album page cap exists for.
  final bool ignoreOffset;

  /// Album indexes whose `getAlbum` answers Subsonic error 70 (not found), as
  /// if removed on the server after the album list was read.
  final Set<int> missingAlbums;

  /// 1-based `getAlbum` call numbers that fail at the transport level (a reset
  /// socket), once each.
  final Set<int> failingAlbumCalls;

  /// From this 1-based `getAlbum` call on, every call fails at the transport
  /// level: the network went away (or Android froze the app) mid-walk.
  final int? failAlbumCallsFrom;

  /// 1-based `getAlbum` call numbers that answer HTTP 503, once each.
  final Set<int> serverErrorAlbumCalls;

  /// From this 1-based `getAlbum` call on, the server rejects the credential
  /// (Subsonic error 40): a failure no retry can fix.
  final int? rejectCredentialsFromAlbumCall;

  /// The 1-based `getAlbum` call that blocks until [releaseStall] (or forever,
  /// standing in for a process that was killed mid-request).
  final int? stallAtAlbumCall;

  final Completer<void> _stall = Completer<void>();
  final Completer<void> _stalled = Completer<void>();

  /// Completes when the walk reaches [stallAtAlbumCall].
  Future<void> get stalled => _stalled.future;

  void releaseStall() {
    if (!_stall.isCompleted) _stall.complete();
  }

  /// Requests served, by Subsonic method name.
  final Map<String, int> calls = <String, int>{};
  int get albumCalls => calls['getAlbum'] ?? 0;
  int get albumListCalls => calls['getAlbumList2'] ?? 0;

  int get trackCount => albums * songsPerAlbum;

  /// A real client talking to this server.
  HttpSubsonicClient client() =>
      HttpSubsonicClient(httpClient: MockClient(handle));

  /// The catalog uri of song [song] of album [album] for [user].
  static String songUri(String user, int album, int song) =>
      '${SubsonicTrackMapper.uriScheme}mf-$user-$album-$song';

  /// Every catalog uri of the library as [user] sees it, minus [exceptAlbums].
  Set<String> urisFor(String user, {Set<int> exceptAlbums = const <int>{}}) =>
      <String>{
        for (int a = 0; a < albums; a++)
          if (!exceptAlbums.contains(a))
            for (int s = 0; s < songsPerAlbum; s++) songUri(user, a, s),
      };

  Future<http.Response> handle(http.Request request) async {
    final String method = request.url.pathSegments.last.replaceAll('.view', '');
    calls[method] = (calls[method] ?? 0) + 1;
    final Map<String, String> query = request.url.queryParameters;
    final String user = query['u'] ?? 'nobody';
    switch (method) {
      case 'getAlbumList2':
        final int size = int.parse(query['size']!);
        final int offset = ignoreOffset ? 0 : int.parse(query['offset']!);
        final int end = (offset + size).clamp(0, albums);
        return _ok(<String, Object?>{
          'albumList2': <String, Object?>{
            'album': <Object?>[
              for (int a = offset; a < end; a++)
                <String, Object?>{
                  'id': 'al-$a',
                  'name': 'Album ${a.toString().padLeft(6, '0')}',
                  'songCount': songsPerAlbum,
                },
            ],
          },
        });
      case 'getAlbum':
        final int call = albumCalls;
        if (call == stallAtAlbumCall) {
          if (!_stalled.isCompleted) _stalled.complete();
          await _stall.future;
        }
        if (failingAlbumCalls.remove(call) ||
            (failAlbumCallsFrom != null && call >= failAlbumCallsFrom!)) {
          throw const SocketException('Connection reset by peer');
        }
        if (rejectCredentialsFromAlbumCall != null &&
            call >= rejectCredentialsFromAlbumCall!) {
          return _failed(40, 'Wrong username or password');
        }
        if (serverErrorAlbumCalls.contains(call)) {
          return http.Response('Service Unavailable', 503);
        }
        final int a = int.parse(query['id']!.substring('al-'.length));
        if (missingAlbums.contains(a)) {
          return _failed(70, 'Album not found');
        }
        return _ok(<String, Object?>{
          'album': <String, Object?>{
            'id': 'al-$a',
            'song': <Object?>[
              for (int s = 0; s < songsPerAlbum; s++)
                <String, Object?>{
                  'id': 'mf-$user-$a-$s',
                  'title': 'Song $a/$s',
                  'album': 'Album $a',
                  'albumId': 'al-$a',
                  'artist': 'Artist ${a ~/ 5}',
                  'track': s + 1,
                  'duration': 180 + s,
                  'coverArt': 'al-$a',
                },
            ],
          },
        });
      case 'getPlaylists':
        return _ok(<String, Object?>{
          'playlists': <String, Object?>{'playlist': <Object?>[]},
        });
      case 'getStarred2':
        return _ok(<String, Object?>{
          'starred2': <String, Object?>{'song': <Object?>[]},
        });
      default:
        // ping and anything else: a plain ok envelope.
        return _ok(<String, Object?>{});
    }
  }

  static http.Response _ok(Map<String, Object?> body) => http.Response.bytes(
        utf8.encode(jsonEncode(<String, Object?>{
          'subsonic-response': <String, Object?>{
            'status': 'ok',
            'version': '1.16.1',
            'type': 'navidrome',
            'serverVersion': '0.53.0',
            ...body,
          },
        })),
        200,
        headers: const <String, String>{'content-type': 'application/json'},
      );

  static http.Response _failed(int code, String message) => http.Response(
        jsonEncode(<String, Object?>{
          'subsonic-response': <String, Object?>{
            'status': 'failed',
            'version': '1.16.1',
            'error': <String, Object?>{'code': code, 'message': message},
          },
        }),
        200,
        headers: const <String, String>{'content-type': 'application/json'},
      );
}
