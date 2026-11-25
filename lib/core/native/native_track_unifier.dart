import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../models/track.dart';
import 'linthra_core.dart';
import 'linthra_core_ffi.dart';
import 'native_text.dart';

/// Runs the cross-provider merge in the Rust core
/// (native/linthra_core/src/track_unifier.rs).
///
/// Use `unifyTracks` (lib/core/catalog/track_unifier.dart), which builds the
/// logical tracks from this and falls back to the Dart rules without the Rust
/// core.
abstract final class NativeTrackUnifier {
  /// The logical tracks of [tracks], or null when this build has no Rust core or a field holds
  /// text UTF-8 cannot carry (an unpaired surrogate).
  ///
  /// Logical track `i` is the copies at
  /// `members[offsets[i]]` to `members[offsets[i + 1] - 1]`, best first.
  ///
  /// [sources] and [ranks] give, per track, which provider owns it (equal
  /// values for the same provider) and that provider's preference rank.
  static ({Uint32List offsets, Uint32List members})? unify(
    List<Track> tracks,
    List<int> sources,
    List<int> ranks,
  ) {
    if (!LinthraCore.isAvailable) return null;
    final int count = tracks.length;
    final NativeTextWriter text = NativeTextWriter(count);

    return using((Arena arena) {
      final Pointer<Uint32> spans = arena<Uint32>(8 * count + 8);
      final Pointer<Int64> numbers = arena<Int64>(3 * count + 3);
      final Pointer<Uint32> ids = arena<Uint32>(2 * count + 2);
      final Uint32List spanList = spans.asTypedList(8 * count);
      final Int64List numberList = numbers.asTypedList(3 * count);
      final Uint32List idList = ids.asTypedList(2 * count);
      for (int i = 0; i < count; i++) {
        final Track track = tracks[i];
        // Lower-cased here, not in Rust: Dart's case table is the one the
        // Dart rules fold with.
        text.add(spanList, 8 * i, track.title.toLowerCase());
        text.add(spanList, 8 * i + 2, track.artistName?.toLowerCase() ?? '');
        text.add(spanList, 8 * i + 4, track.albumName?.toLowerCase() ?? '');
        text.add(spanList, 8 * i + 6, track.uri);
        final int? number = track.trackNumber;
        numberList[3 * i] = track.duration.inSeconds;
        numberList[3 * i + 1] = number == null ? 0 : 1;
        numberList[3 * i + 2] = number ?? 0;
        idList[2 * i] = sources[i];
        idList[2 * i + 1] = ranks[i];
      }
      if (text.lossy) return null;

      final Uint8List bytes = text.bytes();
      final Pointer<Uint8> textPointer = arena<Uint8>(bytes.length + 1);
      textPointer.asTypedList(bytes.length).setAll(0, bytes);

      final Pointer<LinthraUnifyResult> result = linthraUnifyTracks(
        textPointer,
        bytes.length,
        spans,
        numbers,
        ids,
        count,
      );
      // Every span was written by [NativeTextWriter] from Dart strings, so a
      // refusal means the two sides of the ABI disagree.
      if (result == nullptr) {
        throw StateError('linthra_unify_tracks refused its input');
      }
      try {
        final LinthraUnifyView view = linthraUnifyResultView(result);
        final Uint32List offsets = Uint32List.fromList(
          view.offsets.asTypedList(view.count + 1),
        );
        return (
          offsets: offsets,
          members: Uint32List.fromList(
            view.members.asTypedList(offsets.last),
          ),
        );
      } finally {
        linthraUnifyResultFree(result);
      }
    });
  }
}
