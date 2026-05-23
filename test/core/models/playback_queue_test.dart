import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon/core/models/playback_queue.dart';
import 'package:halcyon/core/models/track.dart';

Track _track(String id) => Track(id: id, title: 'Song $id', uri: '/$id.mp3');

void main() {
  group('PlaybackQueue', () {
    test('empty queue has no current track and no next', () {
      const queue = PlaybackQueue.empty;

      expect(queue.current, isNull);
      expect(queue.isEmpty, isTrue);
      expect(queue.hasNext, isFalse);
      expect(queue.upNext, isEmpty);
    });

    test('of() starts at the given index and queues the rest as up next', () {
      final queue = PlaybackQueue.of(
        [_track('a'), _track('b'), _track('c')],
        startIndex: 1,
      );

      expect(queue.current, _track('b'));
      expect(queue.upNext, [_track('c')]);
      expect(queue.hasNext, isTrue);
    });

    test('of() clamps an out-of-range start index', () {
      final queue = PlaybackQueue.of([_track('a'), _track('b')], startIndex: 9);

      expect(queue.current, _track('b'));
      expect(queue.hasNext, isFalse);
    });

    test('of() with an empty list yields the empty queue', () {
      expect(PlaybackQueue.of(const []), PlaybackQueue.empty);
    });

    test('next() advances the current track', () {
      final queue = PlaybackQueue.of([_track('a'), _track('b'), _track('c')]);

      final advanced = queue.next();

      expect(advanced.current, _track('b'));
      expect(advanced.upNext, [_track('c')]);
    });

    test('next() at the end returns the same queue', () {
      final queue = PlaybackQueue.of([_track('a')]);

      expect(queue.next(), same(queue));
    });

    test('enqueueNext() inserts right after the current track', () {
      final queue = PlaybackQueue.of([_track('a'), _track('c')]);

      final updated = queue.enqueueNext(_track('b'));

      expect(updated.current, _track('a'));
      expect(updated.upNext, [_track('b'), _track('c')]);
    });

    test('enqueueNext() on an empty queue makes the track current', () {
      final updated = PlaybackQueue.empty.enqueueNext(_track('a'));

      expect(updated.current, _track('a'));
      expect(updated.hasNext, isFalse);
    });

    test('cleared() keeps the current track and drops up next', () {
      final queue = PlaybackQueue.of([_track('a'), _track('b'), _track('c')]);

      final cleared = queue.cleared();

      expect(cleared.current, _track('a'));
      expect(cleared.hasNext, isFalse);
      expect(cleared.upNext, isEmpty);
    });

    test('cleared() on an empty queue stays empty', () {
      expect(PlaybackQueue.empty.cleared(), PlaybackQueue.empty);
    });

    test('value equality compares tracks and current index', () {
      final a = PlaybackQueue.of([_track('a'), _track('b')]);
      final b = PlaybackQueue.of([_track('a'), _track('b')]);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(b.next()));
    });
  });
}
