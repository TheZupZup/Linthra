import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/library_grouping.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/track.dart';

/// A track shaped like the Jellyfin mapper's output: an opaque `jellyfin:<id>`
/// uri (never a stream URL) and a token-free primary-image artwork URL.
Track _jelly(
  String id, {
  required String title,
  String? artist,
  String? album,
  String? albumId,
  String? albumArtist,
  int? trackNumber,
  int? discNumber,
}) =>
    Track(
      id: id,
      title: title,
      uri: 'jellyfin:$id',
      artistName: artist,
      albumName: album,
      albumId: albumId,
      albumArtistName: albumArtist,
      trackNumber: trackNumber,
      discNumber: discNumber,
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

  // Issue #281: an album whose tracks credit different collaborating artists
  // used to split into one album entry per distinct artist string.
  group('album grouping — collaborations (albumId tier)', () {
    test('tracks sharing an albumId group despite differing artists', () {
      final List<Album> albums = groupAlbums(<Track>[
        _jelly('1',
            title: 'Solo',
            artist: 'Main Artist',
            album: 'The Album',
            albumId: 'jellyfin:al-1',
            albumArtist: 'Main Artist'),
        _jelly('2',
            title: 'Feature',
            artist: 'Main Artist feat. Guest One',
            album: 'The Album',
            albumId: 'jellyfin:al-1',
            albumArtist: 'Main Artist'),
        _jelly('3',
            title: 'Another',
            artist: 'Main Artist feat. Guest Two',
            album: 'The Album',
            albumId: 'jellyfin:al-1',
            albumArtist: 'Main Artist'),
      ]);

      expect(albums, hasLength(1));
      expect(albums.single.trackCount, 3);
      // The album artist labels the group, not a per-track "feat." credit.
      expect(albums.single.artistName, 'Main Artist');
    });

    test('the album artist labels the group whatever the track order', () {
      // Regression: the first track carries only a per-track credit. If the
      // aggregate collapsed artist choice as tracks arrived, that credit would
      // stick and block the real album artist the second track supplies.
      List<Track> input() => <Track>[
            _jelly('1',
                title: 'Feature',
                artist: 'Main Artist feat. Guest',
                album: 'The Album',
                albumId: 'jellyfin:al-1'),
            _jelly('2',
                title: 'Solo',
                artist: 'Main Artist',
                album: 'The Album',
                albumId: 'jellyfin:al-1',
                albumArtist: 'Main Artist'),
          ];

      expect(groupAlbums(input()).single.artistName, 'Main Artist');
      // ...and the same in the other order.
      expect(
        groupAlbums(input().reversed.toList()).single.artistName,
        'Main Artist',
      );
    });

    test('falls back to the track artist when no track has an album artist',
        () {
      final List<Album> albums = groupAlbums(<Track>[
        _jelly('1',
            title: 'a',
            artist: 'Only Artist',
            album: 'LP',
            albumId: 'jellyfin:al-1'),
        _jelly('2',
            title: 'b',
            artist: 'Other Credit',
            album: 'LP',
            albumId: 'jellyfin:al-1'),
      ]);

      expect(albums.single.artistName, 'Only Artist');
    });

    test('the same album title under different albumIds stays distinct', () {
      final List<Album> albums = groupAlbums(<Track>[
        _jelly('1',
            title: 'a',
            artist: 'Queen',
            album: 'Greatest Hits',
            albumId: 'jellyfin:al-1'),
        _jelly('2',
            title: 'b',
            artist: 'ABBA',
            album: 'Greatest Hits',
            albumId: 'jellyfin:al-2'),
      ]);

      expect(albums, hasLength(2));
    });

    test('album ids from different providers never collide', () {
      // Both servers call their album "al-1"; the provider namespace keeps
      // them apart.
      final List<Album> albums = groupAlbums(<Track>[
        _jelly('1',
            title: 'a', artist: 'A', album: 'Shared', albumId: 'jellyfin:al-1'),
        _jelly('2',
            title: 'b', artist: 'A', album: 'Shared', albumId: 'subsonic:al-1'),
      ]);

      expect(albums, hasLength(2));
    });

    test('a blank albumId falls through to the name-based tiers', () {
      final List<Album> albums = groupAlbums(<Track>[
        _jelly('1', title: 'a', artist: 'A', album: 'LP', albumId: '   '),
        _jelly('2', title: 'b', artist: 'A', album: 'LP'),
      ]);

      expect(albums, hasLength(1));
      expect(albums.single.trackCount, 2);
    });

    test('all tracks of a collaboration album appear in the album detail', () {
      final List<Track> tracks = <Track>[
        _jelly('1',
            title: 'One',
            artist: 'Main Artist',
            album: 'The Album',
            albumId: 'jellyfin:al-1',
            trackNumber: 1),
        _jelly('2',
            title: 'Two',
            artist: 'Main Artist feat. Guest',
            album: 'The Album',
            albumId: 'jellyfin:al-1',
            trackNumber: 2),
        _jelly('3',
            title: 'Three',
            artist: 'Guest feat. Main Artist',
            album: 'The Album',
            albumId: 'jellyfin:al-1',
            trackNumber: 3),
      ];
      final String id = albumIdForTrack(tracks.first);

      expect(
        tracksForAlbum(tracks, id).map((Track t) => t.title),
        <String>['One', 'Two', 'Three'],
      );
    });
  });

  group('album grouping — albumArtistName tier', () {
    test('collaborations group by album + album artist without an albumId', () {
      final List<Album> albums = groupAlbums(<Track>[
        _jelly('1',
            title: 'Solo',
            artist: 'Main Artist',
            album: 'The Album',
            albumArtist: 'Main Artist'),
        _jelly('2',
            title: 'Feature',
            artist: 'Main Artist feat. Guest',
            album: 'The Album',
            albumArtist: 'Main Artist'),
      ]);

      expect(albums, hasLength(1));
      expect(albums.single.trackCount, 2);
      expect(albums.single.artistName, 'Main Artist');
    });

    test('same title, different album artists stay distinct', () {
      final List<Album> albums = groupAlbums(<Track>[
        _jelly('1',
            title: 'a',
            artist: 'Queen',
            album: 'Greatest Hits',
            albumArtist: 'Queen'),
        _jelly('2',
            title: 'b',
            artist: 'ABBA',
            album: 'Greatest Hits',
            albumArtist: 'ABBA'),
      ]);

      expect(albums, hasLength(2));
      expect(
        albums.map((Album a) => a.artistName).toSet(),
        <String>{'Queen', 'ABBA'},
      );
    });

    test('albumId wins over albumArtistName when both are present', () {
      // Same album artist, different source albums (e.g. an album and its
      // deluxe reissue) — the stable id is the more specific signal.
      final List<Album> albums = groupAlbums(<Track>[
        _jelly('1',
            title: 'a',
            album: 'LP',
            albumId: 'jellyfin:al-1',
            albumArtist: 'Artist'),
        _jelly('2',
            title: 'b',
            album: 'LP',
            albumId: 'jellyfin:al-2',
            albumArtist: 'Artist'),
      ]);

      expect(albums, hasLength(2));
    });

    test('albumArtistName wins over artistName for the grouping key', () {
      // Without the album-artist tier these two would split on artistName.
      final List<Album> albums = groupAlbums(<Track>[
        _jelly('1',
            title: 'a', artist: 'X feat. Y', album: 'LP', albumArtist: 'X'),
        _jelly('2',
            title: 'b', artist: 'X feat. Z', album: 'LP', albumArtist: 'X'),
      ]);

      expect(albums, hasLength(1));
    });

    test('case and accents do not split an album-artist group', () {
      final List<Album> albums = groupAlbums(<Track>[
        _jelly('1',
            title: 'a', artist: 'a', album: 'Takk', albumArtist: 'Sigur Rós'),
        _jelly('2',
            title: 'b', artist: 'b', album: 'takk', albumArtist: 'Sigur Ros'),
      ]);

      expect(albums, hasLength(1));
      expect(albums.single.trackCount, 2);
    });
  });

  group('album grouping — artistName fallback tier', () {
    test('tracks with neither albumId nor albumArtist group by name pair', () {
      final List<Album> albums = groupAlbums(<Track>[
        _jelly('1', title: 'a', artist: 'Adele', album: '25'),
        _jelly('2', title: 'b', artist: 'Adele', album: '25'),
      ]);

      expect(albums, hasLength(1));
      expect(albums.single.trackCount, 2);
      expect(albums.single.artistName, 'Adele');
    });

    test('a track with no album gets its own artist\'s Unknown Album', () {
      final List<Album> albums = groupAlbums(<Track>[
        _jelly('1', title: 'a', artist: 'Adele'),
        _jelly('2', title: 'b', artist: 'Queen'),
      ]);

      expect(albums, hasLength(2));
      expect(albums.every((Album a) => a.title == kUnknownAlbum), isTrue);
      expect(
        albums.map((Album a) => a.artistName).toSet(),
        <String>{'Adele', 'Queen'},
      );
    });

    test('the three tiers never collide on identical raw strings', () {
      // Each track would key on the string "LP"/"X" in a different tier; a
      // tier prefix keeps all three apart.
      final List<Album> albums = groupAlbums(<Track>[
        _jelly('1', title: 'a', album: 'LP', albumId: 'X'),
        _jelly('2', title: 'b', album: 'LP', albumArtist: 'X'),
        _jelly('3', title: 'c', album: 'LP', artist: 'X'),
      ]);

      expect(albums, hasLength(3));
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

  // Issue #682: every track with no album title and no source album id used to
  // share one global "Unknown Album" id, so opening one artist's Unknown Album
  // listed (and queued) every other artist's album-less tracks too.
  group('album grouping: missing album title (#682)', () {
    final List<Track> catalog = <Track>[
      _local('/a/1.mp3').copyWith(artistName: 'Artist A', trackNumber: 2),
      _local('/a/2.mp3').copyWith(artistName: 'Artist A', trackNumber: 1),
      _local('/b/1.mp3').copyWith(artistName: 'Artist B'),
      _local('/b/2.mp3').copyWith(artistName: 'Artist B'),
      _local('/x/1.mp3'),
      _local('/x/2.mp3'),
      _local('/a/lp.mp3')
          .copyWith(artistName: 'Artist A', albumName: 'Real Album'),
    ];
    final String artistA = artistIdForTrack(catalog[0]);
    final String artistB = artistIdForTrack(catalog[2]);

    Album unknownAlbumOf(String artistId) => albumsForArtist(catalog, artistId)
        .singleWhere((Album a) => a.title == kUnknownAlbum);

    test('two artists\' album-less tracks do not share one album', () {
      final List<Album> unknown = groupAlbums(catalog)
          .where((Album a) => a.title == kUnknownAlbum)
          .toList();

      // Artist A, Artist B, and the fully untagged pair.
      expect(unknown, hasLength(3));
      expect(unknown.map((Album a) => a.id).toSet(), hasLength(3));
      expect(
        unknown.map((Album a) => a.artistName).toSet(),
        <String?>{'Artist A', 'Artist B', null},
      );
    });

    test('opening Artist A\'s Unknown Album returns only Artist A\'s tracks',
        () {
      final Album album = unknownAlbumOf(artistA);

      expect(album.artistName, 'Artist A');
      expect(album.trackCount, 2);
      // The album detail page resolves the id against the whole catalog.
      expect(albumById(catalog, album.id)?.trackCount, 2);
      expect(
        tracksForAlbum(catalog, album.id).map((Track t) => t.id),
        <String>['/a/2.mp3', '/a/1.mp3'],
      );
    });

    test('Artist B\'s Unknown Album stays separate', () {
      final Album a = unknownAlbumOf(artistA);
      final Album b = unknownAlbumOf(artistB);

      expect(b.id, isNot(a.id));
      expect(
        tracksForAlbum(catalog, b.id).map((Track t) => t.id).toSet(),
        <String>{'/b/1.mp3', '/b/2.mp3'},
      );
    });

    test('an album-less track never joins a real album by the same artist', () {
      final List<Album> albums = albumsForArtist(catalog, artistA);

      expect(
        albums.map((Album a) => a.title),
        <String>['Real Album', kUnknownAlbum],
      );
      expect(groupArtists(catalog).first.albumCount, 2);
    });

    test('missing artist + missing album groups deterministically', () {
      final List<Track> reversed = catalog.reversed.toList();
      final Album untagged = groupAlbums(catalog).singleWhere(
          (Album a) => a.title == kUnknownAlbum && a.artistName == null);

      expect(untagged.trackCount, 2);
      expect(
        tracksForAlbum(catalog, untagged.id).map((Track t) => t.id),
        <String>['/x/1.mp3', '/x/2.mp3'],
      );
      // Same id and same members whatever order the catalog arrives in.
      expect(albumIdForTrack(catalog[4]), albumIdForTrack(catalog[5]));
      expect(
        groupAlbums(reversed).map((Album a) => a.id),
        groupAlbums(catalog).map((Album a) => a.id),
      );
    });

    test('a literal "Unknown Album" tag is not the missing-album fallback', () {
      final List<Track> tracks = <Track>[
        _local('/a/1.mp3').copyWith(artistName: 'Artist A'),
        _local('/a/2.mp3')
            .copyWith(artistName: 'Artist A', albumName: 'Unknown Album'),
        _local('/b/1.mp3')
            .copyWith(artistName: 'Artist B', albumName: 'Unknown Album'),
        _local('/x/1.mp3'),
        _local('/x/2.mp3').copyWith(albumName: 'Unknown Album'),
      ];

      final List<Album> albums = groupAlbums(tracks);

      // Every track is its own album: tagged and untagged never collide, and
      // the literal tag is still keyed by its artist like any other title.
      expect(albums, hasLength(5));
      expect(albums.every((Album a) => a.title == kUnknownAlbum), isTrue);
      expect(albums.map((Album a) => a.id).toSet(), hasLength(5));
    });

    test('blank and whitespace album titles count as missing', () {
      final List<Track> tracks = <Track>[
        _local('/a/1.mp3').copyWith(artistName: 'Artist A'),
        _local('/a/2.mp3').copyWith(artistName: 'Artist A', albumName: ''),
        _local('/a/3.mp3').copyWith(artistName: 'Artist A', albumName: '  '),
      ];

      expect(groupAlbums(tracks).single.trackCount, 3);
    });

    test('case and accents do not split one artist\'s Unknown Album', () {
      final List<Track> tracks = <Track>[
        _local('/1.mp3').copyWith(artistName: 'Sigur Rós'),
        _local('/2.mp3').copyWith(artistName: 'sigur ros'),
      ];

      // Matches the artist grouping, which also folds these into one artist.
      expect(groupArtists(tracks), hasLength(1));
      expect(groupAlbums(tracks).single.trackCount, 2);
    });

    test('a source album id still wins over a missing album title', () {
      // e.g. Android MediaStore, which reports an ALBUM_ID even for a track
      // whose album tag is unknown.
      final List<Track> tracks = <Track>[
        _local('/1.mp3')
            .copyWith(artistName: 'Artist A', albumId: 'android-mediastore:7'),
        _local('/2.mp3')
            .copyWith(artistName: 'Artist B', albumId: 'android-mediastore:7'),
        _local('/3.mp3').copyWith(artistName: 'Artist A'),
      ];

      final List<Album> albums = groupAlbums(tracks);

      expect(albums, hasLength(2));
      expect(
        albums.map((Album a) => a.trackCount).toList()..sort(),
        <int>[1, 2],
      );
    });

    test('an artist page\'s Unknown Album only holds that artist\'s tracks',
        () {
      // A collaboration credit, an album artist, an untagged track and a
      // same-titled real album across two artists, all mixed together.
      final List<Track> tracks = <Track>[
        ...catalog,
        _jelly('j1', title: 'a', artist: 'X feat. Y', albumArtist: 'X'),
        _jelly('j2', title: 'b', artist: 'X'),
        _jelly('j3', title: 'c', artist: 'X', album: 'Hits'),
        _jelly('j4', title: 'd', artist: 'Artist A', album: 'Hits'),
      ];

      for (final Artist artist in groupArtists(tracks)) {
        final Set<Track> own = tracksForArtist(tracks, artist.id).toSet();
        for (final Album album in albumsForArtist(tracks, artist.id)) {
          if (album.title != kUnknownAlbum) continue;
          expect(
            own.containsAll(tracksForAlbum(tracks, album.id)),
            isTrue,
            reason: '${album.title} on ${artist.name}\'s page leaked tracks',
          );
        }
      }
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

  group('multi-disc album order', () {
    /// A two-disc release as a server reports one: track numbers restart at 1
    /// on the second disc, which is exactly what makes ordering by number alone
    /// interleave the discs.
    List<Track> twoDiscs() => <Track>[
          _jelly('d2t2',
              title: 'D2T2',
              artist: 'A',
              album: 'LP',
              discNumber: 2,
              trackNumber: 2),
          _jelly('d1t1',
              title: 'D1T1',
              artist: 'A',
              album: 'LP',
              discNumber: 1,
              trackNumber: 1),
          _jelly('d2t1',
              title: 'D2T1',
              artist: 'A',
              album: 'LP',
              discNumber: 2,
              trackNumber: 1),
          _jelly('d1t2',
              title: 'D1T2',
              artist: 'A',
              album: 'LP',
              discNumber: 1,
              trackNumber: 2),
        ];

    test('disc 1 plays end to end before disc 2 starts', () {
      final List<Track> all = twoDiscs();
      final String id = albumIdForTrack(all.first);

      expect(
        tracksForAlbum(all, id).map((Track t) => t.title),
        <String>['D1T1', 'D1T2', 'D2T1', 'D2T2'],
      );
    });

    test('the order does not depend on how the catalog happened to arrive', () {
      final String id = albumIdForTrack(twoDiscs().first);
      final List<String> forwards =
          tracksForAlbum(twoDiscs(), id).map((Track t) => t.title).toList();

      expect(
        tracksForAlbum(twoDiscs().reversed.toList(), id)
            .map((Track t) => t.title),
        forwards,
      );
    });

    test('a disc-numbered track comes before one with no disc at all', () {
      final List<Track> all = <Track>[
        _jelly('none', title: 'Bonus', artist: 'A', album: 'LP'),
        _jelly('d1', title: 'Opener', artist: 'A', album: 'LP', discNumber: 1),
      ];
      final String id = albumIdForTrack(all.first);

      expect(
        tracksForAlbum(all, id).map((Track t) => t.title),
        <String>['Opener', 'Bonus'],
      );
    });

    test('an album with no disc numbers orders exactly as it always did', () {
      // Every source leaves discNumber null today, so the disc tier must be a
      // no-op: track number first, numbered before unnumbered, then title.
      final List<Track> all = <Track>[
        _jelly('x', title: 'No number', artist: 'A', album: 'LP'),
        _jelly('2', title: 'Second', artist: 'A', album: 'LP', trackNumber: 2),
        _jelly('1', title: 'First', artist: 'A', album: 'LP', trackNumber: 1),
      ];
      final String id = albumIdForTrack(all.first);

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
