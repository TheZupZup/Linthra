import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'linthra_core.dart';
import 'linthra_core_ffi.dart';

/// What the Rust unifier reads of one catalog row.
typedef NativeUnifyTrack = ({
  String uri,
  String title,
  String artist,
  String album,
  int source,
  int rank,
  int durationSeconds,
  int? trackNumber,
});

/// Merges one song's copies from different servers in the Rust core
/// (native/linthra_core/src/track_unifier.rs). Use `unifyTracks`, which calls
/// this and runs its Dart rules without the Rust core.
abstract final class NativeTrackUnifier {
  static const int _noNumber = -0x8000000000000000;

  /// The library rows, each a list of indices into [tracks]; null when this
  /// build has no Rust core.
  static List<List<int>>? unify(List<NativeUnifyTrack> tracks) {
    if (!LinthraCore.isAvailable) return null;
    final int count = tracks.length;
    final BytesBuilder text = BytesBuilder(copy: false);
    final Uint32List spans = Uint32List(8 * count);
    void add(int at, String part) {
      final Uint8List bytes = utf8.encode(part);
      spans[at] = text.length;
      spans[at + 1] = bytes.length;
      text.add(bytes);
    }

    for (int i = 0; i < count; i++) {
      final NativeUnifyTrack t = tracks[i];
      add(8 * i, t.uri);
      add(8 * i + 2, t.title);
      add(8 * i + 4, t.artist);
      add(8 * i + 6, t.album);
    }
    final Uint8List bytes = text.toBytes();
    return using((Arena arena) {
      final Pointer<Uint8> textPointer = arena<Uint8>(bytes.length + 1);
      textPointer.asTypedList(bytes.length).setAll(0, bytes);
      final Pointer<Uint32> spanPointer = arena<Uint32>(spans.length + 1);
      spanPointer.asTypedList(spans.length).setAll(0, spans);
      final Pointer<Uint32> sources = arena<Uint32>(count + 1);
      final Pointer<Uint32> ranks = arena<Uint32>(count + 1);
      final Pointer<Int64> durations = arena<Int64>(count + 1);
      final Pointer<Int64> numbers = arena<Int64>(count + 1);
      for (int i = 0; i < count; i++) {
        final NativeUnifyTrack t = tracks[i];
        sources[i] = t.source;
        ranks[i] = t.rank;
        durations[i] = t.durationSeconds;
        numbers[i] = t.trackNumber ?? _noNumber;
      }
      final Pointer<LinthraUnifyResult> result = linthraUnifyTracks(textPointer,
          bytes.length, spanPointer, sources, ranks, durations, numbers, count);
      if (result == nullptr) {
        throw StateError('linthra_unify_tracks refused its input');
      }
      try {
        final int rows = linthraUnifyRows(result);
        final Uint32List starts =
            linthraUnifyStarts(result).asTypedList(rows + 1);
        final Uint32List indices =
            linthraUnifyIndices(result).asTypedList(starts[rows]);
        return <List<int>>[
          for (int r = 0; r < rows; r++)
            List<int>.of(indices.sublist(starts[r], starts[r + 1])),
        ];
      } finally {
        linthraUnifyFree(result);
      }
    });
  }

  /// Whether [row] is the playing [current] track, as
  /// `isCurrentPlaybackTrack` decides it, or null when this build has no
  /// Rust core or a field holds text UTF-8 cannot carry (an unpaired
  /// surrogate), which would cross as U+FFFD and could make two different
  /// titles look alike.
  ///
  /// [sameSource] is whether both come from the same server.
  static bool? isCurrent(
    NativeUnifyTrack row,
    NativeUnifyTrack current, {
    required bool sameSource,
  }) {
    if (!LinthraCore.isAvailable) return null;
    final List<String> parts = <String>[
      row.uri,
      row.title,
      row.artist,
      row.album,
      current.uri,
      current.title,
      current.artist,
      current.album,
    ];
    if (parts.any(_hasUnpairedSurrogate)) return null;
    final BytesBuilder text = BytesBuilder(copy: false);
    final Uint32List spans = Uint32List(16);
    for (int k = 0; k < parts.length; k++) {
      final Uint8List bytes = utf8.encode(parts[k]);
      spans[2 * k] = text.length;
      spans[2 * k + 1] = bytes.length;
      text.add(bytes);
    }
    final Uint8List bytes = text.toBytes();
    return using((Arena arena) {
      final Pointer<Uint8> textPointer = arena<Uint8>(bytes.length + 1);
      textPointer.asTypedList(bytes.length).setAll(0, bytes);
      final Pointer<Uint32> spanPointer = arena<Uint32>(16);
      spanPointer.asTypedList(16).setAll(0, spans);
      final Pointer<Uint32> sources = arena<Uint32>(2);
      sources[0] = 0;
      sources[1] = sameSource ? 0 : 1;
      final Pointer<Int64> durations = arena<Int64>(2);
      final Pointer<Int64> numbers = arena<Int64>(2);
      durations[0] = row.durationSeconds;
      durations[1] = current.durationSeconds;
      numbers[0] = row.trackNumber ?? _noNumber;
      numbers[1] = current.trackNumber ?? _noNumber;
      final int answer = linthraIsCurrentTrack(
        textPointer,
        bytes.length,
        spanPointer,
        sources,
        durations,
        numbers,
      );
      // Every span was written here from Dart strings, so anything but 0 or
      // 1 means the two sides of the ABI disagree.
      if (answer > 1) {
        throw StateError('linthra_is_current_track refused its input');
      }
      return answer == 1;
    });
  }

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
