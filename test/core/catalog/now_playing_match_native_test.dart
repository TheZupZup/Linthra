import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/now_playing_match.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/native/linthra_core.dart';

/// The Rust answer to "is this row the playing track?" has to be the Dart
/// one: a drift lights the now-playing marker on the wrong song, or announces
/// a track change that did not happen.
///
/// Runs through the real Rust library hook/build.dart builds for the test
/// host, and is skipped without it (CI sets LINTHRA_REQUIRE_RUST=1, which
/// fails linthra_core_test.dart instead).
void main() {
  final Object skip = LinthraCore.isAvailable
      ? false
      : 'Rust core not built (install Rust, or see native/linthra_core/README.md)';

  group('native now-playing match', skip: skip, () {
    test('matches Dart on random pairs', () {
      final Random random = Random(11);
      int matches = 0;
      for (int i = 0; i < 20000; i++) {
        final Track row = _random(random);
        final Track current = random.nextInt(4) == 0 ? row : _random(random);
        final bool dart =
            isCurrentPlaybackTrack(row, current, useNative: false);
        expect(
          isCurrentPlaybackTrack(row, current),
          dart,
          reason: '${_describe(row)} vs ${_describe(current)}',
        );
        if (dart && row.uri != current.uri) matches++;
      }
      // Enough cross-server matches that the comparison means something.
      expect(matches, greaterThan(50));
    });

    test('leaves text with an unpaired surrogate to Dart', () {
      final Track row = _track('jellyfin:', '1', 'Hello \uD800');
      final Track current = _track('subsonic:', '1', 'Hello \uDC00');
      expect(
        isCurrentPlaybackTrack(row, current),
        isCurrentPlaybackTrack(row, current, useNative: false),
      );
    });
  });
}

const List<String> _schemes = <String>[
  'jellyfin:',
  'subsonic:',
  'plex:',
  '/music/',
];

const List<String> _titles = <String>[
  'Hello',
  'HELLO',
  'Hello (Live)',
  'Hello feat. Guest',
  'Hello (feat. Guest)',
  'Привет',
  'ПРИВЕТ',
  'こんにちは',
  'Γειά',
  '',
];

const List<String> _artists = <String>['Adele', 'adele', 'Adele, NF', 'NF', ''];

const List<String> _albums = <String>['25', '25 (Deluxe)', 'Hits', ''];

Track _track(
  String scheme,
  String id,
  String title, {
  String artist = 'Adele',
  String album = '25',
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

Track _random(Random random) => _track(
      _schemes[random.nextInt(_schemes.length)],
      '${random.nextInt(3)}',
      _titles[random.nextInt(_titles.length)],
      artist: _artists[random.nextInt(_artists.length)],
      album: _albums[random.nextInt(_albums.length)],
      seconds: <int>[0, 178, 180, 181, 183][random.nextInt(5)],
      number: random.nextBool() ? null : random.nextInt(3),
    );

String _describe(Track t) =>
    '${t.uri} "${t.title}" / "${t.artistName}" / "${t.albumName}" '
    '${t.duration.inSeconds}s #${t.trackNumber}';
