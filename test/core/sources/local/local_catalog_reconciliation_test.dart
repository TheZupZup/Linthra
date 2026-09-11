import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/local/local_catalog_reconciliation.dart';
import 'package:linthra/core/sources/local/local_track_identity.dart';

/// A tagged track: the duration is what tells the scan apart from the
/// name/folder fallback, so every track meant to be matchable has one.
Track _tagged(
  String path, {
  String title = 'Holocene',
  String? artist = 'Bon Iver',
  String? album = 'Bon Iver',
  int ms = 337000,
  int? trackNumber = 5,
  String? albumId,
}) {
  return Track(
    id: path,
    uri: path,
    title: title,
    artistName: artist,
    albumName: album,
    albumId: albumId,
    duration: Duration(milliseconds: ms),
    trackNumber: trackNumber,
  );
}

/// What a file with no readable tags looks like after the mapper's fallback:
/// title from the file name, artist/album from the folders, no duration.
Track _untagged(String path, {String title = 'Holocene'}) => Track(
      id: path,
      uri: path,
      title: title,
      artistName: 'Bon Iver',
      albumName: 'Bon Iver',
    );

bool _everythingRefreshed(String uri) => true;

void main() {
  group('LocalTrackIdentity', () {
    test('a file whose tags were read has an identity', () {
      expect(LocalTrackIdentity.of(_tagged('/music/a.flac')), isNotNull);
    });

    test('a file with no tags has none, so it can never match', () {
      expect(LocalTrackIdentity.of(_untagged('/music/a.flac')), isNull);
    });

    test('identity ignores the path entirely', () {
      expect(
        LocalTrackIdentity.of(_tagged('/music/a.flac')),
        LocalTrackIdentity.of(_tagged('/elsewhere/deep/b.flac')),
      );
    });

    test('casing and padding do not break a match', () {
      expect(
        LocalTrackIdentity.of(_tagged('/a.flac', title: 'Holocene')),
        LocalTrackIdentity.of(_tagged('/b.flac', title: '  HOLOCENE  ')),
      );
    });

    test('a different length is a different track', () {
      expect(
        LocalTrackIdentity.of(_tagged('/a.flac', ms: 337000)),
        isNot(LocalTrackIdentity.of(_tagged('/b.flac', ms: 337001))),
      );
    });

    test('an album id sharpens the match rather than being ignored', () {
      expect(
        LocalTrackIdentity.of(_tagged('/a.flac', albumId: 'mb-1')),
        isNot(LocalTrackIdentity.of(_tagged('/b.flac', albumId: 'mb-2'))),
      );
    });
  });

  group('LocalCatalogReconciliation', () {
    test('a file a readable folder no longer holds is a deletion', () {
      final LocalCatalogReconciliation result =
          LocalCatalogReconciliation.resolve(
        previous: <Track>[_tagged('/music/a.flac'), _tagged('/music/b.flac')],
        scanned: <Track>[_tagged('/music/a.flac')],
        wasRefreshed: _everythingRefreshed,
      );

      expect(result.removedUris, <String>['/music/b.flac']);
      expect(result.moves, isEmpty);
    });

    test('the same tagged file at a new path is a move, not a delete', () {
      final LocalCatalogReconciliation result =
          LocalCatalogReconciliation.resolve(
        previous: <Track>[_tagged('/music/inbox/a.flac')],
        scanned: <Track>[_tagged('/music/Bon Iver/Bon Iver/05.flac')],
        wasRefreshed: _everythingRefreshed,
      );

      expect(
        result.moves,
        <LocalTrackMove>[
          const LocalTrackMove(
            from: '/music/inbox/a.flac',
            to: '/music/Bon Iver/Bon Iver/05.flac',
          ),
        ],
      );
      expect(result.removedUris, isEmpty);
    });

    test('a matching file name is not enough on its own', () {
      // Both sides are untagged, so their titles and artist/album come from the
      // path. Matching them would be matching the file name in disguise.
      final LocalCatalogReconciliation result =
          LocalCatalogReconciliation.resolve(
        previous: <Track>[_untagged('/music/one/01 - Intro.mp3')],
        scanned: <Track>[_untagged('/music/two/01 - Intro.mp3')],
        wasRefreshed: _everythingRefreshed,
      );

      expect(result.moves, isEmpty);
      expect(result.removedUris, <String>['/music/one/01 - Intro.mp3']);
    });

    test('two new files sharing an identity is a copy, so no move', () {
      final LocalCatalogReconciliation result =
          LocalCatalogReconciliation.resolve(
        previous: <Track>[_tagged('/music/original.flac')],
        scanned: <Track>[
          _tagged('/music/copies/one.flac'),
          _tagged('/music/copies/two.flac'),
        ],
        wasRefreshed: _everythingRefreshed,
      );

      expect(result.moves, isEmpty);
      expect(
        result.removedUris,
        <String>['/music/original.flac'],
        reason: 'the original is gone; neither copy may claim its history',
      );
    });

    test('two disappeared files sharing an identity is ambiguous too', () {
      final LocalCatalogReconciliation result =
          LocalCatalogReconciliation.resolve(
        previous: <Track>[
          _tagged('/music/dup-a.flac'),
          _tagged('/music/dup-b.flac'),
        ],
        scanned: <Track>[_tagged('/music/moved.flac')],
        wasRefreshed: _everythingRefreshed,
      );

      expect(result.moves, isEmpty);
      expect(
        result.removedUris,
        containsAll(<String>['/music/dup-a.flac', '/music/dup-b.flac']),
      );
    });

    test('an unreadable folder produces neither deletions nor moves', () {
      // The drive was not plugged in, so nothing under it was looked for.
      final LocalCatalogReconciliation result =
          LocalCatalogReconciliation.resolve(
        previous: <Track>[
          _tagged('/media/usb/a.flac'),
          _tagged('/music/b.flac', title: 'Perth'),
        ],
        scanned: <Track>[_tagged('/music/b.flac', title: 'Perth')],
        wasRefreshed: (String uri) => uri.startsWith('/music/'),
      );

      expect(result.removedUris, isEmpty);
      expect(result.moves, isEmpty);
      expect(result.isEmpty, isTrue);
    });

    test('a file cannot "move" out of an unreadable folder', () {
      // The offline drive's copy must not be re-associated with a same-tagged
      // file that turned up in a folder that *was* read: it is still on the
      // drive, and the new one is a second copy.
      final LocalCatalogReconciliation result =
          LocalCatalogReconciliation.resolve(
        previous: <Track>[_tagged('/media/usb/a.flac')],
        scanned: <Track>[_tagged('/music/a.flac')],
        wasRefreshed: (String uri) => uri.startsWith('/music/'),
      );

      expect(result.moves, isEmpty);
      expect(result.removedUris, isEmpty);
    });

    test('a re-tagged file is treated as new rather than guessed at', () {
      final LocalCatalogReconciliation result =
          LocalCatalogReconciliation.resolve(
        previous: <Track>[_tagged('/music/a.flac', ms: 337000)],
        scanned: <Track>[_tagged('/music/b.flac', ms: 400000)],
        wasRefreshed: _everythingRefreshed,
      );

      expect(result.moves, isEmpty);
      expect(result.removedUris, <String>['/music/a.flac']);
    });

    test('an empty previous catalog reconciles to nothing', () {
      expect(
        LocalCatalogReconciliation.resolve(
          previous: const <Track>[],
          scanned: <Track>[_tagged('/music/a.flac')],
          wasRefreshed: _everythingRefreshed,
        ).isEmpty,
        isTrue,
      );
    });

    test('several independent moves are all reported', () {
      final LocalCatalogReconciliation result =
          LocalCatalogReconciliation.resolve(
        previous: <Track>[
          _tagged('/inbox/1.flac', title: 'Perth', ms: 250000),
          _tagged('/inbox/2.flac', title: 'Minnesota', ms: 260000),
        ],
        scanned: <Track>[
          _tagged('/music/Perth.flac', title: 'Perth', ms: 250000),
          _tagged('/music/Minnesota.flac', title: 'Minnesota', ms: 260000),
        ],
        wasRefreshed: _everythingRefreshed,
      );

      expect(result.moves, hasLength(2));
      expect(result.removedUris, isEmpty);
    });
  });
}
