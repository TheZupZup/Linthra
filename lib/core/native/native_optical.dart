import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../services/optical/cdrom_toc_source.dart';
import 'linthra_core_ffi.dart';

/// CD-Text as the Rust core decodes it: texts by item (0 the disc, 1-99 the
/// tracks), in item order.
typedef NativeCdText = ({
  List<(int, String)> titles,
  List<(int, String)> performers,
});

/// A playable audio track as the Rust core works it out.
typedef NativeAudioTrack = ({int number, int startFrame, int frameCount});

/// Audio CD decoding in the Rust core (native/linthra_core/src/optical.rs).
///
/// Use `cdTextFrom`, `normalizedTocEntries`, `playableAudioTracks` and
/// `musicBrainzDiscId`, which call this. A rule that panics gets Rust's safe
/// answer (no CD-Text, an unreadable disc, no tracks, no id), so these throw
/// only when that panicked too, or the two sides of the ABI disagree.
abstract final class NativeOptical {
  /// The decoded CD-Text, `(titles: [], performers: [])` when there is none
  /// to trust.
  static NativeCdText cdText(Uint8List? response) {
    if (response == null) return (titles: const [], performers: const []);
    return using((Arena arena) {
      final Pointer<Uint8> input = arena<Uint8>(response.length + 1);
      input.asTypedList(response.length).setAll(0, response);
      final Pointer<LinthraCdText> text = linthraCdText(input, response.length);
      if (text == nullptr) return (titles: const [], performers: const []);
      try {
        final Pointer<Size> length = arena<Size>();
        List<(int, String)> list(int which) => <(int, String)>[
              for (int i = 0; i < linthraCdTextCount(text, which); i++)
                (
                  linthraCdTextItem(text, which, i),
                  _latin1(linthraCdTextValue(text, which, i, length), length),
                ),
            ];
        return (
          titles: list(LinthraCdTextList.titles),
          performers: list(LinthraCdTextList.performers),
        );
      } finally {
        linthraCdTextFree(text);
      }
    });
  }

  /// The positions of [toc]'s tracks in track order, or null for a TOC that
  /// contradicts itself.
  static List<int>? tocOrder(RawCdToc toc) {
    return using((Arena arena) {
      final _Entries e = _Entries(arena, toc.tracks);
      final int n = toc.tracks.length;
      final Pointer<Uint32> order = arena<Uint32>(n + 1);
      final int written = linthraCdTocOrder(
        toc.firstTrack,
        toc.lastTrack,
        toc.leadOutLba,
        e.numbers,
        e.starts,
        e.data,
        n,
        order,
      );
      if (written == linthraPanicCount) {
        throw StateError('linthra_cd_toc_order gave no answer');
      }
      if (written < 0) return null;
      return List<int>.of(order.asTypedList(written));
    });
  }

  /// The playable audio tracks of [entries], already in track order.
  static List<NativeAudioTrack> playableTracks(
    List<RawCdTocTrack> entries,
    int leadOutLba,
  ) {
    return using((Arena arena) {
      final _Entries e = _Entries(arena, entries);
      final int n = entries.length;
      final Pointer<Int64> out = arena<Int64>(3 * n + 3);
      final int written = linthraCdPlayableTracks(
        e.numbers,
        e.starts,
        e.data,
        n,
        leadOutLba,
        out,
      );
      // Refused (the two sides of the ABI disagree), or Rust's safe answer
      // panicked too.
      if (written < 0) {
        throw StateError('linthra_cd_playable_tracks gave no answer');
      }
      return <NativeAudioTrack>[
        for (int k = 0; k < written; k++)
          (
            number: out[3 * k],
            startFrame: out[3 * k + 1],
            frameCount: out[3 * k + 2],
          ),
      ];
    });
  }

  /// [toc]'s MusicBrainz disc id, null when it has none.
  static String? discId(RawCdToc toc) {
    return using((Arena arena) {
      final _Entries e = _Entries(arena, toc.tracks);
      final Pointer<Uint8> out = arena<Uint8>(linthraDiscIdLength);
      final int answer = linthraCdDiscId(
        toc.firstTrack,
        toc.lastTrack,
        toc.leadOutLba,
        e.numbers,
        e.starts,
        e.data,
        toc.tracks.length,
        out,
      );
      // Refused (the two sides of the ABI disagree), or Rust's safe answer
      // panicked too.
      if (answer < 0) throw StateError('linthra_cd_disc_id gave no answer');
      if (answer == 0) return null;
      return String.fromCharCodes(out.asTypedList(linthraDiscIdLength));
    });
  }

  static String _latin1(Pointer<Uint8> bytes, Pointer<Size> length) =>
      length.value == 0
          ? ''
          : String.fromCharCodes(bytes.asTypedList(length.value));
}

/// A TOC's entries as the parallel arrays the Rust calls read.
class _Entries {
  _Entries(Arena arena, List<RawCdTocTrack> tracks)
      : numbers = arena<Int64>(tracks.length + 1),
        starts = arena<Int64>(tracks.length + 1),
        data = arena<Uint8>(tracks.length + 1) {
    for (int i = 0; i < tracks.length; i++) {
      numbers[i] = tracks[i].number;
      starts[i] = tracks[i].startLba;
      data[i] = tracks[i].isData ? 1 : 0;
    }
  }

  final Pointer<Int64> numbers;
  final Pointer<Int64> starts;
  final Pointer<Uint8> data;
}
