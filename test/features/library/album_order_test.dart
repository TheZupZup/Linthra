import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/features/library/album_order.dart';

void main() {
  test('sorts albums from A to Z', () {
    final albums = [
      const Album(id: '1', title: 'Zebra'),
      const Album(id: '2', title: 'Alpha'),
    ];

    final result = sortAlbumsByTitle(albums);

    expect(result[0].title, 'Alpha');
    expect(result[1].title, 'Zebra');
    expect(albums[0].title, 'Zebra');
  });

  test('sorts albums from Z to A', () {
    final albums = [
      const Album(id: '1', title: 'Alpha'),
      const Album(id: '2', title: 'Zebra'),
    ];

    final result = sortAlbumsByTitle(albums, descending: true);

    expect(result[0].title, 'Zebra');
    expect(result[1].title, 'Alpha');
  });
}
