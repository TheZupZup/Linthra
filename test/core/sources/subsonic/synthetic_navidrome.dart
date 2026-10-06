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
///
/// The album list is served in list order from [listing], which a test can
/// change between pages ([afterAlbumListCall], [removeFromListing],
/// [moveToFrontOfListing]) to model a server whose library changes while a
/// walk reads it (#752).
class SyntheticNavidrome {
  SyntheticNavidrome({
    required this.albums,
    this.songsPerAlbum = 10,
    this.ignoreOffset = false,
    Set<int>? missingAlbums,
    Set<int>? failingAlbumCalls,
    this.failAlbumCallsFrom,
    this.serverErrorAlbumCalls = const <int>{},
    this.rateLimitedAlbumCalls = const <int>{},
    this.rateLimitAlbumCallsFrom,
    this.rejectCredentialsFromAlbumCall,
    this.stallAtAlbumCall,
    this.brokenAlbums = const <int>{},
    this.retypedAlbums = const <int>{},
    this.rejectCredentialsOnPing = false,
    this.failAlbumListCallsFrom,
    this.rejectCredentialsFromAlbumListCall,
    this.afterAlbumListCall,
  })  : missingAlbums = missingAlbums ?? <int>{},
        failingAlbumCalls = failingAlbumCalls ?? <int>{},
        listing = List<int>.generate(albums, (int a) => a);

  final int albums;
  final int songsPerAlbum;

  /// Serve the first page for every `offset`: the runaway-pagination case the
  /// album page cap exists for.
  final bool ignoreOffset;

  /// Album indexes whose `getAlbum` answers Subsonic error 70 (not found), as
  /// if removed on the server after the album list was read.
  final Set<int> missingAlbums;

  /// 1-based `getAlbum` call numbers that fail at the transport level (a reset
  /// socket), once each. The network is down for that moment, so a `ping`
  /// sent before the next `getAlbum` call (the walk asking whether the server
  /// still answers) fails the same way.
  final Set<int> failingAlbumCalls;

  /// From this 1-based `getAlbum` call on, every request fails at the
  /// transport level: the network went away (or Android froze the app)
  /// mid-walk.
  final int? failAlbumCallsFrom;

  /// 1-based `getAlbum` call numbers that answer HTTP 503, once each.
  final Set<int> serverErrorAlbumCalls;

  /// 1-based `getAlbum` call numbers a rate-limiting proxy answers with HTTP
  /// 429, once each.
  final Set<int> rateLimitedAlbumCalls;

  /// From this 1-based `getAlbum` call on, every request answers HTTP 429.
  final int? rateLimitAlbumCallsFrom;

  /// From this 1-based `getAlbum` call on, the server rejects the credential
  /// (Subsonic error 40): a failure no retry can fix.
  final int? rejectCredentialsFromAlbumCall;

  /// The 1-based `getAlbum` call that blocks until [releaseStall] (or forever,
  /// standing in for a process that was killed mid-request).
  final int? stallAtAlbumCall;

  /// Album indexes whose `getAlbum` always answers HTTP 500 (a record the
  /// server chokes on), while everything else on the server works (#740).
  final Set<int> brokenAlbums;

  /// Album indexes served with values of an unexpected JSON type: the list
  /// entry's `songCount` and `year`, and every song's `track` and `duration`,
  /// are numeric strings; song 0's `artist` and song 1's `title` are numbers,
  /// which leaves song 1 without a usable title.
  final Set<int> retypedAlbums;

  /// The `ping` rejects the credential (Subsonic error 40), as a password
  /// changed while an album was failing would.
  final bool rejectCredentialsOnPing;

  /// From this 1-based `getAlbumList2` call on, the album list answers HTTP
  /// 503 (everything else keeps working).
  final int? failAlbumListCallsFrom;

  /// From this 1-based `getAlbumList2` call on, the album list rejects the
  /// credential (Subsonic error 40), as a password changed mid-sync would.
  final int? rejectCredentialsFromAlbumListCall;

  /// Called after each `getAlbumList2` page is served, with the 1-based call
  /// number, so a test can change the library between pages.
  final void Function(SyntheticNavidrome server, int listCall)?
      afterAlbumListCall;

  /// The album indexes `getAlbumList2` lists, in list (alphabetical) order.
  final List<int> listing;

  /// The album was deleted on the server: it leaves the list, and `getAlbum`
  /// answers "not found" for it.
  void removeFromListing(int album) {
    listing.remove(album);
    missingAlbums.add(album);
  }

  /// The album was renamed so that it now sorts first.
  void moveToFrontOfListing(int album) {
    listing
      ..remove(album)
      ..insert(0, album);
  }

  /// Set by [failAlbumCallsFrom]: everything fails from then on.
  bool _down = false;

  /// Set by a [failingAlbumCalls] call, until the next `getAlbum` call: pings
  /// fail meanwhile.
  bool _blip = false;

  /// Set by [rateLimitAlbumCallsFrom]: everything is rate limited from then on.
  bool _rateLimited = false;

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
    if (method != 'getAlbum') {
      if (_down || (_blip && method == 'ping')) {
        throw const SocketException('Connection reset by peer');
      }
      if (_rateLimited) return http.Response('Too Many Requests', 429);
    }
    switch (method) {
      case 'getAlbumList2':
        if (failAlbumListCallsFrom != null &&
            albumListCalls >= failAlbumListCallsFrom!) {
          return http.Response('Service Unavailable', 503);
        }
        if (rejectCredentialsFromAlbumListCall != null &&
            albumListCalls >= rejectCredentialsFromAlbumListCall!) {
          return _failed(40, 'Wrong username or password');
        }
        final int size = int.parse(query['size']!);
        final int offset = ignoreOffset ? 0 : int.parse(query['offset']!);
        final int start = offset.clamp(0, listing.length);
        final int end = (offset + size).clamp(start, listing.length);
        final http.Response page = _ok(<String, Object?>{
          'albumList2': <String, Object?>{
            'album': <Object?>[
              for (final int a in listing.sublist(start, end))
                <String, Object?>{
                  'id': 'al-$a',
                  'name': 'Album ${a.toString().padLeft(6, '0')}',
                  if (retypedAlbums.contains(a)) ...<String, Object?>{
                    'songCount': '$songsPerAlbum',
                    'year': '2011',
                  } else
                    'songCount': songsPerAlbum,
                },
            ],
          },
        });
        afterAlbumListCall?.call(this, albumListCalls);
        return page;
      case 'getAlbum':
        final int call = albumCalls;
        _blip = false;
        if (call == stallAtAlbumCall) {
          if (!_stalled.isCompleted) _stalled.complete();
          await _stall.future;
        }
        if (failAlbumCallsFrom != null && call >= failAlbumCallsFrom!) {
          _down = true;
          throw const SocketException('Connection reset by peer');
        }
        if (failingAlbumCalls.remove(call)) {
          _blip = true;
          throw const SocketException('Connection reset by peer');
        }
        if (rejectCredentialsFromAlbumCall != null &&
            call >= rejectCredentialsFromAlbumCall!) {
          return _failed(40, 'Wrong username or password');
        }
        if (rateLimitAlbumCallsFrom != null &&
            call >= rateLimitAlbumCallsFrom!) {
          _rateLimited = true;
          return http.Response('Too Many Requests', 429);
        }
        if (rateLimitedAlbumCalls.contains(call)) {
          return http.Response('Too Many Requests', 429);
        }
        if (serverErrorAlbumCalls.contains(call)) {
          return http.Response('Service Unavailable', 503);
        }
        final int a = int.parse(query['id']!.substring('al-'.length));
        if (missingAlbums.contains(a)) {
          return _failed(70, 'Album not found');
        }
        if (brokenAlbums.contains(a)) {
          return http.Response('Internal Server Error', 500);
        }
        final bool retyped = retypedAlbums.contains(a);
        return _ok(<String, Object?>{
          'album': <String, Object?>{
            'id': 'al-$a',
            'song': <Object?>[
              for (int s = 0; s < songsPerAlbum; s++)
                <String, Object?>{
                  'id': 'mf-$user-$a-$s',
                  'title': retyped && s == 1 ? 1999 : 'Song $a/$s',
                  'album': 'Album $a',
                  'albumId': 'al-$a',
                  'artist': retyped && s == 0 ? 42 : 'Artist ${a ~/ 5}',
                  'track': retyped ? '${s + 1}' : s + 1,
                  'duration': retyped ? '${180 + s}' : 180 + s,
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
      case 'ping':
        if (rejectCredentialsOnPing) {
          return _failed(40, 'Wrong username or password');
        }
        return _ok(<String, Object?>{});
      default:
        // Anything else: a plain ok envelope.
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
