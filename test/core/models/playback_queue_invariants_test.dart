// The queue stays whole whatever is done to it, in any order.
//
// PlaybackQueue keeps two orders while shuffled, the one playing and the one
// shuffle off goes back to, plus a pointer to the song playing now. The fuzz
// test next to it compares a queue of distinct songs with one of repeated
// songs, and leaves out removedWhere (an account's songs leaving the queue),
// cleared and restarted. Any of those leaving the pointer outside the list,
// or the two orders holding different songs, would make shuffle off restore
// songs that were removed, drop ones still queued, or play the wrong song.
//
// Seeded, so a failure names the seed and the steps that led to it.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_queue.dart';
import 'package:linthra/core/models/track.dart';

/// A small pool, from two providers, so songs repeat and a provider can go.
const List<Track> _pool = <Track>[
  Track(id: 'a', title: 'A', uri: 'jellyfin:a'),
  Track(id: 'b', title: 'B', uri: 'jellyfin:b'),
  Track(id: 'c', title: 'C', uri: 'jellyfin:c'),
  Track(id: '1', title: 'One', uri: 'subsonic:1'),
  Track(id: '2', title: 'Two', uri: 'subsonic:2'),
  Track(id: 'f', title: 'F', uri: 'file:///f.mp3'),
];

List<String> _uris(Iterable<Track> tracks) =>
    <String>[for (final Track t in tracks) t.uri];

/// The uris of [tracks] in a fixed order, to compare two lists as multisets.
List<String> _bag(Iterable<Track> tracks) => _uris(tracks)..sort();

/// What `removedWhere` promises for the current song: it stays when it isn't
/// picked; otherwise the first song left after it plays, or with none after
/// it, the last one left before it.
String? _currentAfterRemoving(PlaybackQueue q, bool Function(Track) test) {
  if (q.current == null) return null;
  if (!test(q.current!)) return q.current!.uri;
  for (int i = q.currentIndex + 1; i < q.tracks.length; i++) {
    if (!test(q.tracks[i])) return q.tracks[i].uri;
  }
  for (int i = q.currentIndex - 1; i >= 0; i--) {
    if (!test(q.tracks[i])) return q.tracks[i].uri;
  }
  return null;
}

void _expectWhole(PlaybackQueue q, String reason) {
  if (q.tracks.isEmpty) {
    expect(q.currentIndex, -1, reason: reason);
    expect(q.current, isNull, reason: reason);
    expect(q.isShuffled, isFalse, reason: reason);
    return;
  }
  expect(q.currentIndex, inInclusiveRange(0, q.tracks.length - 1),
      reason: reason);
  expect(q.history.length + 1 + q.upNext.length, q.tracks.length,
      reason: reason);
  final List<Track>? original = q.originalOrder;
  if (original != null) {
    // Shuffle off goes back to exactly the songs queued now.
    expect(_bag(original), _bag(q.tracks), reason: reason);
  }
  // Shuffle off keeps the song playing.
  expect(q.unshuffled().current?.uri, q.current?.uri, reason: reason);
}

void main() {
  test('every edit, in any order, leaves the queue whole', () {
    for (int seed = 0; seed < 400; seed++) {
      final Random pick = Random(seed);
      Track any() => _pool[pick.nextInt(_pool.length)];
      PlaybackQueue q = PlaybackQueue.of(
        <Track>[for (int i = 0; i < 5; i++) any()],
        startIndex: pick.nextInt(5),
      );
      final List<String> steps = <String>[];

      for (int step = 0; step < 60; step++) {
        final PlaybackQueue before = q;
        final String? playing = before.current?.uri;
        final int up = before.upNext.length;
        final int back = before.history.length;
        // Whether this step leaves the song playing where it is.
        bool keepsCurrent = false;
        String? expectedCurrent;

        switch (pick.nextInt(17)) {
          case 0:
            steps.add('next');
            q = q.next();
          case 1:
            steps.add('previous');
            q = q.previous();
          case 2:
            steps.add('restarted');
            q = q.restarted();
            expectedCurrent =
                before.tracks.isEmpty ? null : before.tracks[0].uri;
          case 3:
            final int i = pick.nextInt(before.tracks.length + 2) - 1;
            steps.add('movedTo($i)');
            q = q.movedTo(i);
            if (i >= 0 && i < before.tracks.length) {
              expectedCurrent = before.tracks[i].uri;
            } else {
              keepsCurrent = true;
            }
          case 4:
            final Track t = any();
            steps.add('enqueueNext(${t.uri})');
            q = q.enqueueNext(t);
            keepsCurrent = playing != null;
          case 5:
            final Track t = any();
            steps.add('appended(${t.uri})');
            q = q.appended(t);
            keepsCurrent = playing != null;
          case 6:
            // A set added to an empty queue is left out: whether it starts
            // shuffled is the controller's call there (#881), not the model's.
            if (before.isEmpty) continue;
            final List<Track> set = <Track>[any(), any(), any()];
            steps.add('enqueueAllNext(${_uris(set)})');
            q = q.enqueueAllNext(set);
            keepsCurrent = true;
          case 7:
            if (before.isEmpty) continue;
            final List<Track> set = <Track>[any(), any()];
            steps.add('appendedAll(${_uris(set)})');
            q = q.appendedAll(set);
            keepsCurrent = true;
          case 8:
            final int i = pick.nextInt(up + 1);
            steps.add('removeUpNextAt($i)');
            q = q.removeUpNextAt(i);
            keepsCurrent = true;
          case 9:
            final int from = pick.nextInt(up + 1);
            final int to = pick.nextInt(up + 1);
            steps.add('reorderUpNext($from, $to)');
            q = q.reorderUpNext(from, to);
            keepsCurrent = true;
          case 10:
            final int i = pick.nextInt(up + 1);
            steps.add('jumpToUpNext($i)');
            q = q.jumpToUpNext(i);
            if (i < up) expectedCurrent = before.upNext[i].uri;
          case 11:
            final int i = pick.nextInt(back + 1);
            steps.add('jumpToHistory($i)');
            q = q.jumpToHistory(i);
            if (i < back) expectedCurrent = before.history[i].uri;
          case 12:
            steps.add('cleared');
            q = q.cleared();
            keepsCurrent = true;
            if (playing != null) {
              expect(_uris(q.tracks), <String>[playing],
                  reason: 'seed $seed after ${steps.join(', ')}');
            }
          case 13:
            // Either one provider's songs go (an account signing out), or
            // every copy of one song.
            final bool byProvider = pick.nextBool();
            final String target = byProvider
                ? <String>['jellyfin:', 'subsonic:'][pick.nextInt(2)]
                : any().uri;
            bool test(Track t) =>
                byProvider ? t.uri.startsWith(target) : t.uri == target;
            steps.add('removedWhere($target)');
            q = q.removedWhere(test);
            expectedCurrent = _currentAfterRemoving(before, test);
            expect(q.tracks.where(test), isEmpty,
                reason: 'seed $seed after ${steps.join(', ')}');
            expect((q.originalOrder ?? const <Track>[]).where(test), isEmpty,
                reason: 'seed $seed after ${steps.join(', ')}');
            if (expectedCurrent == null) {
              expect(q.tracks, isEmpty,
                  reason: 'seed $seed after ${steps.join(', ')}');
            }
          case 14:
          case 15:
            final int order = pick.nextInt(1 << 30);
            steps.add('shuffled($order)');
            q = q.shuffled(Random(order));
            keepsCurrent = true;
          case 16:
            if (pick.nextBool()) {
              steps.add('unshuffled');
              q = q.unshuffled();
              keepsCurrent = true;
            } else {
              final Track t = any();
              steps.add('replaceCurrent(${t.uri})');
              q = q.replaceCurrent(t);
              if (playing != null) expectedCurrent = t.uri;
            }
        }

        final String reason = 'seed $seed after ${steps.join(', ')}';
        _expectWhole(q, reason);
        if (keepsCurrent) expect(q.current?.uri, playing, reason: reason);
        if (expectedCurrent != null) {
          expect(q.current?.uri, expectedCurrent, reason: reason);
        }
        // An emptied queue is sometimes edited as it is, sometimes refilled,
        // so the rest of the run still has songs to move around.
        if (q.isEmpty && pick.nextBool()) {
          steps.add('refilled');
          q = PlaybackQueue.of(<Track>[any(), any()]);
        }
      }
    }
  });

  group('the current song leaving a shuffled queue', () {
    bool isSubsonic(Track t) => t.uri.startsWith('subsonic:');

    test('shuffle off keeps the song that took its place', () {
      const List<Track> tracks = <Track>[
        Track(id: 'a', title: 'A', uri: 'jellyfin:a'),
        Track(id: '1', title: 'One', uri: 'subsonic:1'),
        Track(id: 'b', title: 'B', uri: 'jellyfin:b'),
        Track(id: '2', title: 'Two', uri: 'subsonic:2'),
        Track(id: 'c', title: 'C', uri: 'jellyfin:c'),
      ];
      for (int seed = 0; seed < 30; seed++) {
        // Playing the Navidrome song when that account signs out.
        final PlaybackQueue shuffled =
            PlaybackQueue.of(tracks, startIndex: 1).shuffled(Random(seed));
        final PlaybackQueue removed = shuffled.removedWhere(isSubsonic);
        final String? takesOver = removed.current?.uri;
        expect(takesOver, isNotNull, reason: 'seed $seed');

        final PlaybackQueue unshuffled = removed.unshuffled();

        expect(takesOver, isNot(startsWith('subsonic:')), reason: 'seed $seed');
        expect(unshuffled.current?.uri, takesOver, reason: 'seed $seed');
        expect(_uris(unshuffled.tracks),
            <String>['jellyfin:a', 'jellyfin:b', 'jellyfin:c'],
            reason: 'seed $seed');
        expect(
          unshuffled.currentIndex,
          _uris(unshuffled.tracks).indexOf(takesOver!),
          reason: 'seed $seed',
        );
        expect(unshuffled.isShuffled, isFalse, reason: 'seed $seed');
      }
    });
  });
}
