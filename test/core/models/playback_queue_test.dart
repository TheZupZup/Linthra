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

    test('play next while shuffled is still next once shuffle is off', () {
      // Before, the track was appended to the pre-shuffle order, so turning
      // shuffle off moved it behind everything else.
      final queue = PlaybackQueue.of(
        [_track('a'), _track('b'), _track('c'), _track('d')],
        startIndex: 1,
      ).shuffled(Random(4)).enqueueNext(_track('z'));

      final PlaybackQueue unshuffled = queue.unshuffled();

      expect(unshuffled.current, _track('b'));
      expect(unshuffled.tracks, [
        _track('a'),
        _track('b'),
        _track('z'),
        _track('c'),
        _track('d'),
      ]);
    });

    test('a set played next while shuffled keeps its place after shuffle off',
        () {
      final queue = PlaybackQueue.of(
        [_track('a'), _track('b'), _track('c')],
        startIndex: 1,
      ).shuffled(Random(5)).enqueueAllNext([_track('x'), _track('y')]);

      expect(queue.unshuffled().tracks, [
        _track('a'),
        _track('b'),
        _track('x'),
        _track('y'),
        _track('c'),
      ]);
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

    test('repeated reorderUpNext() calls keep the queue whole', () {
      // A drag-and-drop session is many small moves, each one landing on the
      // queue the previous one produced. Walking a track down the list and
      // back up again must return the same set of tracks in a sane order —
      // never a lost, duplicated, or half-moved entry — with the playing track
      // where it started.
      PlaybackQueue queue = PlaybackQueue.of(
        [_track('a'), _track('b'), _track('c'), _track('d'), _track('e')],
      );

      for (int i = 0; i < 3; i++) {
        queue = queue.reorderUpNext(i, i + 1);
      }
      expect(
          queue.upNext, [_track('c'), _track('d'), _track('e'), _track('b')]);

      for (int i = 3; i > 0; i--) {
        queue = queue.reorderUpNext(i, i - 1);
      }

      expect(queue.current, _track('a'));
      expect(
          queue.upNext, [_track('b'), _track('c'), _track('d'), _track('e')]);
      expect(queue.currentIndex, 0);
    });

    test('reorderUpNext() while shuffled leaves the original order alone', () {
      final queue = PlaybackQueue.of(
        [_track('a'), _track('b'), _track('c'), _track('d')],
      ).shuffled(Random(3));
      final List<Track> before = List<Track>.of(queue.originalOrder!);

      // Reordering the shuffled (effective) order is a change to what plays
      // next, not to the order shuffle will be undone back to.
      final updated = queue.reorderUpNext(0, 2);

      expect(updated.isShuffled, isTrue);
      expect(updated.originalOrder, before);
      expect(updated.current, queue.current);
      expect(updated.unshuffled().tracks, before);
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

  group('PlaybackQueue batched inserts (a whole collection at once)', () {
    test('enqueueAllNext() keeps the set in the order it was handed over', () {
      final queue = PlaybackQueue.of([_track('a'), _track('b')]);

      final updated = queue.enqueueAllNext([_track('x'), _track('y')]);

      // Inserting one at a time would land each at the same slot and queue the
      // set backwards; one insert keeps it front to back.
      expect(updated.current, _track('a'));
      expect(updated.upNext, [_track('x'), _track('y'), _track('b')]);
    });

    test('enqueueAllNext() keeps what was already upcoming behind it', () {
      final queue = PlaybackQueue.of(
        [_track('a'), _track('b'), _track('c')],
      );

      final updated = queue.enqueueAllNext([_track('x')]);

      expect(updated.upNext, [_track('x'), _track('b'), _track('c')]);
      expect(updated.tracks, hasLength(4));
    });

    test('enqueueAllNext() on an empty queue starts the set at its first track',
        () {
      final updated =
          PlaybackQueue.empty.enqueueAllNext([_track('a'), _track('b')]);

      expect(updated.current, _track('a'));
      expect(updated.upNext, [_track('b')]);
    });

    test('enqueueAllNext() with nothing to insert leaves the queue alone', () {
      final queue = PlaybackQueue.of([_track('a')]);

      expect(queue.enqueueAllNext(const []), same(queue));
      expect(PlaybackQueue.empty.enqueueAllNext(const []),
          same(PlaybackQueue.empty));
    });

    test('appendedAll() adds the set to the end, in order', () {
      final queue = PlaybackQueue.of([_track('a'), _track('b')]);

      final updated = queue.appendedAll([_track('x'), _track('y')]);

      expect(updated.current, _track('a'));
      expect(updated.upNext, [_track('b'), _track('x'), _track('y')]);
    });

    test('appendedAll() on an empty queue starts the set', () {
      final updated =
          PlaybackQueue.empty.appendedAll([_track('a'), _track('b')]);

      expect(updated.current, _track('a'));
      expect(updated.upNext, [_track('b')]);
    });

    test('appendedAll() with nothing to add leaves the queue alone', () {
      final queue = PlaybackQueue.of([_track('a')]);

      expect(queue.appendedAll(const []), same(queue));
    });

    test('both carry the set into originalOrder, so unshuffle keeps it', () {
      final shuffled =
          PlaybackQueue.of([_track('a'), _track('b')]).shuffled(Random(3));

      final next = shuffled.enqueueAllNext([_track('x'), _track('y')]);
      final appended = shuffled.appendedAll([_track('x'), _track('y')]);

      expect(next.unshuffled().tracks, containsAll([_track('x'), _track('y')]));
      expect(appended.unshuffled().tracks,
          containsAll([_track('x'), _track('y')]));
    });

    test('a set inserted next is one transition, not one per track', () {
      final queue = PlaybackQueue.of([_track('a')]);
      final set = [_track('x'), _track('y'), _track('z')];

      // Each track appears exactly once, wherever it landed: a batched insert
      // cannot double-add an entry the way a retried per-track loop could.
      final inserted = queue.enqueueAllNext(set);
      for (final Track track in set) {
        expect(
          inserted.tracks.where((Track t) => t.uri == track.uri),
          hasLength(1),
        );
      }
      expect(inserted.tracks, hasLength(4));
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

  group('replaceCurrent (runtime source fallback)', () {
    test('swaps the current track in place, keeping position and queue', () {
      final queue = PlaybackQueue.of(
        [_track('a'), _track('b'), _track('c')],
        startIndex: 1,
      );

      final replaced = queue.replaceCurrent(_track('B'));

      expect(replaced.current, _track('B'));
      expect(replaced.currentIndex, 1);
      expect(replaced.history, [_track('a')]);
      expect(replaced.upNext, [_track('c')]);
    });

    test('is a no-op on an empty queue', () {
      expect(
        PlaybackQueue.empty.replaceCurrent(_track('a')),
        PlaybackQueue.empty,
      );
    });

    test('is a no-op when replacing the current with an equal track', () {
      final queue = PlaybackQueue.of([_track('a')]);
      expect(identical(queue.replaceCurrent(_track('a')), queue), isTrue);
    });

    test('swaps to another provider copy that shares the bare id (fallback)',
        () {
      // jellyfin:101 falling back to subsonic:101 — same bare id, different uri.
      // The swap must take effect (it previously no-op'd via Track == on id), so
      // `current` reflects the copy that actually started.
      const jelly = Track(id: '101', title: 'Hello', uri: 'jellyfin:101');
      const sub = Track(id: '101', title: 'Hello', uri: 'subsonic:101');
      final queue = PlaybackQueue.of(<Track>[jelly]);

      final replaced = queue.replaceCurrent(sub);

      expect(identical(replaced, queue), isFalse);
      expect(replaced.current!.uri, 'subsonic:101');
    });

    test('a later unshuffle keeps the replaced copy, not the original', () {
      final queue = PlaybackQueue.of([_track('a'), _track('b'), _track('c')])
          .shuffled(Random(1));
      // shuffled keeps the current track ('a') at the front.
      final replaced = queue.replaceCurrent(_track('A'));

      final restored = replaced.unshuffled();

      final ids = restored.tracks.map((Track t) => t.id);
      expect(ids, contains('A'));
      expect(ids, isNot(contains('a')));
      expect(restored.current, _track('A'));
    });
  });

  group('provider-aware identity (two rows share a bare id across providers)',
      () {
    const jelly = Track(id: '101', title: 'Alpha', uri: 'jellyfin:101');
    const sub = Track(id: '101', title: 'Beta', uri: 'subsonic:101');

    test('unshuffle keeps the current copy, not the first row sharing the id',
        () {
      // Shuffled state: the subsonic copy is current; pre-shuffle order had the
      // jellyfin copy first. indexOf-by-id would jump current to jellyfin.
      const shuffled = PlaybackQueue(
        tracks: <Track>[sub, jelly],
        currentIndex: 0,
        originalOrder: <Track>[jelly, sub],
      );

      final restored = shuffled.unshuffled();

      expect(restored.current!.uri, 'subsonic:101');
      expect(restored.tracks.map((Track t) => t.uri),
          <String>['jellyfin:101', 'subsonic:101']);
    });

    test('removeUpNextAt drops the right copy from originalOrder by uri', () {
      // current = jelly, upNext = [sub], same originalOrder. Removing the upNext
      // entry must drop the subsonic copy — not the jellyfin one that shares its
      // bare id (which `List.remove` via Track == would have hit first).
      const q = PlaybackQueue(
        tracks: <Track>[jelly, sub],
        currentIndex: 0,
        originalOrder: <Track>[jelly, sub],
      );

      final result = q.removeUpNextAt(0);

      expect(result.upNext, isEmpty);
      expect(result.unshuffled().tracks.map((Track t) => t.uri),
          <String>['jellyfin:101']);
    });
  });

  group('the same song queued twice (#744)', () {
    final Track a = _track('a');
    final Track b = _track('b');
    final Track c = _track('c');

    test('shuffle off keeps the copy that was playing', () {
      for (int seed = 0; seed < 20; seed++) {
        final PlaybackQueue queue =
            PlaybackQueue.of(<Track>[a, b, a, c], startIndex: 2)
                .shuffled(Random(seed))
                .unshuffled();

        expect(queue.currentIndex, 2, reason: 'seed $seed');
        expect(queue.history, <Track>[a, b], reason: 'seed $seed');
        expect(queue.upNext, <Track>[c], reason: 'seed $seed');
      }
    });

    test('play next goes after the playing copy, not the first one', () {
      final PlaybackQueue queue =
          PlaybackQueue.of(<Track>[a, b, a, c], startIndex: 2)
              .shuffled(Random(1))
              .enqueueNext(_track('z'))
              .unshuffled();

      expect(queue.tracks, <Track>[a, b, a, _track('z'), c]);
      expect(queue.currentIndex, 2);
    });

    test('removing a played-next copy of the current song takes that copy', () {
      final Track y = _track('y');
      final PlaybackQueue shuffled =
          PlaybackQueue.of(<Track>[a, b, c, _track('d')], startIndex: 1)
              .shuffled(Random(3));
      // Play next on the song that's playing, then on another one: up next
      // starts [y, b, ...].
      final PlaybackQueue queued = shuffled.enqueueNext(b).enqueueNext(y);
      expect(queued.upNext.take(2), <Track>[y, b]);

      final PlaybackQueue off = queued.removeUpNextAt(1).unshuffled();

      // The current entry keeps its own place, and y, which hasn't played,
      // is still up next.
      expect(off.history, <Track>[a]);
      expect(off.current, b);
      expect(off.upNext, <Track>[y, c, _track('d')]);
    });

    test('a source fallback swaps the playing copy, not the first one', () {
      const Track other = Track(id: 'a', title: 'Song a', uri: 'subsonic:a');
      final PlaybackQueue queue =
          PlaybackQueue.of(<Track>[a, b, a, c], startIndex: 2)
              .shuffled(Random(2))
              .replaceCurrent(other)
              .unshuffled();

      expect(queue.tracks, <Track>[a, b, other, c]);
      expect(queue.currentIndex, 2);
    });

    test('moving to an entry keeps the copies apart', () {
      // [a, b₂, b₀, c]: the copy of b from the end of the original order
      // comes first.
      final PlaybackQueue shuffled =
          PlaybackQueue.of(<Track>[b, a, b, c], startIndex: 1)
              .shuffled(Random(13));

      final PlaybackQueue moved = shuffled.movedTo(1).unshuffled();

      expect(moved.currentIndex, 2);
      expect(moved.upNext, <Track>[c]);
      expect(shuffled.movedTo(9), same(shuffled));
      expect(shuffled.movedTo(-1), same(shuffled));
    });

    test('queues that only differ in which copy is which are not equal', () {
      // [b, a, a] shuffled: up next is either copy of a first. The queues
      // read the same, but shuffle off after Next lands somewhere else.
      final PlaybackQueue start = PlaybackQueue.of(<Track>[b, a, a]);
      final Map<int, PlaybackQueue> byLanding = <int, PlaybackQueue>{};
      for (int seed = 0; seed < 20; seed++) {
        final PlaybackQueue shuffled = start.shuffled(Random(seed));
        byLanding[shuffled.next().unshuffled().currentIndex] = shuffled;
      }
      expect(byLanding.keys, unorderedEquals(<int>[1, 2]));

      final PlaybackQueue first = byLanding[1]!;
      final PlaybackQueue second = byLanding[2]!;
      expect(first.tracks, second.tracks);
      expect(first.originalOrder, second.originalOrder);
      expect(first, isNot(second));
    });

    test('a queue built with an original order pairs copies in turn', () {
      // Built from saved fields, with no ids: the first copy of a in tracks
      // stands for the first copy in the original order.
      final PlaybackQueue queue = PlaybackQueue(
        tracks: <Track>[a, c, a, b],
        currentIndex: 2,
        originalOrder: <Track>[a, b, a, c],
      );

      expect(queue.unshuffled().currentIndex, 2);
      expect(queue.removeUpNextAt(0).unshuffled().tracks, <Track>[a, a, c]);
    });

    test('every edit does what it does when each entry is a different song',
        () {
      // The same edits run twice: once where every entry is its own song, and
      // once where the entries are only three songs, queued again and again.
      // The queue has to do the same thing either way.
      Track entry(int n) => Track(id: 'e$n', title: 'e$n', uri: '/e$n.mp3');
      Track song(Track entry) =>
          _track('s${int.parse(entry.id.substring(1)) % 3}');
      List<Track> songs(List<Track> entries) => <Track>[
            for (final Track t in entries) song(t),
          ];

      for (int seed = 0; seed < 300; seed++) {
        final Random pick = Random(seed);
        int made = 0;
        Track fresh() => entry(made++);
        PlaybackQueue distinct = PlaybackQueue.of(
          <Track>[for (int i = 0; i < 6; i++) fresh()],
          startIndex: pick.nextInt(6),
        );
        PlaybackQueue repeated = PlaybackQueue.of(
          songs(distinct.tracks),
          startIndex: distinct.currentIndex,
        );
        final List<String> steps = <String>[];
        for (int step = 0; step < 40; step++) {
          final int up = distinct.upNext.length;
          final int back = distinct.history.length;
          switch (pick.nextInt(15)) {
            case 0:
              steps.add('next');
              distinct = distinct.next();
              repeated = repeated.next();
            case 1:
              steps.add('previous');
              distinct = distinct.previous();
              repeated = repeated.previous();
            case 2:
              steps.add('enqueueNext');
              final Track t = fresh();
              distinct = distinct.enqueueNext(t);
              repeated = repeated.enqueueNext(song(t));
            case 3:
              steps.add('appended');
              final Track t = fresh();
              distinct = distinct.appended(t);
              repeated = repeated.appended(song(t));
            case 4:
              steps.add('enqueueAllNext');
              final List<Track> set = <Track>[fresh(), fresh()];
              distinct = distinct.enqueueAllNext(set);
              repeated = repeated.enqueueAllNext(songs(set));
            case 5:
              steps.add('appendedAll');
              final List<Track> set = <Track>[fresh(), fresh()];
              distinct = distinct.appendedAll(set);
              repeated = repeated.appendedAll(songs(set));
            case 6:
              final int i = pick.nextInt(up + 1);
              steps.add('removeUpNextAt($i)');
              distinct = distinct.removeUpNextAt(i);
              repeated = repeated.removeUpNextAt(i);
            case 7:
              final int from = pick.nextInt(up + 1);
              final int to = pick.nextInt(up + 1);
              steps.add('reorderUpNext($from, $to)');
              distinct = distinct.reorderUpNext(from, to);
              repeated = repeated.reorderUpNext(from, to);
            case 8:
              final int i = pick.nextInt(up + 1);
              steps.add('jumpToUpNext($i)');
              distinct = distinct.jumpToUpNext(i);
              repeated = repeated.jumpToUpNext(i);
            case 9:
              final int i = pick.nextInt(back + 1);
              steps.add('jumpToHistory($i)');
              distinct = distinct.jumpToHistory(i);
              repeated = repeated.jumpToHistory(i);
            case 10:
            case 11:
              final int order = pick.nextInt(1 << 30);
              steps.add('shuffled($order)');
              distinct = distinct.shuffled(Random(order));
              repeated = repeated.shuffled(Random(order));
            case 12:
              steps.add('unshuffled');
              distinct = distinct.unshuffled();
              repeated = repeated.unshuffled();
            case 13:
              steps.add('replaceCurrent');
              final Track t = fresh();
              distinct = distinct.replaceCurrent(t);
              repeated = repeated.replaceCurrent(song(t));
            case 14:
              final int i = pick.nextInt(distinct.tracks.length + 1);
              steps.add('movedTo($i)');
              distinct = distinct.movedTo(i);
              repeated = repeated.movedTo(i);
          }
          final String reason = 'seed $seed after ${steps.join(', ')}';
          expect(repeated.tracks, songs(distinct.tracks), reason: reason);
          expect(repeated.currentIndex, distinct.currentIndex, reason: reason);
          expect(
            repeated.originalOrder,
            distinct.originalOrder == null
                ? null
                : songs(distinct.originalOrder!),
            reason: reason,
          );
        }
      }
    });
  });
}
