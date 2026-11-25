// #883: an artist with two albums that share a title (Weezer's self-titled
// albums, Peter Gabriel 1-4) had their songs interleaved on the artist page,
// A1, B1, A2, B2, since the songs were ordered by album name and then track
// number. Albums with their own id are their own albums: album by album.
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/library_grouping.dart';
import 'package:linthra/core/models/track.dart';

Track _song(String album, int number) => Track(
      id: '$album-$number',
      title: 'Song $number',
      uri: 'jellyfin:$album-$number',
      artistName: 'Weezer',
      albumName: 'Weezer',
      albumId: album,
      trackNumber: number,
    );

void main() {
  test('two albums with one title play album by album', () {
    final List<Track> catalog = <Track>[
      _song('blue', 1),
      _song('green', 1),
      _song('blue', 2),
      _song('green', 2),
    ];
    final String artist = artistIdForTrack(catalog.first);

    expect(
      tracksForArtist(catalog, artist).map((Track t) => t.id),
      <String>['blue-1', 'blue-2', 'green-1', 'green-2'],
    );
  });
}
