import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/settings/plex/plex_library_signature.dart';

final Track _aurora = Track(
  id: '101',
  title: 'Aurora',
  uri: 'plex:101',
  artistName: 'The Band',
  albumName: 'First Light',
  albumId: '201',
  albumArtistName: 'The Band',
  duration: const Duration(milliseconds: 215000),
  trackNumber: 1,
  artworkUri: Uri.parse('plex-art:/library/metadata/101/thumb/1'),
);

const Track _dusk = Track(id: '102', title: 'Dusk', uri: 'plex:102');

void main() {
  test('is the same in every run', () {
    // A literal, so a signature saved by one launch is proven to match the
    // next. Object.hash, which this replaced, is seeded afresh on every run.
    expect(
      plexLibrarySignature(<String>['5', '3'], <Track>[_aurora, _dusk]),
      '3,5|2|c496e64f50ab5103d31f1628bee6406f8ff53a8efa585bbc00ead814ce58427a',
    );
  });

  test('ignores the order of the tracks and of the sections', () {
    expect(
      plexLibrarySignature(<String>['3', '5'], <Track>[_dusk, _aurora]),
      plexLibrarySignature(<String>['5', '3'], <Track>[_aurora, _dusk]),
    );
  });

  test('changes with the selection and with the track count', () {
    final String base = plexLibrarySignature(<String>['5'], <Track>[_aurora]);

    expect(plexLibrarySignature(<String>['6'], <Track>[_aurora]), isNot(base));
    expect(
      plexLibrarySignature(<String>['5'], <Track>[_aurora, _dusk]),
      isNot(base),
    );
  });

  test('changes when any field the catalog keeps changes', () {
    final String base = plexLibrarySignature(<String>['5'], <Track>[_aurora]);
    final List<Track> edits = <Track>[
      _aurora.copyWith(id: '999'),
      _aurora.copyWith(title: 'Aurora (Live)'),
      _aurora.copyWith(artistName: 'Someone Else'),
      _aurora.copyWith(albumName: 'Second Light'),
      _aurora.copyWith(albumId: '202'),
      _aurora.copyWith(albumArtistName: 'Various Artists'),
      _aurora.copyWith(duration: const Duration(milliseconds: 215001)),
      _aurora.copyWith(trackNumber: 2),
      _aurora.copyWith(artworkUri: Uri.parse('plex-art:/other')),
    ];
    for (final Track edited in edits) {
      expect(
        plexLibrarySignature(<String>['5'], <Track>[edited]),
        isNot(base),
        reason: '$edited',
      );
    }
  });

  test('cannot be fooled by text that spans two fields', () {
    const Track a = Track(id: '1', title: 'a","b', uri: 'plex:1');
    const Track b = Track(id: '1', title: 'a', uri: 'plex:1', artistName: 'b');

    expect(
      plexLibrarySignature(const <String>['5'], const <Track>[a]),
      isNot(plexLibrarySignature(const <String>['5'], const <Track>[b])),
    );
  });
}
