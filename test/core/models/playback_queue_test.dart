import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_queue.dart';
import 'package:linthra/core/models/track.dart';

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

    test('previous() steps back to the prior track', () {
      final queue = PlaybackQueue.of(
        [_track('a'), _track('b'), _track('c')],
        startIndex: 2,
      );

      final stepped = queue.previous();

      expect(stepped.current, _track('b'));
      expect(stepped.hasPrevious, isTrue);
      expect(stepped.upNext, [_track('c')]);
    });

    test('previous() at the start returns the same queue', () {
      final queue = PlaybackQueue.of([_track('a'), _track('b')]);

      expect(queue.hasPrevious, isFalse);
      expect(queue.previous(), same(queue));
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

    test('restarted() wraps back to the first track keeping the queue', () {
      final queue = PlaybackQueue.of(
        [_track('a'), _track('b'), _track('c')],
        startIndex: 2,
      );

      final restarted = queue.restarted();

      expect(restarted.current, _track('a'));
      expect(restarted.upNext, [_track('b'), _track('c')]);
      expect(restarted.hasPrevious, isFalse);
    });

    test('restarted() on an empty queue stays empty', () {
      expect(PlaybackQueue.empty.restarted(), PlaybackQueue.empty);
    });
  });

  group('PlaybackQueue advanced editing', () {
    test('history exposes the tracks played before the current one', () {
      final queue = PlaybackQueue.of(
        [_track('a'), _track('b'), _track('c')],
        startIndex: 2,
      );

      expect(queue.history, [_track('a'), _track('b')]);
    });

    test('history is empty at the start of the queue', () {
      final queue = PlaybackQueue.of([_track('a'), _track('b')]);

      expect(queue.history, isEmpty);
    });

    test('appended() adds a track to the end, keeping the current one', () {
      final queue = PlaybackQueue.of([_track('a'), _track('b')]);

      final updated = queue.appended(_track('c'));

      expect(updated.current, _track('a'));
      expect(updated.upNext, [_track('b'), _track('c')]);
    });

    test('appended() on an empty queue makes the track current', () {
      final updated = PlaybackQueue.empty.appended(_track('a'));

      expect(updated.current, _track('a'));
      expect(updated.hasNext, isFalse);
    });

    test('appended() while shuffled survives a later unshuffle', () {
      final queue = PlaybackQueue.of([_track('a'), _track('b')])
          .shuffled(Random(2))
          .appended(_track('z'));

      expect(queue.unshuffled().tracks, contains(_track('z')));
    });

    test('removeUpNextAt() drops only that upcoming entry', () {
      final queue = PlaybackQueue.of(
        [_track('a'), _track('b'), _track('c'), _track('d')],
      );

      // up next is [b, c, d]; remove index 1 (c).
      final updated = queue.removeUpNextAt(1);

      expect(updated.current, _track('a'));
      expect(updated.upNext, [_track('b'), _track('d')]);
    });

    test('removeUpNextAt() leaves the current track and history untouched', () {
      final queue = PlaybackQueue.of(
        [_track('a'), _track('b'), _track('c')],
        startIndex: 1,
      );

      // current is b, history [a], up next [c]; remove the only up-next entry.
      final updated = queue.removeUpNextAt(0);

      expect(updated.current, _track('b'));
      expect(updated.history, [_track('a')]);
      expect(updated.upNext, isEmpty);
    });

    test('removeUpNextAt() out of range is a no-op', () {
      final queue = PlaybackQueue.of([_track('a'), _track('b')]);

      expect(queue.removeUpNextAt(5), same(queue));
      expect(queue.removeUpNextAt(-1), same(queue));
    });

    test('removeUpNextAt() drops the track from the shuffle original too', () {
      final queue = PlaybackQueue.of([_track('a'), _track('b'), _track('c')])
          .shuffled(Random(4));
      // Remove the first up-next track in the shuffled order.
      final removed = queue.upNext.first;

      final updated = queue.removeUpNextAt(0).unshuffled();

      // Unshuffling must not resurrect the removed track.
      expect(updated.tracks, isNot(contains(removed)));
    });

    test('reorderUpNext() moves an upcoming track, keeping current playing',
        () {
      final queue = PlaybackQueue.of(
        [_track('a'), _track('b'), _track('c'), _track('d')],
      );

      // up next is [b, c, d]; move b (0) to the end (2).
      final updated = queue.reorderUpNext(0, 2);

      expect(updated.current, _track('a'));
      expect(updated.upNext, [_track('c'), _track('d'), _track('b')]);
    });

    test('reorderUpNext() is a no-op for equal or out-of-range indices', () {
      final queue = PlaybackQueue.of([_track('a'), _track('b'), _track('c')]);

      expect(queue.reorderUpNext(0, 0), same(queue));
      expect(queue.reorderUpNext(0, 9), same(queue));
      expect(queue.reorderUpNext(-1, 0), same(queue));
    });

    test('jumpToUpNext() makes an upcoming track current', () {
      final queue = PlaybackQueue.of(
        [_track('a'), _track('b'), _track('c'), _track('d')],
      );

      // up next is [b, c, d]; jump to c (index 1).
      final updated = queue.jumpToUpNext(1);

      expect(updated.current, _track('c'));
      expect(updated.history, [_track('a'), _track('b')]);
      expect(updated.upNext, [_track('d')]);
    });

    test('jumpToUpNext() out of range is a no-op', () {
      final queue = PlaybackQueue.of([_track('a'), _track('b')]);

      expect(queue.jumpToUpNext(5), same(queue));
    });

    test('jumpToHistory() steps back to a played track', () {
      final queue = PlaybackQueue.of(
        [_track('a'), _track('b'), _track('c')],
        startIndex: 2,
      );

      // history is [a, b]; jump back to a (index 0).
      final updated = queue.jumpToHistory(0);

      expect(updated.current, _track('a'));
      expect(updated.upNext, [_track('b'), _track('c')]);
      expect(updated.history, isEmpty);
    });

    test('jumpToHistory() out of range is a no-op', () {
      final queue = PlaybackQueue.of([_track('a'), _track('b')], startIndex: 1);

      expect(queue.jumpToHistory(5), same(queue));
    });
  });

  group('PlaybackQueue shuffle', () {
    test('shuffled() keeps the current track current and shuffles the rest',
        () {
      final queue = PlaybackQueue.of(
        [_track('a'), _track('b'), _track('c'), _track('d')],
        startIndex: 1,
      );

      // A fixed seed keeps this deterministic across runs.
      final shuffled = queue.shuffled(Random(7));

      // The track that was playing keeps playing and moves to the front.
      expect(shuffled.current, _track('b'));
      expect(shuffled.currentIndex, 0);
      expect(shuffled.isShuffled, isTrue);
      expect(shuffled.hasPrevious, isFalse);
      // Every track is preserved, just reordered.
      expect(
        shuffled.tracks.toSet(),
        {_track('a'), _track('b'), _track('c'), _track('d')},
      );
      expect(shuffled.tracks.length, 4);
    });

    test('shuffled() on an empty queue is a no-op', () {
      expect(PlaybackQueue.empty.shuffled(Random(1)), PlaybackQueue.empty);
      expect(PlaybackQueue.empty.isShuffled, isFalse);
    });

    test('unshuffled() restores the original order, keeping the current track',
        () {
      final original = [_track('a'), _track('b'), _track('c'), _track('d')];
      final queue = PlaybackQueue.of(original, startIndex: 2);

      final restored = queue.shuffled(Random(3)).unshuffled();

      expect(restored.isShuffled, isFalse);
      expect(restored.tracks, original);
      // 'c' was current before shuffling and is still current after restoring.
      expect(restored.current, _track('c'));
      expect(restored.currentIndex, 2);
    });

    test('unshuffled() on a non-shuffled queue returns the same queue', () {
      final queue = PlaybackQueue.of([_track('a'), _track('b')]);

      expect(queue.unshuffled(), same(queue));
    });

    test('next()/previous() preserve the shuffled order', () {
      final queue = PlaybackQueue.of(
        [_track('a'), _track('b'), _track('c')],
      ).shuffled(Random(5));

      final advanced = queue.next();
      expect(advanced.isShuffled, isTrue);
      expect(advanced.tracks, queue.tracks);

      final back = advanced.previous();
      expect(back.isShuffled, isTrue);
      expect(back.current, queue.current);
    });

    test('enqueueNext() while shuffled survives a later unshuffle', () {
      final queue = PlaybackQueue.of([_track('a'), _track('b')])
          .shuffled(Random(2))
          .enqueueNext(_track('z'));

      final restored = queue.unshuffled();

      // The queued track is still present once the original order is restored.
      expect(restored.tracks, contains(_track('z')));
    });

    test('equality distinguishes a shuffled queue from a plain one', () {
      final plain = PlaybackQueue.of([_track('a'), _track('b')]);
      final shuffled = plain.shuffled(Random(1));

      // A single-front-track + remembered original order is not the plain queue.
      expect(shuffled, isNot(plain));
      expect(shuffled.isShuffled, isTrue);
    });
  });
}
