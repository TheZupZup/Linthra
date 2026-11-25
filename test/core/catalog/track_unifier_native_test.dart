import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/logical_track.dart';
import 'package:linthra/core/catalog/source_priority.dart';
import 'package:linthra/core/catalog/track_unifier.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/native/linthra_core.dart';

/// The Rust merge has to give exactly what the Dart rules give: the same
/// logical tracks, in the same order, with the same copies best first. A
/// drift either merges two different songs or shows one song twice.
///
/// Runs through the real Rust library hook/build.dart builds for the test
/// host, and is skipped without it (CI sets LINTHRA_REQUIRE_RUST=1, which
/// fails linthra_core_test.dart instead).
void main() {
  final Object skip = LinthraCore.isAvailable
      ? false
      : 'Rust core not built (install Rust, or see native/linthra_core/README.md)';

  const List<SourcePriority> priorities = <SourcePriority>[
    SourcePriority.fallback,
    SourcePriority(<String>['subsonic', 'local']),
    SourcePriority(<String>['plex', 'jellyfin', 'subsonic']),
  ];

  group('native track unifier', skip: skip, () {
    test('matches Dart on titles that are easy to get wrong', () {
      for (final SourcePriority priority in priorities) {
        _expectSameAsDart(_tricky(), priority);
      }
    });

    test('matches Dart on random catalogs', () {
      for (int seed = 0; seed < 300; seed++) {
        final Random random = Random(seed);
        _expectSameAsDart(
          _randomCatalog(random),
          priorities[seed % priorities.length],
        );
      }
    });

    test('matches Dart on blocks larger than an insertion sort', () {
      // Dozens of copies of one song share a block, past the size where
      // Dart's sort stops being an insertion sort.
      final List<Track> tracks = <Track>[
        for (int i = 0; i < 120; i++)
          _track(
            _schemes[i % _schemes.length],
            '${119 - i}',
            title: 'Hello',
            artist: 'Adele',
            album: i.isEven ? '25' : '25 (Deluxe)',
            seconds: 180 + i % 4,
          ),
      ];
      for (final SourcePriority priority in priorities) {
        _expectSameAsDart(tracks, priority);
      }
    });

    test('merges a real-world featured-artist drift', () {
      final List<LogicalTrack> merged = unifyTracks(<Track>[
        _track('jellyfin:', '1',
            title: 'CAREFUL', artist: 'NF', album: 'The Search'),
        _track(
          'subsonic:',
          '1',
          title: 'CAREFUL (feat. Cordae)',
          artist: 'NF, Cordae',
          album: 'The Search (Deluxe)',
        ),
      ], SourcePriority.fallback);
      expect(merged, hasLength(1));
      expect(merged.single.sourceIds, <String>['jellyfin', 'subsonic']);
    });

    test('leaves text with an unpaired surrogate to Dart', () {
      final List<Track> tracks = <Track>[
        _track('jellyfin:', '1',
            title: 'Hello \uD800', artist: 'Adele', album: '25'),
        _track('subsonic:', '1', title: 'Hello', artist: 'Adele', album: '25'),
      ];
      _expectSameAsDart(tracks, SourcePriority.fallback);
    });
  });
}

const List<String> _schemes = <String>[
  'jellyfin:',
  'subsonic:',
  'plex:',
  '/music/',
];

Track _track(
  String scheme,
  String id, {
  required String title,
  String? artist,
  String? album,
  int seconds = 180,
  int? number,
}) =>
    Track(
      id: id,
      title: title,
      uri: '$scheme$id',
      artistName: artist,
      albumName: album,
      duration: Duration(seconds: seconds),
      trackNumber: number,
    );

void _expectSameAsDart(List<Track> tracks, SourcePriority priority) {
  final List<LogicalTrack> dart = unifyTracksInDart(tracks, priority);
  final List<LogicalTrack> rust = unifyTracks(tracks, priority);
  expect(
    _describe(rust),
    _describe(dart),
    reason: 'priority ${priority.preferredOrder}',
  );
  expect(rust, dart);
}

/// The uris of each logical track's copies, readable in a failure.
List<String> _describe(List<LogicalTrack> logical) => <String>[
      for (final LogicalTrack l in logical) l.allTrackUris.join(' + '),
    ];

/// Titles, artists and albums around every rule: feat qualifiers in and out
/// of brackets, word boundaries, `_`, accents and case Dart folds, versions,
/// editions, stopwords, and uris whose order differs between UTF-8 and
/// UTF-16.
List<Track> _tricky() {
  const List<String> titles = <String>[
    'Careful',
    'CAREFUL feat. Cordae',
    'Careful (feat. Cordae)',
    'Careful [ft Cordae] (Live)',
    'Careful (Live)',
    'Careful ft',
    'Careful_feat x',
    'Careful (featuring x',
    'Careful feat x (Remix)',
    'Careful (x) feat y',
    'Careful ((feat y)',
    'Careful (Feat y)',
    'Careful (Featuring Ÿ)',
    'Cäreful',
    'CAREFUL',
    'Ｃareful',
    'İstanbul',
    'istanbul',
    'Feature Film',
    'Ft. Lauderdale',
    'feat',
    '(feat x)',
    'Song 2',
    'Song  2',
  ];
  const List<String> artists = <String>[
    'NF',
    'NF, Cordae',
    'NF feat. Cordae',
    'Hall & Oates',
    'Hall and Oates',
    'and',
    'Björk',
    'Bjork',
    'Ⅻ',
  ];
  const List<String> albums = <String>[
    'The Search',
    'The Search (Deluxe)',
    'Other',
    'Œuvre',
    'oeuvre'
  ];
  const List<String> ids = <String>['1', 'a', '\u{1F600}', '！', '', 'b'];
  final List<Track> tracks = <Track>[];
  int n = 0;
  for (final String title in titles) {
    for (final String artist in artists) {
      final String scheme = _schemes[n % _schemes.length];
      tracks.add(
        _track(
          scheme,
          '${ids[n % ids.length]}$n',
          title: title,
          artist: artist,
          album: albums[n % albums.length],
          seconds: 180 + n % 5,
          number: n % 7 == 0 ? null : 1 + n % 2,
        ),
      );
      n++;
    }
  }
  return tracks;
}

List<Track> _randomCatalog(Random random) {
  const List<String> titleWords = <String>[
    'hello',
    'Hello',
    'feat.',
    'ft',
    'featuring',
    '(feat.',
    '(Live)',
    '[ft',
    'x)',
    'y]',
    '(',
    ')',
    'Café',
    'cafe',
    'Ǆ',
    'İ',
    '_feat',
    'Remix',
    '2',
  ];
  const List<String> artists = <String>[
    'Adele',
    'adele',
    'Adele feat. NF',
    'NF and Adele',
    'Ädele',
    '',
  ];
  const List<String> albums = <String>['25', '25 (Deluxe)', 'Hits', 'hits', ''];
  final int count = random.nextInt(60);
  return <Track>[
    for (int i = 0; i < count; i++)
      _track(
        _schemes[random.nextInt(_schemes.length)],
        // Few ids, so uris sometimes repeat.
        '${random.nextInt(count + 5)}',
        title: <String>[
          for (int w = 0; w <= random.nextInt(3); w++)
            titleWords[random.nextInt(titleWords.length)],
        ].join(' '),
        artist: random.nextInt(10) == 0
            ? null
            : artists[random.nextInt(artists.length)],
        album: random.nextInt(10) == 0
            ? null
            : albums[random.nextInt(albums.length)],
        seconds: random.nextInt(6) - 1 + 178,
        number: random.nextBool() ? null : random.nextInt(3),
      ),
  ];
}
