import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/subsonic/subsonic_api.dart';
import 'package:linthra/core/sources/subsonic/subsonic_reply.dart';

/// What the Rust core reads of the values a server actually sends (through
/// `subsonic_reply.dart`). A value of an unexpected type costs that field, or
/// the entry when it is the id or the title, and never fails the answer: a
/// failure here fails the whole sync, and the next launch would walk the
/// library into it again.
void main() {
  /// Every JSON type a field can arrive as. `double.infinity` is written as
  /// `1e400`, a number too large for a double.
  const List<Object?> anyType = <Object?>[
    null,
    true,
    7,
    7.5,
    double.infinity,
    '',
    'text',
    '12',
    <Object?>[],
    <String, Object?>{},
  ];

  final Map<String, Future<Object?> Function(Map<String, dynamic>)> parsers =
      <String, Future<Object?> Function(Map<String, dynamic>)>{
    'song': _song,
    'album': _album,
    'artist': _artist,
    'playlist': _playlist,
  };
  final Map<String, Map<String, dynamic>> samples =
      <String, Map<String, dynamic>>{
    'song': <String, dynamic>{
      'id': 'mf-1',
      'title': 'Nightcall',
      'album': 'OutRun',
      'albumId': 'al-1',
      'artist': 'Kavinsky',
      'track': 1,
      'duration': 256,
      'coverArt': 'al-1',
    },
    'album': <String, dynamic>{
      'id': 'al-1',
      'name': 'OutRun',
      'artist': 'Kavinsky',
      'songCount': 13,
      'year': 2013,
      'coverArt': 'al-1',
    },
    'artist': <String, dynamic>{
      'id': 'ar-1',
      'name': 'Kavinsky',
      'albumCount': 2,
      'coverArt': 'ar-1',
    },
    'playlist': <String, dynamic>{'id': 'pl-1', 'name': 'Drive'},
  };

  test('no field of any type makes an entry fail the answer', () async {
    for (final String kind in parsers.keys) {
      final Map<String, dynamic> sample = samples[kind]!;
      for (final String field in sample.keys) {
        for (final Object? value in anyType) {
          await expectLater(
            parsers[kind]!(<String, dynamic>{...sample, field: value}),
            completes,
            reason: '$kind with $field: $value',
          );
        }
      }
    }
  });

  test('a number sent as a numeric string is read as that number', () async {
    final SubsonicSongDto song = (await _song(<String, dynamic>{
      ...samples['song']!,
      'track': '3',
      'duration': ' 256 ',
    }))!;
    expect(song.track, 3);
    expect(song.durationSeconds, 256);

    final SubsonicAlbumDto album = (await _album(<String, dynamic>{
      ...samples['album']!,
      'songCount': '13',
      'year': '2013',
    }))!;
    expect(album.songCount, 13);
    expect(album.year, 2013);

    final SubsonicArtistDto artist = (await _artist(<String, dynamic>{
      ...samples['artist']!,
      'albumCount': '2',
    }))!;
    expect(artist.albumCount, 2);
  });

  test('a fractional number or numeric string is truncated', () async {
    final SubsonicSongDto song = (await _song(<String, dynamic>{
      ...samples['song']!,
      'duration': 256.7,
      'track': '3.0',
    }))!;
    expect(song.durationSeconds, 256);
    expect(song.track, 3);
  });

  test('a number that is not finite, or not a number, is left out', () async {
    final SubsonicSongDto song = (await _song(<String, dynamic>{
      ...samples['song']!,
      'duration': double.infinity,
      'track': 'B-side',
    }))!;
    expect(song.durationSeconds, isNull);
    expect(song.track, isNull);
  });

  test('a text field of another type is left out, and the entry kept',
      () async {
    final SubsonicSongDto song = (await _song(<String, dynamic>{
      ...samples['song']!,
      'artist': 42,
      'album': <Object?>[],
      'coverArt': true,
    }))!;
    expect(song.title, 'Nightcall');
    expect(song.artist, isNull);
    expect(song.album, isNull);
    expect(song.coverArt, isNull);
  });

  test('an entry whose id or title is not text is skipped', () async {
    expect(
      await _song(<String, dynamic>{...samples['song']!, 'title': 1999}),
      isNull,
    );
    expect(
        await _song(<String, dynamic>{...samples['song']!, 'id': 7}), isNull);
    expect(
      await _album(<String, dynamic>{...samples['album']!, 'name': 1989}),
      isNull,
    );
    expect(
      await _playlist(<String, dynamic>{...samples['playlist']!, 'id': 7}),
      isNull,
    );
  });

  test('reads the date added from Navidrome', () async {
    final SubsonicSongDto? song = await _song(<String, dynamic>{
      'id': 'song1',
      'title': 'My Song',
      'created': '2026-10-27T14:00:00Z',
    });

    expect(song?.dateCreated, DateTime.utc(2026, 10, 27, 14));
  });

  test('reads the date added for a Navidrome album', () async {
    final SubsonicAlbumDto? album = await _album(<String, dynamic>{
      'id': 'album1',
      'name': 'My Album',
      'created': '2026-10-27T14:00:00Z',
    });

    expect(album?.dateCreated, DateTime.utc(2026, 10, 27, 14));
  });

  test('reads the albumId the server reports, or none', () async {
    final SubsonicSongDto? song = await _song(<String, dynamic>{
      'id': 'tr-397',
      'title': 'As I Please',
      'album': '.limbo messiah',
      'albumId': 'al-27',
      'artist': 'Beatsteaks',
    });
    expect(song?.albumId, 'al-27');
    final SubsonicSongDto? bare =
        await _song(<String, dynamic>{'id': 'tr-397', 'title': 'As I Please'});
    expect(bare?.albumId, isNull);
  });

  group('the envelope', () {
    Map<String, dynamic> failed(Map<String, dynamic> error) =>
        <String, dynamic>{
          'subsonic-response': <String, dynamic>{
            'status': 'failed',
            'version': '1.16.1',
            'error': error,
          },
        };

    test('an error code sent as a string is still read', () async {
      final SubsonicReply reply = await _read(
        failed(<String, dynamic>{'code': '40', 'message': 'Wrong password'}),
        SubsonicRead.envelope,
      );
      expect(reply.outcome, SubsonicOutcome.failed);
      expect(reply.errorCode, 40);
    });

    test('no field of any type makes it fail to read', () async {
      for (final String field in <String>['code', 'message']) {
        for (final Object? value in anyType) {
          final SubsonicReply reply = await _read(
            failed(<String, dynamic>{'code': 40, 'message': 'x', field: value}),
            SubsonicRead.envelope,
          );
          expect(reply.outcome, SubsonicOutcome.failed,
              reason: 'error $field: $value');
        }
      }
      for (final String field in <String>['version', 'type', 'serverVersion']) {
        for (final Object? value in anyType) {
          final SubsonicReply reply = await _read(<String, dynamic>{
            'subsonic-response': <String, dynamic>{
              'status': 'ok',
              field: value
            },
          }, SubsonicRead.envelope);
          expect(reply.outcome, SubsonicOutcome.ok, reason: '$field: $value');
        }
      }
    });
  });
}

/// [value] as JSON, with infinity written as `1e400`.
String _encode(Object? value) => switch (value) {
      final double d when d.isInfinite => d.isNegative ? '-1e400' : '1e400',
      final Map<String, dynamic> map =>
        '{${map.entries.map((e) => '${jsonEncode(e.key)}:${_encode(e.value)}').join(',')}}',
      final List<Object?> list => '[${list.map(_encode).join(',')}]',
      _ => jsonEncode(value),
    };

Future<SubsonicReply> _read(Map<String, dynamic> body, SubsonicRead what) =>
    readSubsonicAnswer(utf8.encode(_encode(body)), what);

Map<String, dynamic> _ok(Map<String, dynamic> data) => <String, dynamic>{
      'subsonic-response': <String, dynamic>{'status': 'ok', ...data},
    };

Future<SubsonicSongDto?> _song(Map<String, dynamic> json) async {
  final SubsonicReply reply = await _read(
    _ok(<String, dynamic>{
      'album': <String, dynamic>{
        'song': <Object?>[json],
      },
    }),
    SubsonicRead.albumSongs,
  );
  return reply.songs.isEmpty ? null : songDto(reply.songs.single);
}

Future<SubsonicAlbumDto?> _album(Map<String, dynamic> json) async {
  final SubsonicReply reply = await _read(
    _ok(<String, dynamic>{
      'albumList2': <String, dynamic>{
        'album': <Object?>[json],
      },
    }),
    SubsonicRead.albumPage,
  );
  return reply.albums.isEmpty ? null : albumDto(reply.albums.single);
}

Future<SubsonicArtistDto?> _artist(Map<String, dynamic> json) async {
  final SubsonicReply reply = await _read(
    _ok(<String, dynamic>{
      'artists': <String, dynamic>{
        'index': <Object?>[
          <String, dynamic>{
            'artist': <Object?>[json],
          },
        ],
      },
    }),
    SubsonicRead.artists,
  );
  return reply.artists.isEmpty ? null : artistDto(reply.artists.single);
}

Future<SubsonicPlaylistDto?> _playlist(Map<String, dynamic> json) async {
  final SubsonicReply reply = await _read(
    _ok(<String, dynamic>{
      'playlists': <String, dynamic>{
        'playlist': <Object?>[json],
      },
    }),
    SubsonicRead.playlists,
  );
  return reply.named.isEmpty ? null : playlistDto(reply.named.single);
}
