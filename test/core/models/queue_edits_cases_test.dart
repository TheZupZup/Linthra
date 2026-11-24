import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_queue.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/native/linthra_core.dart';

/// Replays `test/fixtures/queue_edits_cases.txt`, the cases the Rust edits
/// (native/linthra_core/src/queue_edits_cases_test.rs) replay too.
///
/// Each id in the file is a track whose uri is `t<id>`, so the queue built
/// here from tracks is the one the file describes, and a result is checked by
/// the tracks it holds.
Track _track(int id) => Track(id: '$id', title: 'Song $id', uri: 't$id');

/// Hands [PlaybackQueue.shuffled] the seed a case names: the high 32 bits,
/// then the low 32.
class _SeedRandom implements Random {
  _SeedRandom(BigInt seed)
      : _halves = <int>[
          (seed >> 32).toInt(),
          (seed & BigInt.from(0xFFFFFFFF)).toInt(),
        ];

  final List<int> _halves;
  int _next = 0;

  @override
  int nextInt(int max) => _halves[_next++];

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  double nextDouble() => throw UnimplementedError();
}

void main() {
  List<int> list(String field) => field == '.'
      ? <int>[]
      : <int>[for (final String id in field.split(',')) int.parse(id)];

  List<String> uris(List<Track> tracks) =>
      <String>[for (final Track t in tracks) t.uri];

  List<String> expectedUris(String field) =>
      <String>[for (final int id in list(field)) 't$id'];

  final List<String> lines = File('test/fixtures/queue_edits_cases.txt')
      .readAsLinesSync()
      .where((String line) => line.isNotEmpty && !line.startsWith('#'))
      .toList();

  tearDown(() => PlaybackQueue.useNativeCore = true);

  for (final bool useNative in <bool>[false, true]) {
    test(
      '${useNative ? 'Rust' : 'Dart'}: a queue edit gives what every shared '
      'case says',
      skip:
          useNative && !LinthraCore.isAvailable ? 'Rust core not built' : false,
      () {
        PlaybackQueue.useNativeCore = useNative;
        for (final String line in lines) {
          final List<String> f = line.split('\t');
          expect(f.length == 7 || f.length == 9, isTrue, reason: line);
          final List<int> ids = list(f[0]);
          final List<int>? original = f[2] == '-' ? null : list(f[2]);
          final PlaybackQueue queue = PlaybackQueue(
            tracks: <Track>[for (final int id in ids) _track(id)],
            currentIndex: int.parse(f[1]),
            originalOrder: original == null
                ? null
                : <Track>[for (final id in original) _track(id)],
          );
          // New entries take the ids after the highest one in use.
          final int first = <int>[...ids, ...?original]
                  .fold(-1, (int a, int b) => max(a, b)) +
              1;
          List<Track> added(String count) => <Track>[
                for (int i = 0; i < int.parse(count); i++) _track(first + i),
              ];
          final PlaybackQueue edited = switch (f[3]) {
            'insertNext' => queue.enqueueAllNext(added(f[4])),
            'append' => queue.appendedAll(added(f[4])),
            'removeUpNextAt' => queue.removeUpNextAt(int.parse(f[4])),
            'reorderUpNext' =>
              queue.reorderUpNext(int.parse(f[4]), int.parse(f[5])),
            'removeWhere' => queue.removedWhere(
                (Track t) => expectedUris(f[4]).contains(t.uri),
              ),
            'shuffle' => queue.shuffled(_SeedRandom(BigInt.parse(f[4]))),
            'unshuffle' => queue.unshuffled(),
            final String other => throw StateError('unknown op $other'),
          };
          if (f[6] == '-') {
            expect(identical(edited, queue), isTrue, reason: 'case "$line"');
            continue;
          }
          expect(uris(edited.tracks), expectedUris(f[6]), reason: line);
          expect(edited.currentIndex, int.parse(f[7]), reason: line);
          expect(
            edited.originalOrder == null ? null : uris(edited.originalOrder!),
            f[8] == '-' ? null : expectedUris(f[8]),
            reason: line,
          );
        }
        expect(lines.length, greaterThanOrEqualTo(34));
      },
    );
  }
}
