import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'linthra_core.dart';
import 'linthra_core_ffi.dart';

/// An edit to the playback queue, numbered as the Rust core's edit codes
/// (native/linthra_core/src/ffi/queue.rs).
enum QueueEditOp {
  insertNext,
  append,
  removeUpNextAt,
  reorderUpNext,
  removeWhere,
  shuffle,
  unshuffle,
}

/// Where an entry of an edited queue came from.
enum QueueSourceKind {
  /// The entry at this position in the queue's play order.
  track,

  /// The entry at this position in the order before shuffle.
  original,

  /// The added track at this position.
  added,
}

typedef QueueSource = ({QueueSourceKind kind, int index});

/// An edited queue, on entry ids: [QueueEditAnswer.edit] is null when the
/// edit left the queue alone.
typedef QueueEditResult = ({
  List<int> ids,
  List<QueueSource> sources,
  int current,
  List<int>? originalIds,
  List<QueueSource>? originalSources,
});

typedef QueueEditAnswer = ({QueueEditResult? edit});

/// The playback queue's moves and edits in the Rust core
/// (native/linthra_core/src/queue_moves.rs and queue_edits.rs).
///
/// `PlaybackQueue` calls this and falls back to its Dart rules without the
/// Rust core. Each method returns null when there is no Rust core, or when the
/// Rust side refused its input.
abstract final class NativeQueue {
  /// The current position after [move] (a `QueueMove.index`), as a record so
  /// that a null position (the move does nothing) is told apart from no answer.
  static ({int? target})? move(int length, int current, int move, int index) {
    if (!LinthraCore.isAvailable) return null;
    final int target = linthraQueueMove(length, current, move, index);
    if (target == LinthraQueueMove.invalid) return null;
    return (target: target == LinthraQueueMove.none ? null : target);
  }

  static QueueEditAnswer? edit(
    QueueEditOp op, {
    required List<int> ids,
    required int current,
    required List<int>? originalIds,
    int a = 0,
    int b = 0,
    int seed = 0,
    List<bool>? removed,
    List<bool>? removedOriginal,
  }) {
    if (!LinthraCore.isAvailable) return null;
    final List<int> original = originalIds ?? const <int>[];
    return using((Arena arena) {
      final Pointer<Int64> idsPtr = arena<Int64>(ids.length + 1);
      for (int i = 0; i < ids.length; i++) {
        idsPtr[i] = ids[i];
      }
      final Pointer<Int64> originalPtr = arena<Int64>(original.length + 1);
      for (int i = 0; i < original.length; i++) {
        originalPtr[i] = original[i];
      }
      final Pointer<Uint8> removedPtr = arena<Uint8>(ids.length + 1);
      final Pointer<Uint8> removedOriginalPtr =
          arena<Uint8>(original.length + 1);
      for (int i = 0; i < ids.length; i++) {
        removedPtr[i] = (removed != null && removed[i]) ? 1 : 0;
      }
      for (int i = 0; i < original.length; i++) {
        removedOriginalPtr[i] =
            (removedOriginal != null && removedOriginal[i]) ? 1 : 0;
      }
      final Pointer<LinthraQueueEditResult> result = linthraQueueEdit(
        op.index,
        a,
        b,
        seed,
        idsPtr,
        ids.length,
        current,
        originalIds != null,
        originalPtr,
        original.length,
        removedPtr,
        removedOriginalPtr,
      );
      if (result == nullptr) return null;
      try {
        if (!linthraQueueEditChanged(result)) return (edit: null);
        final int length = linthraQueueEditLen(result);
        final bool shuffled = linthraQueueEditHasOriginal(result);
        final int originalLength = linthraQueueEditOriginalLen(result);
        return (
          edit: (
            ids: _ints(linthraQueueEditIds(result), length),
            sources: _sources(linthraQueueEditSources(result), length),
            current: linthraQueueEditCurrent(result),
            originalIds: shuffled
                ? _ints(linthraQueueEditOriginalIds(result), originalLength)
                : null,
            originalSources: shuffled
                ? _sources(
                    linthraQueueEditOriginalSources(result),
                    originalLength,
                  )
                : null,
          ),
        );
      } finally {
        linthraQueueEditFree(result);
      }
    });
  }

  static List<int> _ints(Pointer<Int64> values, int length) =>
      length == 0 ? <int>[] : List<int>.of(values.asTypedList(length));

  static List<QueueSource> _sources(Pointer<Int64> values, int length) =>
      <QueueSource>[
        for (int i = 0; i < length; i++)
          (
            kind: QueueSourceKind.values[values[i] >> 32],
            index: values[i] & 0xFFFFFFFF,
          ),
      ];
}
