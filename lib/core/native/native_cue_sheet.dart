import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'linthra_core.dart';
import 'linthra_core_ffi.dart';

/// One audio track of a CUE sheet as the Rust core parses it: its FILE name
/// as written (with `\` turned into `/`), not yet joined to the sheet's
/// folder.
typedef NativeCueTrack = ({
  int number,
  String file,
  int startMs,
  String? title,
  String? performer,
  String? album,
  String? albumPerformer,
});

/// Decodes and parses CUE sheets in the Rust core
/// (native/linthra_core/src/cue_sheet.rs). Use `CueSheet.decode` and
/// `CueSheet.parse`, which call this and run their Dart rules without the
/// Rust core.
abstract final class NativeCueSheet {
  /// [bytes] decoded as UTF-8 or Windows-1251, or null without the Rust core.
  static String? decode(List<int> bytes) {
    if (!LinthraCore.isAvailable) return null;
    return using((Arena arena) {
      final Pointer<Uint8> input = arena<Uint8>(bytes.length + 1);
      input.asTypedList(bytes.length).setAll(0, bytes);
      final Pointer<LinthraCueText> text =
          linthraCueDecode(input, bytes.length);
      if (text == nullptr) {
        throw StateError('linthra_cue_decode refused its input');
      }
      try {
        final Pointer<Size> length = arena<Size>();
        // UTF-16 units, not UTF-8: a second utf8.decode would drop another
        // leading byte order mark.
        final Pointer<Uint16> units = linthraCueText(text, length);
        return length.value == 0
            ? ''
            : String.fromCharCodes(units.asTypedList(length.value));
      } finally {
        linthraCueTextFree(text);
      }
    });
  }

  /// The audio tracks of [contents], or null without the Rust core or when
  /// [contents] holds text UTF-8 cannot carry (an unpaired surrogate).
  static List<NativeCueTrack>? parse(String contents) {
    if (!LinthraCore.isAvailable || _hasUnpairedSurrogate(contents)) {
      return null;
    }
    final Uint8List bytes = utf8.encode(contents);
    return using((Arena arena) {
      final Pointer<Uint8> input = arena<Uint8>(bytes.length + 1);
      input.asTypedList(bytes.length).setAll(0, bytes);
      final Pointer<LinthraCueTracks> tracks =
          linthraCueParse(input, bytes.length);
      if (tracks == nullptr) {
        throw StateError('linthra_cue_parse refused its input');
      }
      try {
        final Pointer<Size> length = arena<Size>();
        String? field(int i, int which) {
          final Pointer<Uint8> text = linthraCueField(tracks, i, which, length);
          if (text == nullptr) return null;
          return length.value == 0
              ? ''
              : utf8.decode(text.asTypedList(length.value));
        }

        return <NativeCueTrack>[
          for (int i = 0; i < linthraCueTrackCount(tracks); i++)
            (
              number: linthraCueNumber(tracks, i),
              file: field(i, LinthraCueField.file)!,
              startMs: linthraCueStartMs(tracks, i),
              title: field(i, LinthraCueField.title),
              performer: field(i, LinthraCueField.performer),
              album: field(i, LinthraCueField.album),
              albumPerformer: field(i, LinthraCueField.albumPerformer),
            ),
        ];
      } finally {
        linthraCueTracksFree(tracks);
      }
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
