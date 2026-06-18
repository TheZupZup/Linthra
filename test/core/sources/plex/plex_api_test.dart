import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';

void main() {
  group('PlexMetadataType', () {
    test('maps the three music kinds to PMS numeric types', () {
      expect(PlexMetadataType.artist.value, 8);
      expect(PlexMetadataType.album.value, 9);
      expect(PlexMetadataType.track.value, 10);
    });

    test('resolves a type from its string name', () {
      expect(PlexMetadataType.fromTypeName('artist'), PlexMetadataType.artist);
      expect(PlexMetadataType.fromTypeName('album'), PlexMetadataType.album);
      expect(PlexMetadataType.fromTypeName('track'), PlexMetadataType.track);
    });

    test('returns null for a non-music or missing type', () {
      expect(PlexMetadataType.fromTypeName('movie'), isNull);
      expect(PlexMetadataType.fromTypeName(null), isNull);
    });
  });

  group('PlexServerIdentity.fromJson', () {
    test('parses machineIdentifier and version from /identity', () {
      final PlexServerIdentity? identity =
          PlexServerIdentity.fromJson(<String, dynamic>{
        'MediaContainer': <String, dynamic>{
          'machineIdentifier': 'abc123def',
          'version': '1.40.2.8395',
        },
      });

      expect(identity, isNotNull);
      expect(identity!.machineIdentifier, 'abc123def');
      expect(identity.version, '1.40.2.8395');
    });

    test('tolerates a missing version', () {
      final PlexServerIdentity? identity =
          PlexServerIdentity.fromJson(<String, dynamic>{
        'MediaContainer': <String, dynamic>{'machineIdentifier': 'abc123def'},
      });
      expect(identity, isNotNull);
      expect(identity!.version, isNull);
    });

    test('returns null when the body is not a Plex MediaContainer', () {
      expect(PlexServerIdentity.fromJson(<String, dynamic>{}), isNull);
      expect(
        PlexServerIdentity.fromJson(<String, dynamic>{
          'MediaContainer': <String, dynamic>{'version': '1.40'},
        }),
        isNull,
        reason: 'no machineIdentifier means this is not a recognisable PMS',
      );
    });
  });

  group('PlexMediaContainer.fromJson — library sections (Directory)', () {
    test('parses sections and flags music libraries', () {
      final PlexMediaContainer? container =
          PlexMediaContainer.fromJson(<String, dynamic>{
        'MediaContainer': <String, dynamic>{
          'size': 2,
          'Directory': <dynamic>[
            <String, dynamic>{
              'key': '3',
              'title': 'Music',
              'type': 'artist',
              'uuid': 'uuid-music',
            },
            <String, dynamic>{
              'key': '1',
              'title': 'Movies',
              'type': 'movie',
            },
          ],
        },
      });

      expect(container, isNotNull);
      expect(container!.directories, hasLength(2));

      final PlexDirectory music = container.directories.first;
      expect(music.key, '3');
      expect(music.title, 'Music');
      expect(music.type, 'artist');
      expect(music.uuid, 'uuid-music');
      expect(music.isMusic, isTrue);

      expect(container.directories[1].isMusic, isFalse);
    });

    test('skips a section missing its key or title', () {
      final PlexMediaContainer? container =
          PlexMediaContainer.fromJson(<String, dynamic>{
        'MediaContainer': <String, dynamic>{
          'Directory': <dynamic>[
            <String, dynamic>{'title': 'No key'},
            <String, dynamic>{'key': '5'},
            <String, dynamic>{'key': '3', 'title': 'Music', 'type': 'artist'},
          ],
        },
      });
      expect(container!.directories, hasLength(1));
      expect(container.directories.single.key, '3');
    });
  });

  group('PlexMediaContainer.fromJson — metadata items', () {
    test('parses an artist (type 8)', () {
      final PlexMetadata artist = _single(<String, dynamic>{
        'ratingKey': '50',
        'type': 'artist',
        'title': 'Boards of Canada',
        'thumb': '/library/metadata/50/thumb/1',
      });
      expect(artist.ratingKey, '50');
      expect(artist.metadataType, PlexMetadataType.artist);
      expect(artist.title, 'Boards of Canada');
      expect(artist.thumb, '/library/metadata/50/thumb/1');
      // An artist has no parent links.
      expect(artist.parentRatingKey, isNull);
      expect(artist.grandparentRatingKey, isNull);
    });

    test('parses an album (type 9) with its parent link, year, and track count',
        () {
      final PlexMetadata album = _single(<String, dynamic>{
        'ratingKey': '100',
        'type': 'album',
        'title': 'Music Has the Right to Children',
        'parentRatingKey': '50',
        'parentTitle': 'Boards of Canada',
        'year': 1998,
        'leafCount': 12,
      });
      expect(album.metadataType, PlexMetadataType.album);
      expect(album.parentRatingKey, '50');
      expect(album.parentTitle, 'Boards of Canada');
      expect(album.grandparentRatingKey, isNull);
      expect(album.year, 1998);
      expect(album.leafCount, 12);
    });

    test('parses a track (type 10) with parent + grandparent links and Part',
        () {
      final PlexMetadata track = _single(<String, dynamic>{
        'ratingKey': '123',
        'type': 'track',
        'title': 'Roygbiv',
        'parentRatingKey': '100',
        'grandparentRatingKey': '50',
        'parentTitle': 'Music Has the Right to Children',
        'grandparentTitle': 'Boards of Canada',
        'thumb': '/library/metadata/123/thumb/9',
        'duration': 215000,
        'index': 4,
        'Media': <dynamic>[
          <String, dynamic>{
            'container': 'flac',
            'Part': <dynamic>[
              <String, dynamic>{
                'key': '/library/parts/12345/167/file.flac',
                'container': 'flac',
                'duration': 215000,
              },
            ],
          },
        ],
      });

      expect(track.metadataType, PlexMetadataType.track);
      expect(track.parentRatingKey, '100');
      expect(track.grandparentRatingKey, '50');
      expect(track.parentTitle, 'Music Has the Right to Children');
      expect(track.grandparentTitle, 'Boards of Canada');
      expect(track.duration, 215000);
      // The track number (PMS `index`) is parsed for in-order album playback.
      expect(track.index, 4);

      expect(track.media, hasLength(1));
      expect(track.media.single.container, 'flac');
      expect(track.media.single.parts, hasLength(1));

      final PlexPart part = track.media.single.parts.single;
      expect(part.key, '/library/parts/12345/167/file.flac');
      expect(part.container, 'flac');

      // The two-step play resolution reads Media[0].Part[0].key.
      expect(track.firstPartKey, '/library/parts/12345/167/file.flac');
    });

    test('parses a track\'s originalTitle and parentThumb fallback fields', () {
      final PlexMetadata track = _single(<String, dynamic>{
        'ratingKey': '321',
        'type': 'track',
        'title': 'Avril 14th',
        // A compilation entry: the album artist (grandparentTitle) is the
        // various-artists umbrella, while originalTitle credits the performer.
        'grandparentTitle': 'Various Artists',
        'originalTitle': 'Aphex Twin',
        // No own thumb, only the album's (parentThumb).
        'parentThumb': '/library/metadata/200/thumb/55',
      });
      expect(track.originalTitle, 'Aphex Twin');
      expect(track.parentThumb, '/library/metadata/200/thumb/55');
      expect(track.thumb, isNull);
    });

    test('leaves originalTitle / parentThumb null when PMS omits them', () {
      final PlexMetadata track = _single(<String, dynamic>{
        'ratingKey': '322',
        'type': 'track',
        'title': 'Plain track',
      });
      expect(track.originalTitle, isNull);
      expect(track.parentThumb, isNull);
    });

    test('tolerates a track without duration or media', () {
      final PlexMetadata track = _single(<String, dynamic>{
        'ratingKey': '124',
        'type': 'track',
        'title': 'No media here',
      });
      expect(track.duration, isNull);
      expect(track.media, isEmpty);
      expect(track.firstPartKey, isNull);
    });

    test('leaves index / year / leafCount null when PMS omits them', () {
      final PlexMetadata item = _single(<String, dynamic>{
        'ratingKey': '125',
        'type': 'track',
        'title': 'Unnumbered',
      });
      expect(item.index, isNull);
      expect(item.year, isNull);
      expect(item.leafCount, isNull);
    });

    test('skips an item missing its ratingKey, keeps the valid ones', () {
      final PlexMediaContainer? container =
          PlexMediaContainer.fromJson(<String, dynamic>{
        'MediaContainer': <String, dynamic>{
          'Metadata': <dynamic>[
            <String, dynamic>{'type': 'track', 'title': 'Orphan'},
            <String, dynamic>{'ratingKey': '7', 'type': 'track', 'title': 'OK'},
          ],
        },
      });
      expect(container!.metadata, hasLength(1));
      expect(container.metadata.single.ratingKey, '7');
    });

    test('tolerates a missing title (mapper supplies the fallback)', () {
      final PlexMetadata item = _single(<String, dynamic>{
        'ratingKey': '9',
        'type': 'track',
      });
      expect(item.ratingKey, '9');
      expect(item.title, isNull);
    });

    test('accepts ratingKey reported as a bare number', () {
      // Some PMS fields/servers emit numeric ids rather than strings.
      final PlexMetadata item = _single(<String, dynamic>{
        'ratingKey': 42,
        'type': 'album',
        'title': 'Numbered',
      });
      expect(item.ratingKey, '42');
    });
  });

  group('PlexMediaContainer.fromJson — pagination', () {
    test('reads totalSize / size / offset for the paged walk', () {
      final PlexMediaContainer container = _container(<String, dynamic>{
        'size': 50,
        'totalSize': 1234,
        'offset': 500,
        'Metadata': <dynamic>[],
      });
      expect(container.size, 50);
      expect(container.totalSize, 1234);
      expect(container.offset, 500);
      expect(container.total, 1234);
    });

    test('total falls back to size when totalSize is absent (single page)', () {
      final PlexMediaContainer container = _container(<String, dynamic>{
        'size': 12,
        'Metadata': <dynamic>[],
      });
      expect(container.totalSize, isNull);
      expect(container.total, 12);
    });

    test('returns null when the body is not a MediaContainer', () {
      expect(PlexMediaContainer.fromJson(<String, dynamic>{}), isNull);
    });
  });

  group('no token leakage', () {
    test('DTOs carry only credential-free paths/ids, never a token', () {
      // ratingKey is identity; the Part key is a server path. Neither is the
      // X-Plex-Token, which only the URL builders weave in at play/render time.
      final PlexMetadata track = _single(<String, dynamic>{
        'ratingKey': '123',
        'type': 'track',
        'title': 'Roygbiv',
        'thumb': '/library/metadata/123/thumb/9',
        'Media': <dynamic>[
          <String, dynamic>{
            'Part': <dynamic>[
              <String, dynamic>{'key': '/library/parts/12345/167/file.flac'},
            ],
          },
        ],
      });

      final String dump = <Object?>[
        track.ratingKey,
        track.thumb,
        track.firstPartKey,
      ].join(' ');
      expect(dump.toLowerCase(), isNot(contains('x-plex-token')));
      expect(dump.toLowerCase(), isNot(contains('token')));
    });
  });
}

/// Parses [meta] as the sole item of a one-element `Metadata` array.
PlexMetadata _single(Map<String, dynamic> meta) {
  final PlexMediaContainer container = _container(<String, dynamic>{
    'Metadata': <dynamic>[meta],
  });
  return container.metadata.single;
}

/// Wraps [body] in the `MediaContainer` envelope and parses it.
PlexMediaContainer _container(Map<String, dynamic> body) {
  final PlexMediaContainer? container =
      PlexMediaContainer.fromJson(<String, dynamic>{'MediaContainer': body});
  expect(container, isNotNull);
  return container!;
}
