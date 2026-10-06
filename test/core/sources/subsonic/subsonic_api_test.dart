import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/subsonic/subsonic_api.dart';

/// What the Subsonic DTOs make of the values a server actually sends. A value
/// of an unexpected type costs that field, or the entry when it is the id or
/// the title, and never throws: a `TypeError` here fails the whole sync, and
/// the next launch would walk the library into it again.
void main() {
  /// Every JSON type a field can arrive as. `double.infinity` is what
  /// `jsonDecode` makes of a number too large for a double (`1e400`).
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

  final Map<String, Object? Function(Map<String, dynamic>)> parsers =
      <String, Object? Function(Map<String, dynamic>)>{
    'song': SubsonicSongDto.fromJson,
    'album': SubsonicAlbumDto.fromJson,
    'artist': SubsonicArtistDto.fromJson,
    'playlist': SubsonicPlaylistDto.fromJson,
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

  test('no field of any type makes an entry throw', () {
    for (final String kind in parsers.keys) {
      final Map<String, dynamic> sample = samples[kind]!;
      for (final String field in sample.keys) {
        for (final Object? value in anyType) {
          expect(
            () => parsers[kind]!(<String, dynamic>{...sample, field: value}),
            returnsNormally,
            reason: '$kind with $field: $value',
          );
        }
      }
    }
  });

  test('a number sent as a numeric string is read as that number', () {
    final SubsonicSongDto song = SubsonicSongDto.fromJson(<String, dynamic>{
      ...samples['song']!,
      'track': '3',
      'duration': ' 256 ',
    })!;
    expect(song.track, 3);
    expect(song.durationSeconds, 256);

    final SubsonicAlbumDto album = SubsonicAlbumDto.fromJson(<String, dynamic>{
      ...samples['album']!,
      'songCount': '13',
      'year': '2013',
    })!;
    expect(album.songCount, 13);
    expect(album.year, 2013);

    final SubsonicArtistDto artist =
        SubsonicArtistDto.fromJson(<String, dynamic>{
      ...samples['artist']!,
      'albumCount': '2',
    })!;
    expect(artist.albumCount, 2);
  });

  test('a fractional number or numeric string is truncated', () {
    final SubsonicSongDto song = SubsonicSongDto.fromJson(<String, dynamic>{
      ...samples['song']!,
      'duration': 256.7,
      'track': '3.0',
    })!;
    expect(song.durationSeconds, 256);
    expect(song.track, 3);
  });

  test('a number that is not finite, or not a number, is left out', () {
    final SubsonicSongDto song = SubsonicSongDto.fromJson(<String, dynamic>{
      ...samples['song']!,
      'duration': double.infinity,
      'track': 'B-side',
    })!;
    expect(song.durationSeconds, isNull);
    expect(song.track, isNull);
  });

  test('a text field of another type is left out, and the entry kept', () {
    final SubsonicSongDto song = SubsonicSongDto.fromJson(<String, dynamic>{
      ...samples['song']!,
      'artist': 42,
      'album': <Object?>[],
      'coverArt': true,
    })!;
    expect(song.title, 'Nightcall');
    expect(song.artist, isNull);
    expect(song.album, isNull);
    expect(song.coverArt, isNull);
  });

  test('an entry whose id or title is not text is skipped', () {
    expect(
      SubsonicSongDto.fromJson(<String, dynamic>{
        ...samples['song']!,
        'title': 1999,
      }),
      isNull,
    );
    expect(
      SubsonicSongDto.fromJson(<String, dynamic>{...samples['song']!, 'id': 7}),
      isNull,
    );
    expect(
      SubsonicAlbumDto.fromJson(<String, dynamic>{
        ...samples['album']!,
        'name': 1989,
      }),
      isNull,
    );
    expect(
      SubsonicPlaylistDto.fromJson(<String, dynamic>{
        ...samples['playlist']!,
        'id': 7,
      }),
      isNull,
    );
  });

  group('SubsonicEnvelope', () {
    Map<String, dynamic> failed(Map<String, dynamic> error) =>
        <String, dynamic>{
          'subsonic-response': <String, dynamic>{
            'status': 'failed',
            'version': '1.16.1',
            'error': error,
          },
        };

    test('an error code sent as a string is still read', () {
      final SubsonicEnvelope envelope = SubsonicEnvelope.fromJson(
        failed(<String, dynamic>{'code': '40', 'message': 'Wrong password'}),
      )!;
      expect(envelope.errorCode, 40);
      expect(envelope.errorMessage, 'Wrong password');
    });

    test('no field of any type makes it throw', () {
      for (final String field in <String>['code', 'message']) {
        for (final Object? value in anyType) {
          expect(
            () => SubsonicEnvelope.fromJson(
              failed(
                  <String, dynamic>{'code': 40, 'message': 'x', field: value}),
            ),
            returnsNormally,
            reason: 'error $field: $value',
          );
        }
      }
      for (final String field in <String>['version', 'type', 'serverVersion']) {
        for (final Object? value in anyType) {
          expect(
            () => SubsonicEnvelope.fromJson(<String, dynamic>{
              'subsonic-response': <String, dynamic>{
                'status': 'ok',
                field: value,
              },
            }),
            returnsNormally,
            reason: '$field: $value',
          );
        }
      }
    });
  });
}
