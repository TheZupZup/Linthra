import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/library_grouping.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/native/native_library_grouping.dart';

/// The Rust grouping's album and artist ids have to be the ones
/// `albumIdForTrack` and `artistIdForTrack` compute in Dart, one track at a
/// time: album and artist pages look their tracks up with those.
void main() {
  group('native library grouping', () {
    test("gives Dart's ids on names that are easy to get wrong", () {
      _expectSameIds(_tricky());
    });

    test("gives Dart's ids on random catalogs", () {
      for (int seed = 0; seed < 200; seed++) {
        _expectSameIds(_randomCatalog(Random(seed)));
      }
    });

    test('folds every code point the way Dart does', () {
      // Each character alone and between letters, as an album, an artist and
      // an album artist, so Dart's case table, trim and fold all get a say.
      final List<Track> tracks = <Track>[];
      for (int cp = 0; cp <= 0x10FFFF; cp++) {
        if (cp >= 0xD800 && cp <= 0xDFFF) continue;
        final String ch = String.fromCharCode(cp);
        tracks.add(
          Track(
            id: 'cp-$cp',
            title: 't',
            uri: 'u',
            albumName: cp.isEven ? 'A${ch}b' : ch,
            artistName: cp.isEven ? ch : 'Z$ch ',
            albumArtistName: cp % 3 == 0 ? ' $ch' : null,
          ),
        );
        if (tracks.length == 0x10000) {
          _expectSameIds(tracks);
          tracks.clear();
        }
      }
      _expectSameIds(tracks);
    });

    test('reads an unpaired surrogate as U+FFFD, as the Dart ids do', () {
      _expectSameIds(<Track>[
        _track('1', album: 'Broken \uE000', artist: 'A'),
        _track('2', album: 'Broken \uD83C', artist: 'A\uDC00'),
      ]);
    });

    test('an empty catalog has no albums or artists', () {
      final ({List<Album> albums, List<Artist> artists}) groups =
          groupLibrary(const <Track>[]);
      expect(groups.albums, isEmpty);
      expect(groups.artists, isEmpty);
    });
  });
}

/// Every track's native album and artist ids are the ones Dart computes.
void _expectSameIds(List<Track> tracks) {
  final NativeLibraryGroups native = NativeLibraryGrouping.group(tracks);
  for (int i = 0; i < tracks.length; i++) {
    final Track track = tracks[i];
    final String album = native.albumIds[native.trackAlbum[i]];
    final String artist = native.artistIds[native.trackArtist[i]];
    if (album != albumIdForTrack(track) || artist != artistIdForTrack(track)) {
      fail(
        'ids differ for ${track.id} '
        '(album ${_codes(track.albumName)}, '
        'artist ${_codes(track.artistName)}, '
        'album artist ${_codes(track.albumArtistName)}): '
        'native $album / $artist, '
        'Dart ${albumIdForTrack(track)} / ${artistIdForTrack(track)}',
      );
    }
  }
}

String _codes(String? text) => text == null
    ? 'null'
    : text.codeUnits.map((int u) => u.toRadixString(16)).join(' ');

Track _track(
  String id, {
  String? album,
  String? artist,
  String? albumArtist,
  String? albumId,
  String? artwork,
}) =>
    Track(
      id: id,
      title: 'Song $id',
      uri: 'file:///$id.flac',
      albumName: album,
      artistName: artist,
      albumArtistName: albumArtist,
      albumId: albumId,
      artworkUri: artwork == null ? null : Uri.parse(artwork),
    );

List<Track> _tricky() => <Track>[
      _track('1', album: 'Homogenic', artist: 'Björk'),
      _track('2', album: 'HOMOGENIC', artist: 'bjork', artwork: 'a:1'),
      _track('3', album: '  Homogenic  ', artist: 'Bjork\t'),
      _track('4', album: 'Greatest Hits', artist: 'ABBA'),
      _track('5', album: 'Greatest Hits', artist: 'Queen'),
      _track('6', album: 'Greatest Hits', artist: 'Main feat. Guest'),
      _track('7', album: 'Greatest Hits', artist: 'Main', albumArtist: 'Main'),
      _track('8', album: 'Greatest Hits', artist: 'Other', albumArtist: 'Main'),
      _track('9', albumId: 'jellyfin:al-1', album: 'One', artist: 'A'),
      _track('10', albumId: ' jellyfin:al-1 ', album: 'Two', artist: 'B'),
      _track('11', albumId: '   ', album: 'Spaces', artist: 'C'),
      _track('12', albumId: '', album: 'Spaces', artist: 'C'),
      _track('13', album: '', artist: 'C'),
      _track('14', album: null, artist: 'C', artwork: 'a:14'),
      _track('15', album: 'Unknown Album', artist: 'C'),
      _track('16', album: null, artist: null),
      _track('17', album: '', artist: ''),
      _track('18', album: 'x', artist: '   '),
      _track('19', album: 'x', artist: ' '),
      _track('20', album: 'x', artist: '﻿'),
      // Dart lower-cases İ to a plain i, Rust to i + U+0307.
      _track('21', album: 'İstanbul', artist: 'İ'),
      _track('22', album: 'istanbul', artist: 'i'),
      // Dart has no final sigma, Rust's str::to_lowercase does.
      _track('23', album: 'ΟΔΟΣ', artist: 'ΣΣ'),
      _track('24', album: 'οδοσ', artist: 'σσ'),
      _track('25', album: 'Straße', artist: 'STRASSE'),
      _track('26', album: 'Ⓐ', artist: 'Ⓑ'),
      _track('27', album: '𝄞 Music', artist: '🎵'),
      _track('28', album: '～', artist: '🎵'),
      _track('29', album: 'a b', artist: 'c'),
      _track('30', album: 'a', artist: 'b c'),
      _track('31', album: 'a|b', artist: 'c'),
      _track('32', album: 'a', artist: 'b|c'),
      _track('33', album: 'Ǆ', artist: 'ǅ'),
      _track('34', album: 'Ꭰ', artist: 'ꭰ'),
      _track('35', album: 'Ä', artist: 'Ä'),
      _track('36', album: 'Encyclopædia', artist: 'ŒUVRE'),
    ];

const List<String?> _names = <String?>[
  null,
  '',
  ' ',
  ' ',
  '﻿',
  'Björk',
  'bjork',
  'BJÖRK ',
  'Motörhead',
  'İ',
  'i',
  'Σ',
  'ς',
  'σ',
  'Straße',
  'strasse',
  '𝄞',
  '🎵',
  '～',
  'a b',
  'a  b',
  'a\tb',
  'Unknown Album',
  'Unknown Artist',
  'Ꭰ',
  'ǅ',
  'a|b',
  'Ⅻ',
  'Ａ',
];

const List<String?> _albumIds = <String?>[
  null,
  null,
  null,
  '',
  ' ',
  'jellyfin:al-1',
  ' jellyfin:al-1',
  'plex:7',
  'Ä',
];

List<Track> _randomCatalog(Random random) {
  String? pick(List<String?> from) => from[random.nextInt(from.length)];
  return <Track>[
    for (int i = 0; i < random.nextInt(60); i++)
      _track(
        '$i',
        album: pick(_names),
        artist: pick(_names),
        albumArtist: random.nextInt(3) == 0 ? pick(_names) : null,
        albumId: pick(_albumIds),
        artwork: random.nextInt(4) == 0 ? 'art:$i' : null,
      ),
  ];
}
