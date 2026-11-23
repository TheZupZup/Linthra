import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/native/linthra_core.dart';

/// These tests go through the real Rust library that hook/build.dart builds
/// for the test host. Without Rust installed the hook skips it and they are
/// skipped too, unless LINTHRA_REQUIRE_RUST=1 (as in CI), where a missing
/// library is a failure.
void main() {
  final bool required = Platform.environment['LINTHRA_REQUIRE_RUST'] == '1';
  final bool available = LinthraCore.isAvailable;
  final Object skip = available
      ? false
      : 'Rust core not built (install Rust, or see native/linthra_core/README.md)';

  test('the Rust core is bundled when the build requires it', () {
    if (!required) {
      markTestSkipped('LINTHRA_REQUIRE_RUST is not set');
      return;
    }
    expect(
      available,
      isTrue,
      reason: 'LINTHRA_REQUIRE_RUST=1 but the Rust core did not load. Is cargo '
          'on PATH where `flutter test` runs?',
    );
  });

  group('NativeSearchIndex', skip: skip, () {
    late NativeSearchIndex index;

    setUp(() {
      index = NativeSearchIndex.build(const <NativeSearchRecord>[
        NativeSearchRecord(
          id: 'jf:1',
          title: 'Jóga',
          artist: 'Björk',
          album: 'Homogenic',
          provider: 'jellyfin',
        ),
        NativeSearchRecord(
          id: 'nd:2',
          title: 'Hunter',
          artist: 'Björk',
          album: 'Homogenic',
          albumArtist: 'Björk',
          provider: 'navidrome',
        ),
        NativeSearchRecord(
          id: 'local:3',
          title: 'Ace of Spades',
          artist: 'Motörhead',
          album: 'Ace of Spades',
          provider: 'local',
        ),
      ])!;
    });

    tearDown(() => index.dispose());

    test('counts its tracks', () {
      expect(index.length, 3);
    });

    test('folds accents and case, and ANDs prefix terms', () {
      expect(index.search('BJORK hun'), <String>['nd:2']);
      expect(index.search('motorhead'), <String>['local:3']);
      expect(index.search('bjork'), unorderedEquals(<String>['jf:1', 'nd:2']));
    });

    test('ranks a title match above an album match', () {
      final NativeSearchIndex ranked = NativeSearchIndex.build(
        const <NativeSearchRecord>[
          // Listed first, so only the ranking can put the other one ahead.
          NativeSearchRecord(
            id: 'album-match',
            title: 'Song',
            artist: 'Artist',
            album: 'Wildflower',
            provider: 'local',
          ),
          NativeSearchRecord(
            id: 'title-match',
            title: 'Wildflower',
            artist: 'Artist',
            album: 'Record',
            provider: 'local',
          ),
        ],
      )!;
      addTearDown(ranked.dispose);
      expect(
        ranked.search('wildflower'),
        <String>['title-match', 'album-match'],
      );
    });

    test('caps results at the limit', () {
      expect(index.search('bjork', limit: 1), hasLength(1));
      expect(index.search('bjork', limit: 0), isEmpty);
      expect(index.search('bjork', limit: -3), isEmpty);
    });

    test('finds nothing for an empty query or an unknown word', () {
      expect(index.search(''), isEmpty);
      expect(index.search('   '), isEmpty);
      expect(index.search('zzzz'), isEmpty);
    });

    test('ids with non-ASCII text come back unchanged', () {
      final NativeSearchIndex other = NativeSearchIndex.build(
        const <NativeSearchRecord>[
          NativeSearchRecord(
            id: 'id:é✓ 東京',
            title: 'Title',
            artist: 'Artist',
            album: 'Album',
            provider: 'local',
          ),
        ],
      )!;
      addTearDown(other.dispose);
      expect(other.search('title'), <String>['id:é✓ 東京']);
    });

    test('an empty index finds nothing', () {
      final NativeSearchIndex empty =
          NativeSearchIndex.build(const <NativeSearchRecord>[])!;
      addTearDown(empty.dispose);
      expect(empty.length, 0);
      expect(empty.search('anything'), isEmpty);
    });

    test('dispose is idempotent and later searches throw', () {
      index.dispose();
      index.dispose();
      expect(() => index.search('bjork'), throwsStateError);
    });
  });
}
