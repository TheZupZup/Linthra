import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../models/track.dart';
import 'linthra_core_ffi.dart';

/// Works out moved and deleted local files in the Rust core
/// (native/linthra_core/src/local_reconcile.rs). Use
/// `LocalCatalogReconciliation.resolve`, which calls this.
abstract final class NativeLocalReconcile {
  static const int _noNumber = -0x8000000000000000;

  /// The moves as (previous, scanned) position pairs and the positions of
  /// the previous tracks that are gone.
  ///
  /// A panic gets Rust's safe answer (nothing moved, nothing confirmed gone),
  /// so this throws only when that panicked too.
  static ({Uint32List moves, Uint32List removed}) resolve({
    required List<Track> previous,
    required List<bool> refreshed,
    required List<Track> scanned,
  }) {
    final int count = previous.length + scanned.length;
    final BytesBuilder text = BytesBuilder(copy: false);
    final Uint32List spans = Uint32List(12 * count);
    void add(int at, String part) {
      final Uint8List bytes = utf8.encode(_wellFormed(part));
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
        throw StateError('linthra_local_reconcile gave no answer');
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

  /// [text] with each surrogate that lacks its other half (which UTF-8
  /// cannot carry) turned into its own private-use character, U+F0000 and
  /// up. U+FFFD would do for display, but two different malformed paths
  /// would then cross as one, and this compares them.
  static String _wellFormed(String text) {
    StringBuffer? out;
    int copied = 0;
    for (int i = 0; i < text.length; i++) {
      final int unit = text.codeUnitAt(i);
      if (unit < 0xD800 || unit > 0xDFFF) continue;
      if (unit <= 0xDBFF && i + 1 < text.length) {
        final int next = text.codeUnitAt(i + 1);
        if (next >= 0xDC00 && next <= 0xDFFF) {
          i++;
          continue;
        }
      }
      (out ??= StringBuffer())
        ..write(text.substring(copied, i))
        ..writeCharCode(0xF0000 + unit - 0xD800);
      copied = i + 1;
    }
    if (out == null) return text;
    return (out..write(text.substring(copied))).toString();
  }
}
