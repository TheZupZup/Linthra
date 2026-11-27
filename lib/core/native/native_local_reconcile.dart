import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../models/track.dart';
import 'linthra_core.dart';
import 'linthra_core_ffi.dart';

/// Works out moved and deleted local files in the Rust core
/// (native/linthra_core/src/local_reconcile.rs). Use
/// `LocalCatalogReconciliation.resolve`, which calls this and runs its Dart
/// rules without the Rust core.
abstract final class NativeLocalReconcile {
  static const int _noNumber = -0x8000000000000000;

  /// The moves as (previous, scanned) position pairs and the positions of
  /// the previous tracks that are gone, or null when this build has no Rust
  /// core or a field holds text UTF-8 cannot carry. Two different malformed
  /// strings would both cross as U+FFFD and could look like one file, so
  /// those stay with Dart.
  static ({Uint32List moves, Uint32List removed})? resolve({
    required List<Track> previous,
    required List<bool> refreshed,
    required List<Track> scanned,
  }) {
    if (!LinthraCore.isAvailable) return null;
    final int count = previous.length + scanned.length;
    final BytesBuilder text = BytesBuilder(copy: false);
    final Uint32List spans = Uint32List(12 * count);
    bool lossy = false;
    void add(int at, String part) {
      if (!lossy && _hasUnpairedSurrogate(part)) lossy = true;
      final Uint8List bytes = utf8.encode(part);
      spans[at] = text.length;
      spans[at + 1] = bytes.length;
      text.add(bytes);
    }

    Track track(int i) =>
        i < previous.length ? previous[i] : scanned[i - previous.length];
    for (int i = 0; i < count; i++) {
      final Track t = track(i);
      // Lower-cased here, not in Rust: Dart's case table is the one
      // LocalTrackIdentity is built with.
      add(12 * i, t.uri);
      add(12 * i + 2, t.title.toLowerCase());
      add(12 * i + 4, t.artistName?.toLowerCase() ?? '');
      add(12 * i + 6, t.albumName?.toLowerCase() ?? '');
      add(12 * i + 8, t.albumArtistName?.toLowerCase() ?? '');
      add(12 * i + 10, t.albumId?.toLowerCase() ?? '');
    }
    if (lossy) return null;
    final Uint8List bytes = text.toBytes();
    return using((Arena arena) {
      final Pointer<Uint8> textPointer = arena<Uint8>(bytes.length + 1);
      textPointer.asTypedList(bytes.length).setAll(0, bytes);
      final Pointer<Uint32> spanPointer = arena<Uint32>(spans.length + 1);
      spanPointer.asTypedList(spans.length).setAll(0, spans);
      final Pointer<Int64> durations = arena<Int64>(count + 1);
      final Pointer<Int64> numbers = arena<Int64>(count + 1);
      final Pointer<Uint8> refreshedPointer = arena<Uint8>(previous.length + 1);
      for (int i = 0; i < count; i++) {
        final Track t = track(i);
        durations[i] = t.duration.inMicroseconds;
        numbers[i] = t.trackNumber ?? _noNumber;
      }
      for (int i = 0; i < previous.length; i++) {
        refreshedPointer[i] = refreshed[i] ? 1 : 0;
      }
      final Pointer<LinthraReconcileResult> result = linthraLocalReconcile(
        textPointer,
        bytes.length,
        spanPointer,
        durations,
        numbers,
        refreshedPointer,
        previous.length,
        count,
      );
      if (result == nullptr) {
        // Refused, or it panicked: the caller reconciles the Dart way.
        return null;
      }
      try {
        final int moves = linthraReconcileMoveCount(result);
        final int removed = linthraReconcileRemovedCount(result);
        return (
          moves: Uint32List.fromList(
            moves == 0
                ? const <int>[]
                : linthraReconcileMoves(result).asTypedList(2 * moves),
          ),
          removed: Uint32List.fromList(
            removed == 0
                ? const <int>[]
                : linthraReconcileRemoved(result).asTypedList(removed),
          ),
        );
      } finally {
        linthraReconcileFree(result);
      }
    });
  }

  /// Whether [text] has a surrogate without its other half.
  static bool _hasUnpairedSurrogate(String text) {
    for (int i = 0; i < text.length; i++) {
      final int unit = text.codeUnitAt(i);
      if (unit < 0xD800 || unit > 0xDFFF) continue;
      if (unit > 0xDBFF || i + 1 == text.length) return true;
      final int next = text.codeUnitAt(i + 1);
      if (next < 0xDC00 || next > 0xDFFF) return true;
      i++;
    }
    return false;
  }
}
