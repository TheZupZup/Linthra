import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/library_grouping.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_track_mapper.dart';

void main() {
  group('PlexTrackMapper.toTrack (Plex type 10)', () {
    test('maps a track to a token-free plex: uri', () {
      const item = PlexMetadata(
        ratingKey: '301',
        type: 'track',
        title: 'Nightcall',
        parentRatingKey: '201',
        grandparentRatingKey: '101',
        parentTitle: 'OutRun',
        grandparentTitle: 'Kavinsky',
        thumb: '/library/metadata/201/thumb/1700000000',
        duration: 258000,
      );

      final track = PlexTrackMapper.toTrack(item);

      expect(track.id, '301');
      expect(track.uri, 'plex:301');
      expect(track.title, 'Nightcall');
      // The parent/grandparent links carry the album/artist relationship.
      expect(track.albumName, 'OutRun');
      expect(track.artistName, 'Kavinsky');
      // Plex reports duration in milliseconds.
      expect(track.duration, const Duration(minutes: 4, seconds: 18));
      expect(
        track.artworkUri.toString(),
        'plex-thumb:/library/metadata/201/thumb/1700000000',
      );
    });

    test('uses the ratingKey, never the Part path, for the uri', () {
      // A realistic track item carries its Media/Part (the playable file
      // path); the mapped uri must stay the opaque ratingKey reference so the
      // catalog never names a server file path.
      final PlexMetadata item = PlexMetadata.fromJson(<String, dynamic>{
        'ratingKey': '301',
        'type': 'track',
        'title': 'Nightcall',
        'Media': <dynamic>[
          <String, dynamic>{
            'Part': <dynamic>[
              <String, dynamic>{
                'key': '/library/parts/9001/1700000000/file.flac',
              },
            ],
          },
        ],
      })!;

      final track = PlexTrackMapper.toTrack(item);

      expect(track.uri, 'plex:301');
      expect(track.uri, isNot(contains('parts')));
      expect(track.uri, isNot(contains('file.flac')));
    });

    test('the uri and artwork reference never embed a credential or server',
        () {
      const item = PlexMetadata(
        ratingKey: '301',
        title: 'x',
        thumb: '/library/metadata/201/thumb/1700000000',
      );

      final track = PlexTrackMapper.toTrack(item);

      // The uri is the opaque ratingKey only — no query, no token.
      expect(track.uri, 'plex:301');
      expect(track.uri, isNot(contains('?')));
      expect(track.uri, isNot(contains('X-Plex-Token')));
      expect(track.uri, isNot(contains('=')));
      // The artwork reference is credential-free and points at no server: the
      // token is woven in only at render time, never persisted here.
      final String artwork = track.artworkUri.toString();
      expect(artwork, 'plex-thumb:/library/metadata/201/thumb/1700000000');
      expect(artwork, isNot(contains('?')));
      expect(artwork, isNot(contains('X-Plex-Token')));
      expect(artwork, isNot(contains('http')));
    });

    test('falls back to a safe title when Plex omits or blanks it', () {
      const missing = PlexMetadata(ratingKey: '1');
      const blank = PlexMetadata(ratingKey: '2', title: '   ');
      expect(PlexTrackMapper.toTrack(missing).title, 'Untitled');
      expect(PlexTrackMapper.toTrack(blank).title, 'Untitled');
    });

    test('leaves artist/album null when the parent titles are missing', () {
      const item = PlexMetadata(ratingKey: '301', title: 'Nightcall');
      final track = PlexTrackMapper.toTrack(item);
      // Null names let the grouping layer fold the track into its Unknown
      // Album/Artist buckets, same as a tagless local file.
      expect(track.artistName, isNull);
      expect(track.albumName, isNull);
    });

    test('maps absent or zero duration to zero', () {
      const absent = PlexMetadata(ratingKey: '1', title: 't');
      const zero = PlexMetadata(ratingKey: '2', title: 't', duration: 0);
      expect(PlexTrackMapper.toTrack(absent).duration, Duration.zero);
      expect(PlexTrackMapper.toTrack(zero).duration, Duration.zero);
    });

    test('leaves artworkUri null when the item reports no thumb', () {
      const item = PlexMetadata(ratingKey: '1', title: 't');
      // No thumb → null → the UI shows its placeholder (not a broken image).
      expect(PlexTrackMapper.toTrack(item).artworkUri, isNull);
    });
  });

  group('PlexTrackMapper.toAlbum (Plex type 9)', () {
    test('maps an album, with its parentTitle as the artist name', () {
      const item = PlexMetadata(
        ratingKey: '201',
        type: 'album',
        title: 'OutRun',
        parentRatingKey: '101',
        parentTitle: 'Kavinsky',
        thumb: '/library/metadata/201/thumb/1700000000',
      );

      final album = PlexTrackMapper.toAlbum(item);

      expect(album.id, '201');
      expect(album.title, 'OutRun');
      expect(album.artistName, 'Kavinsky');
      expect(
        album.artworkUri.toString(),
        'plex-thumb:/library/metadata/201/thumb/1700000000',
      );
    });

    test('falls back to the shared Unknown Album label for a missing title',
        () {
      const item = PlexMetadata(ratingKey: '201', type: 'album');
      expect(PlexTrackMapper.toAlbum(item).title, kUnknownAlbum);
    });

    test('leaves artistName and artwork null when Plex omits them', () {
      const item = PlexMetadata(ratingKey: '201', title: 'OutRun');
      final album = PlexTrackMapper.toAlbum(item);
      expect(album.artistName, isNull);
      expect(album.artworkUri, isNull);
    });
  });

  group('PlexTrackMapper.toArtist (Plex type 8)', () {
    test('maps artist id, name, and artwork reference', () {
      const item = PlexMetadata(
        ratingKey: '101',
        type: 'artist',
        title: 'Kavinsky',
        thumb: '/library/metadata/101/thumb/1700000000',
      );

      final artist = PlexTrackMapper.toArtist(item);

      expect(artist.id, '101');
      expect(artist.name, 'Kavinsky');
      expect(
        artist.artworkUri.toString(),
        'plex-thumb:/library/metadata/101/thumb/1700000000',
      );
    });

    test('falls back to the shared Unknown Artist label for a missing title',
        () {
      const item = PlexMetadata(ratingKey: '101', type: 'artist');
      expect(PlexTrackMapper.toArtist(item).name, kUnknownArtist);
    });
  });

  group('plex-thumb artwork reference', () {
    test('round-trips through the catalog persistence shape', () {
      const item = PlexMetadata(
        ratingKey: '1',
        title: 't',
        thumb: '/library/metadata/201/thumb/1700000000',
      );
      final Uri reference = PlexTrackMapper.toTrack(item).artworkUri!;

      // The catalog persists artworkUri as a string; the reference must come
      // back out of Uri.parse with its thumb path intact.
      final Uri reparsed = Uri.parse(reference.toString());
      expect(
        PlexTrackMapper.thumbPath(reparsed),
        '/library/metadata/201/thumb/1700000000',
      );
    });

    test('thumbPath leaves other providers\' artwork untouched', () {
      expect(
        PlexTrackMapper.thumbPath(Uri.parse('https://x.example/cover.jpg')),
        isNull,
      );
      expect(
        PlexTrackMapper.thumbPath(Uri.parse('subsonic-cover:al-7')),
        isNull,
      );
      expect(
        PlexTrackMapper.thumbPath(Uri.parse('file:///covers/a.jpg')),
        isNull,
      );
    });
  });
}
