import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/library/library_grouping.dart';

/// A track shaped like the Jellyfin mapper's output: an opaque `jellyfin:<id>`
/// uri (never a stream URL) and a token-free primary-image artwork URL.
Track _jelly(
  String id, {
  required String title,
  String? artist,
  String? album,
  int? trackNumber,
}) =>
    Track(
      id: id,
      title: title,
      uri: 'jellyfin:$id',
      artistName: artist,
      albumName: album,
      trackNumber: trackNumber,
      artworkUri: Uri.parse('https://media.example/Items/$id/Images/Primary'),
    );

/// A track shaped like the local scanner's output: a file path for both id and
/// uri, the file name as title, and no album/artist tags.
Track _local(String path) =>
    Track(id: path, title: path.split('/').last, uri: path);

void main() {
  group('album grouping — Jellyfin tracks', () {
    test('groups tracks that share an album + artist into one album', () {
      final List<Album> albums = groupAlbums(<Track>[
        _jelly('1', title: 'One', artist: 'Adele', album: '25', trackNumber: 1),
        _jelly('2', title: 'Two', artist: 'Adele', album: '25', trackNumber: 2),
      ]);

      expect(albums, hasLength(1));
      expect(albums.single.title, '25');
      expect(albums.single.artistName, 'Adele');
      expect(albums.single.trackCount, 2);
      // Artwork comes from a track, which is the token-free primary image URL.
      expect(albums.single.artworkUri, isNotNull);
    });

    test('same album title by different artists stays distinct', () {
      final List<Album> albums = groupAlbums(<Track>[
        _jelly('1', title: 'a', artist: 'Queen', album: 'Greatest Hits'),
        _jelly('2', title: 'b', artist: 'ABBA', album: 'Greatest Hits'),
      ]);

      expect(albums, hasLength(2));
      expect(
        albums.map((Album a) => a.artistName).toSet(),
        <String>{'Queen', 'ABBA'},
      );
    });

    test('case and accents do not split one album', () {
      final List<Album> albums = groupAlbums(<Track>[
        _jelly('1', title: 'a', artist: 'Sigur Rós', album: 'Takk'),
        _jelly('2', title: 'b', artist: 'Sigur Ros', album: 'takk'),
      ]);

      expect(albums, hasLength(1));
      expect(albums.single.trackCount, 2);
    });
  });

  group('album grouping — local tracks', () {
    test('untagged local files fold into a single Unknown Album', () {
      final List<Album> albums = groupAlbums(<Track>[
        _local('/music/a.mp3'),
        _local('/music/b.mp3'),
        _local('/music/c.flac'),
      ]);

      expect(albums, hasLength(1));
      expect(albums.single.title, kUnknownAlbum);
      expect(albums.single.title, 'Unknown Album');
      expect(albums.single.artistName, isNull);
      expect(albums.single.trackCount, 3);
    });
  });

  group('artist grouping — Jellyfin tracks', () {
    test('groups by artist and counts distinct albums and tracks', () {
      final List<Artist> artists = groupArtists(<Track>[
        _jelly('1', title: 'a', artist: 'Radiohead', album: 'OK Computer'),
        _jelly('2', title: 'b', artist: 'Radiohead', album: 'OK Computer'),
        _jelly('3', title: 'c', artist: 'Radiohead', album: 'In Rainbows'),
      ]);

      expect(artists, hasLength(1));
      expect(artists.single.name, 'Radiohead');
      expect(artists.single.albumCount, 2);
      expect(artists.single.trackCount, 3);
    });
  });

  group('artist grouping — local tracks', () {
    test('untagged local files fold into a single Unknown Artist', () {
      final List<Artist> artists = groupArtists(<Track>[
        _local('/music/a.mp3'),
        _local('/music/b.mp3'),
      ]);

      expect(artists, hasLength(1));
      expect(artists.single.name, kUnknownArtist);
      expect(artists.single.name, 'Unknown Artist');
      expect(artists.single.trackCount, 2);
    });
  });

  group('sorting', () {
    test('albums sort by title then artist, and are deterministic', () {
      List<Track> input() => <Track>[
            _jelly('1', title: 'a', artist: 'Z', album: 'Banana'),
            _jelly('2', title: 'b', artist: 'A', album: 'apple'),
            _jelly('3', title: 'c', artist: 'B', album: 'Apple'),
          ];

      final List<String> first =
          groupAlbums(input()).map((Album a) => a.title).toList();
      final List<Album> reordered = groupAlbums(input().reversed.toList());

      // Title ascending, case-insensitive; the two "Apple"s order by artist.
      expect(first, <String>['apple', 'Apple', 'Banana']);
      // Same input (in any order) always produces the same order.
      expect(reordered.map((Album a) => a.title).toList(), first);
    });

    test('artists sort by name ascending and deterministically', () {
      List<Track> input() => <Track>[
            _jelly('1', title: 'a', artist: 'Tame Impala'),
            _jelly('2', title: 'b', artist: 'ABBA'),
            _jelly('3', title: 'c', artist: 'glass animals'),
          ];

      final List<String> names =
          groupArtists(input()).map((Artist a) => a.name).toList();
      expect(names, <String>['ABBA', 'glass animals', 'Tame Impala']);
      expect(
        groupArtists(input().reversed.toList()).map((Artist a) => a.name),
        names,
      );
    });

    test('album tracks order by track number, numbered before unnumbered', () {
      final List<Track> all = <Track>[
        _jelly('x', title: 'No number', artist: 'A', album: 'LP'),
        _jelly('1', title: 'First', artist: 'A', album: 'LP', trackNumber: 1),
        _jelly('2', title: 'Second', artist: 'A', album: 'LP', trackNumber: 2),
      ];
      final String id = albumIdForTrack(all[1]);

      expect(
        tracksForAlbum(all, id).map((Track t) => t.title),
        <String>['First', 'Second', 'No number'],
      );
    });
  });

  group('lookups', () {
    test('albumById / artistById find the derived group, or null', () {
      final List<Track> tracks = <Track>[
        _jelly('1', title: 'a', artist: 'Muse', album: 'Drones'),
      ];
      final String albumId = albumIdForTrack(tracks.first);
      final String artistId = artistIdForTrack(tracks.first);

      expect(albumById(tracks, albumId)?.title, 'Drones');
      expect(artistById(tracks, artistId)?.name, 'Muse');
      expect(albumById(tracks, 'nope'), isNull);
      expect(artistById(tracks, 'nope'), isNull);
    });

    test('albumsForArtist returns only that artist\'s albums', () {
      final List<Track> tracks = <Track>[
        _jelly('1', title: 'a', artist: 'Muse', album: 'Drones'),
        _jelly('2', title: 'b', artist: 'Muse', album: 'Origin'),
        _jelly('3', title: 'c', artist: 'Other', album: 'Misc'),
      ];
      final String artistId = artistIdForTrack(tracks.first);

      expect(
        albumsForArtist(tracks, artistId).map((Album a) => a.title),
        <String>['Drones', 'Origin'],
      );
    });
  });

  group('privacy', () {
    test('derived album/artist metadata carries no token or auth URL', () {
      final List<Track> tracks = <Track>[
        _jelly('1', title: 'a', artist: 'Artist', album: 'Album'),
      ];
      final Album album = groupAlbums(tracks).single;
      final Artist artist = groupArtists(tracks).single;

      final List<String> exposed = <String>[
        album.title,
        album.artistName ?? '',
        album.id,
        album.artworkUri?.toString() ?? '',
        artist.name,
        artist.id,
        artist.artworkUri?.toString() ?? '',
      ];
      for (final String value in exposed) {
        expect(value.toLowerCase(), isNot(contains('api_key')));
        expect(value.toLowerCase(), isNot(contains('token')));
        expect(value, isNot(contains('AccessToken')));
      }
    });
  });
}
