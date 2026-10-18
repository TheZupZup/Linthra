import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/library/song_sort.dart';

Track _song(
  String id,
  String title, {
  String? artist,
  String? album,
  String? albumArtist,
  int? trackNumber,
  int? discNumber,
}) {
  return Track(
    id: id,
    title: title,
    uri: 'file:///$id.mp3',
    artistName: artist,
    albumName: album,
    albumArtistName: albumArtist,
    trackNumber: trackNumber,
    discNumber: discNumber,
  );
}

/// A small library with the awkward cases in it: accented artists and titles,
/// a title starting with a digit, a song with no tags at all and one whose tags
/// are blank.
final List<Track> _library = <Track>[
  _song(
    '1',
    'Zombie',
    artist: 'The Cranberries',
    album: 'No Need to Argue',
    trackNumber: 7,
  ),
  _song(
    '2',
    'Linger',
    artist: 'The Cranberries',
    album: 'Everybody Else Is Doing It',
    trackNumber: 2,
  ),
  _song(
    '3',
    'Dreams',
    artist: 'The Cranberries',
    album: 'Everybody Else Is Doing It',
    trackNumber: 1,
  ),
  _song(
    '4',
    'La vie en rose',
    artist: 'Édith Piaf',
    album: 'Best Of',
    trackNumber: 1,
  ),
  _song(
    '5',
    'Non, je ne regrette rien',
    artist: 'Édith Piaf',
    album: 'Best Of',
    trackNumber: 2,
  ),
  _song(
    '6',
    'Around the World',
    artist: 'Daft Punk',
    album: 'Homework',
    trackNumber: 7,
  ),
  _song(
    '7',
    '99 Luftballons',
    artist: 'Nena',
    album: '99 Luftballons',
    trackNumber: 1,
  ),
  _song('8', 'Untitled'),
  _song('9', 'Demo', artist: '', album: '   '),
  _song('10', 'Été', artist: 'Angèle', album: 'Brol', trackNumber: 3),
];

/// When some of [_library] first entered the library. Dreams, Linger and 99
/// Luftballons came in with the same scan; 5, 8 and 9 were never stamped.
final Map<String, DateTime> _addedAt = <String, DateTime>{
  'file:///1.mp3': DateTime(2026, 1, 1),
  'file:///2.mp3': DateTime(2026, 3, 1),
  'file:///3.mp3': DateTime(2026, 3, 1),
  'file:///4.mp3': DateTime(2026, 2, 1),
  'file:///6.mp3': DateTime(2026, 6, 1),
  'file:///7.mp3': DateTime(2026, 3, 1),
  'file:///10.mp3': DateTime(2026, 5, 1),
};

SortedSongs _sorted(SongSort sort, [List<Track>? tracks]) =>
    sortSongs(tracks ?? _library, sort, addedAt: _addedAt);

List<String> _titles(SortedSongs sorted) =>
    <String>[for (final Track track in sorted.tracks) track.title];

/// Each section once, in the order the list shows them.
List<String> _sectionRuns(SortedSongs sorted) {
  final List<String> runs = <String>[];
  for (final String section in sorted.sections!) {
    if (runs.isEmpty || runs.last != section) runs.add(section);
  }
  return runs;
}

void main() {
  group('SongSort', () {
    test('offers every field in both directions', () {
      expect(
        <(SongSortField, bool)>[
          for (final SongSort sort in SongSort.values)
            (sort.field, sort.descending),
        ],
        <(SongSortField, bool)>[
          (SongSortField.title, false),
          (SongSortField.title, true),
          (SongSortField.artist, false),
          (SongSortField.artist, true),
          (SongSortField.album, false),
          (SongSortField.album, true),
          (SongSortField.dateAdded, true),
          (SongSortField.dateAdded, false),
        ],
      );
    });

    test('reads every order back from its stored name', () {
      for (final SongSort sort in SongSort.values) {
        expect(SongSort.byName(sort.name), sort);
      }
      expect(SongSort.byName(null), isNull);
      expect(SongSort.byName(''), isNull);
      expect(SongSort.byName('releaseDate'), isNull);
      expect(SongSort.fallback, SongSort.titleAscending);
    });
  });

  group('sortSongs by title', () {
    test('A to Z folds accents and puts the # section first', () {
      final SortedSongs sorted = _sorted(SongSort.titleAscending);

      expect(_titles(sorted), <String>[
        '99 Luftballons',
        'Around the World',
        'Demo',
        'Dreams',
        'Été',
        'La vie en rose',
        'Linger',
        'Non, je ne regrette rien',
        'Untitled',
        'Zombie',
      ]);
      expect(
        _sectionRuns(sorted),
        <String>['#', 'A', 'D', 'E', 'L', 'N', 'U', 'Z'],
      );
    });

    test('Z to A runs the other way, with # last', () {
      final SortedSongs sorted = _sorted(SongSort.titleDescending);

      expect(
        _titles(sorted),
        _titles(_sorted(SongSort.titleAscending)).reversed.toList(),
      );
      expect(
        _sectionRuns(sorted),
        <String>['Z', 'U', 'N', 'L', 'E', 'D', 'A', '#'],
      );
    });

    test('a leading space or another script does not move a title', () {
      final SortedSongs sorted = sortSongs(<Track>[
        _song('a', 'Mango'),
        _song('b', ' Zebra'),
        _song('c', 'Кино'),
        _song('d', 'Ödland'),
        _song('e', ''),
      ], SongSort.titleAscending);

      expect(
        _titles(sorted),
        <String>['', 'Кино', 'Mango', 'Ödland', ' Zebra'],
      );
      expect(sorted.sections, <String>['#', '#', 'M', 'O', 'Z']);
    });
  });

  group('sortSongs by artist', () {
    test('A to Z reads each artist album by album, untagged songs last', () {
      final SortedSongs sorted = _sorted(SongSort.artistAscending);

      expect(_titles(sorted), <String>[
        // Angèle
        'Été',
        // Daft Punk
        'Around the World',
        // Édith Piaf, filed under E with its accent folded away.
        'La vie en rose',
        'Non, je ne regrette rien',
        // Nena
        '99 Luftballons',
        // The Cranberries: one album in track order, then the next.
        'Dreams',
        'Linger',
        'Zombie',
        // No artist, or a blank one, by title.
        'Demo',
        'Untitled',
      ]);
      expect(_sectionRuns(sorted), <String>['A', 'D', 'E', 'N', 'T', '?']);
    });

    test('Z to A reverses the artists but not their albums', () {
      final SortedSongs sorted = _sorted(SongSort.artistDescending);

      expect(_titles(sorted), <String>[
        'Dreams',
        'Linger',
        'Zombie',
        '99 Luftballons',
        'La vie en rose',
        'Non, je ne regrette rien',
        'Around the World',
        'Été',
        // Still last: an unknown artist isn't the end of the alphabet.
        'Demo',
        'Untitled',
      ]);
      expect(_sectionRuns(sorted), <String>['T', 'N', 'E', 'D', 'A', '?']);
    });

    test('an artist in another script files under #', () {
      final SortedSongs sorted = sortSongs(<Track>[
        _song('a', 'Gruppa krovi', artist: 'Кино'),
        _song('b', 'One', artist: 'U2'),
        _song('c', 'Help', artist: '2Pac'),
      ], SongSort.artistAscending);

      expect(_titles(sorted), <String>['Help', 'Gruppa krovi', 'One']);
      expect(sorted.sections, <String>['#', '#', 'U']);
    });
  });

  group('sortSongs by album', () {
    test('A to Z plays each album in order, untagged songs last', () {
      final SortedSongs sorted = _sorted(SongSort.albumAscending);

      expect(_titles(sorted), <String>[
        '99 Luftballons',
        // Best Of
        'La vie en rose',
        'Non, je ne regrette rien',
        // Brol
        'Été',
        // Everybody Else Is Doing It
        'Dreams',
        'Linger',
        // Homework
        'Around the World',
        // No Need to Argue
        'Zombie',
        // No album, or a blank one.
        'Demo',
        'Untitled',
      ]);
      expect(
        _sectionRuns(sorted),
        <String>['#', 'B', 'E', 'H', 'N', '?'],
      );
    });

    test('Z to A reverses the albums but not their tracks', () {
      final SortedSongs sorted = _sorted(SongSort.albumDescending);

      expect(_titles(sorted), <String>[
        'Zombie',
        'Around the World',
        'Dreams',
        'Linger',
        'Été',
        'La vie en rose',
        'Non, je ne regrette rien',
        '99 Luftballons',
        'Demo',
        'Untitled',
      ]);
      expect(
        _sectionRuns(sorted),
        <String>['N', 'H', 'E', 'B', '#', '?'],
      );
    });

    test('two albums with the same name never interleave', () {
      final SortedSongs sorted = sortSongs(<Track>[
        _song(
          'q1',
          'Bohemian Rhapsody',
          artist: 'Queen',
          album: 'Greatest Hits',
          trackNumber: 1,
        ),
        _song(
          'a2',
          'Waterloo',
          artist: 'ABBA',
          album: 'Greatest Hits',
          trackNumber: 2,
        ),
        _song(
          'q2',
          'Another One Bites the Dust',
          artist: 'Queen',
          album: 'Greatest Hits',
          trackNumber: 2,
        ),
        _song(
          'a1',
          'Dancing Queen',
          artist: 'ABBA',
          album: 'Greatest Hits',
          trackNumber: 1,
        ),
      ], SongSort.albumAscending);

      expect(_titles(sorted), <String>[
        'Dancing Queen',
        'Waterloo',
        'Bohemian Rhapsody',
        'Another One Bites the Dust',
      ]);
    });

    test('a compilation stays together in disc and track order', () {
      final SortedSongs sorted = sortSongs(<Track>[
        _song(
          'c3',
          'Third',
          artist: 'Abe',
          album: 'Now',
          albumArtist: 'Various Artists',
          trackNumber: 1,
          discNumber: 2,
        ),
        _song(
          'c2',
          'Second',
          artist: 'Abe',
          album: 'Now',
          albumArtist: 'Various Artists',
          trackNumber: 2,
          discNumber: 1,
        ),
        _song(
          'c1',
          'First',
          artist: 'Zed',
          album: 'Now',
          albumArtist: 'Various Artists',
          trackNumber: 1,
          discNumber: 1,
        ),
      ], SongSort.albumAscending);

      expect(_titles(sorted), <String>['First', 'Second', 'Third']);
    });
  });

  group('sortSongs by date added', () {
    test('newest first, songs added together by title, unstamped last', () {
      final SortedSongs sorted = _sorted(SongSort.newestAdded);

      expect(_titles(sorted), <String>[
        'Around the World',
        'Été',
        // The same scan stamped these three with one time.
        '99 Luftballons',
        'Dreams',
        'Linger',
        'La vie en rose',
        'Zombie',
        // Nobody recorded when these arrived.
        'Demo',
        'Non, je ne regrette rien',
        'Untitled',
      ]);
      // There are no letters to jump to in a timeline.
      expect(sorted.sections, isNull);
    });

    test('oldest first keeps the unstamped songs last too', () {
      final SortedSongs sorted = _sorted(SongSort.oldestAdded);

      expect(_titles(sorted), <String>[
        'Zombie',
        'La vie en rose',
        '99 Luftballons',
        'Dreams',
        'Linger',
        'Été',
        'Around the World',
        'Demo',
        'Non, je ne regrette rien',
        'Untitled',
      ]);
      expect(sorted.sections, isNull);
    });

    test('with no times at all it reads by title', () {
      for (final SongSort sort in <SongSort>[
        SongSort.newestAdded,
        SongSort.oldestAdded,
      ]) {
        expect(
          _titles(sortSongs(_library, sort)),
          _titles(_sorted(SongSort.titleAscending)),
        );
      }
    });
  });

  group('sortSongs ties', () {
    final List<Track> intros = <Track>[
      _song('i1', 'Intro', artist: 'Zed', album: 'B'),
      _song('i2', 'intro'),
      _song('i3', 'Intro', artist: 'Abe', album: 'C'),
      _song('i4', 'Intro'),
      _song('i5', 'Intro', artist: 'Abe', album: 'A'),
      _song('i6', 'Intro'),
    ];

    test('duplicate titles are ordered by artist, album, then uri', () {
      expect(
        <String>[
          for (final Track track
              in sortSongs(intros, SongSort.titleAscending).tracks)
            track.id,
        ],
        <String>['i5', 'i3', 'i1', 'i4', 'i6', 'i2'],
      );
    });

    test('every order is the same whatever order the songs came in', () {
      final List<Track> songs = <Track>[..._library, ...intros];
      for (final SongSort sort in SongSort.values) {
        final List<Track> expected =
            sortSongs(songs, sort, addedAt: _addedAt).tracks;
        for (int seed = 0; seed < 20; seed++) {
          final List<Track> shuffled = List<Track>.of(songs)
            ..shuffle(Random(seed));
          expect(
            sortSongs(shuffled, sort, addedAt: _addedAt).tracks,
            orderedEquals(expected),
            reason: '$sort, seed $seed',
          );
        }
      }
    });
  });

  // A generated library with every awkward value mixed in, checked against
  // the properties the list relies on rather than one hand-written order.
  group('sortSongs on a large mixed library', () {
    const List<String?> words = <String?>[
      'Alpha',
      'alpha',
      'Écho',
      'echo',
      ' Ünder',
      'zeta',
      'Zeta',
      '42',
      '(intro)',
      'Кино',
      '東京',
      '',
      '  ',
      null,
    ];
    final Random random = Random(893);
    String? pick() => words[random.nextInt(words.length)];
    final List<Track> songs = <Track>[
      for (int i = 0; i < 3000; i++)
        _song(
          'g$i',
          pick() ?? 'Song',
          artist: pick(),
          album: pick(),
          trackNumber: random.nextBool() ? random.nextInt(12) + 1 : null,
        ),
    ];
    final Map<String, DateTime> addedAt = <String, DateTime>{
      for (final Track track in songs)
        if (random.nextInt(4) != 0)
          track.uri: DateTime(2026, 1, 1 + random.nextInt(5)),
    };

    for (final SongSort sort in SongSort.values) {
      test('$sort keeps every song once and every section in one run', () {
        final SortedSongs sorted = sortSongs(songs, sort, addedAt: addedAt);

        expect(sorted.tracks.toSet(), songs.toSet());
        expect(sorted.tracks, hasLength(songs.length));

        final List<String>? sections = sorted.sections;
        if (sort.field == SongSortField.dateAdded) {
          expect(sections, isNull);
          // Undated songs are all at the end, in either direction.
          final int firstUndated = sorted.tracks
              .indexWhere((Track t) => !addedAt.containsKey(t.uri));
          expect(
            sorted.tracks
                .skip(firstUndated)
                .every((Track t) => !addedAt.containsKey(t.uri)),
            isTrue,
          );
          return;
        }
        expect(sections, hasLength(songs.length));
        final List<String> runs = _sectionRuns(sorted);
        expect(runs.toSet(), hasLength(runs.length), reason: 'one run each');
        if (sort.field == SongSortField.title) {
          // Every song has a title, even an empty one ('#').
          expect(runs, isNot(contains(kUnknownSongSection)));
        } else {
          expect(runs.last, kUnknownSongSection);
        }
      });
    }
  });
}
