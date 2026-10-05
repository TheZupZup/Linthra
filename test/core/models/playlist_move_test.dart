import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playlist_move.dart';

void main() {
  group('playlistWithMove (#749)', () {
    test('with the order it was shown in, it is a plain index move', () {
      const List<String> order = <String>['a', 'b', 'c', 'd'];
      expect(
        playlistWithMove(order, shown: order, from: 0, to: 3),
        <String>['b', 'c', 'd', 'a'],
      );
      expect(
        playlistWithMove(order, shown: order, from: 3, to: 1),
        <String>['a', 'd', 'b', 'c'],
      );
    });

    test('a drag repeated from the old order moves the same song', () {
      // c went to the top; the rows still show a, b, c.
      expect(
        playlistWithMove(
          const <String>['c', 'a', 'b'],
          shown: const <String>['a', 'b', 'c'],
          from: 2,
          to: 0,
        ),
        <String>['c', 'a', 'b'],
      );
    });

    test('the song lands after the one it was dropped behind', () {
      // d went to the top; then, from the old rows, b is dropped after c.
      expect(
        playlistWithMove(
          const <String>['d', 'a', 'b', 'c'],
          shown: const <String>['a', 'b', 'c', 'd'],
          from: 1,
          to: 2,
        ),
        <String>['d', 'a', 'c', 'b'],
      );
    });

    test('songs the order left out stay where they are', () {
      expect(
        playlistWithMove(
          const <String>['a', 'x', 'b', 'c'],
          shown: const <String>['a', 'b', 'c'],
          from: 0,
          to: 1,
        ),
        <String>['x', 'b', 'a', 'c'],
      );
    });

    test('the copy of a doubled song that was dragged is the one moved', () {
      expect(
        playlistWithMove(
          const <String>['b', 'a', 'b'],
          shown: const <String>['b', 'a', 'b'],
          from: 2,
          to: 1,
        ),
        <String>['b', 'b', 'a'],
      );
    });

    test('the song after the drop anchors it once the one before is gone', () {
      expect(
        playlistWithMove(
          const <String>['b', 'c', 'd'],
          shown: const <String>['a', 'b', 'c', 'd'],
          from: 3,
          to: 1,
        ),
        <String>['d', 'b', 'c'],
      );
    });

    test('nothing to move when the song has left the playlist', () {
      expect(
        playlistWithMove(
          const <String>['a', 'b'],
          shown: const <String>['a', 'b', 'c'],
          from: 2,
          to: 0,
        ),
        isNull,
      );
      expect(
        playlistWithMove(
          const <String>['a', 'b'],
          shown: const <String>['a', 'b'],
          from: 5,
          to: 0,
        ),
        isNull,
      );
    });
  });
}
