import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'linthra_core.dart';
import 'linthra_core_ffi.dart';

/// A track's names and numbers as the Rust core maps them; its id, uri and
/// cover stay with the caller.
typedef NativeMappedTrack = ({
  String title,
  String? artist,
  String? album,
  String? albumId,
  String? albumArtist,
  int? trackNumber,
  int durationUs,
  int? cueEndUs,
});

/// The tags a mapping starts from, as `LocalAudioMetadata` holds them.
typedef NativeTrackTags = ({
  String? title,
  String? artist,
  String? album,
  String? albumArtist,
  String? albumId,
  int? trackNumber,
  int? durationUs,
});

/// One CUE track as `CueSheetTrack` holds it.
typedef NativeCueTrackInput = ({
  int number,
  int startUs,
  int? endUs,
  String? title,
  String? performer,
  String? album,
  String? albumPerformer,
});

/// What [NativeLocalTrack.map] is handed: a file on disk, a document known
/// only by its name, or a CUE track.
enum NativeTrackSource { path, document, cue }

/// Maps scanned files to tracks in the Rust core
/// (native/linthra_core/src/scan/mapper.rs). Use `LocalTrackMapper`, which
/// calls this and runs its Dart rules without the Rust core.
abstract final class NativeLocalTrack {
  /// The file at [path] (a filesystem path, a document's name, or a CUE
  /// track's audio path, by [source]), or null without the Rust core or when
  /// a text holds what UTF-8 cannot carry (an unpaired surrogate).
  static NativeMappedTrack? map({
    required NativeTrackSource source,
    required String path,
    String? scanRoot,
    NativeTrackTags? tags,
    NativeCueTrackInput? cue,
  }) {
    if (!LinthraCore.isAvailable) return null;
    final List<String?> texts = <String?>[
      path,
      scanRoot,
      tags?.title,
      tags?.artist,
      tags?.album,
      tags?.albumArtist,
      tags?.albumId,
      cue?.title,
      cue?.performer,
      cue?.album,
      cue?.albumPerformer,
    ];
    if (texts.any((String? t) => t != null && _hasUnpairedSurrogate(t))) {
      return null;
    }
    final List<int?> numbers = <int?>[
      tags?.trackNumber,
      tags?.durationUs,
      cue?.number,
      cue?.startUs,
      cue?.endUs,
    ];
    final BytesBuilder buffer = BytesBuilder(copy: false);
    return using((Arena arena) {
      final Pointer<Int64> bounds = arena<Int64>(2 * LinthraLocalTrack.texts);
      for (int i = 0; i < texts.length; i++) {
        final String? text = texts[i];
        bounds[2 * i] = buffer.length;
        if (text == null) {
          bounds[2 * i + 1] = -1;
          continue;
        }
        final Uint8List bytes = utf8.encode(text);
        bounds[2 * i + 1] = bytes.length;
        buffer.add(bytes);
      }
      final Pointer<Int64> values = arena<Int64>(2 * LinthraLocalTrack.numbers);
      for (int i = 0; i < numbers.length; i++) {
        final int? number = numbers[i];
        values[2 * i] = number == null ? 0 : 1;
        values[2 * i + 1] = number ?? 0;
      }
      final Uint8List all = buffer.takeBytes();
      final Pointer<Uint8> text = arena<Uint8>(all.length + 1);
      text.asTypedList(all.length).setAll(0, all);
      final Pointer<LinthraMappedTrack> mapped = linthraLocalTrackMap(
        _kinds[source]!,
        text,
        all.length,
        bounds,
        values,
      );
      if (mapped == nullptr) {
        // Refused, or it panicked: the caller maps the Dart way.
        return null;
      }
      try {
        final Pointer<Size> length = arena<Size>();
        final Pointer<Uint8> present = arena<Uint8>();
        String? field(int which) {
          final Pointer<Uint8> bytes = linthraMappedText(mapped, which, length);
          if (bytes == nullptr) return null;
          return _decode(bytes.asTypedList(length.value));
        }

        int? number(int which) {
          final int value = linthraMappedNumber(mapped, which, present);
          return present.value == 0 ? null : value;
        }

        return (
          title: field(LinthraLocalTrack.title)!,
          artist: field(LinthraLocalTrack.artist),
          album: field(LinthraLocalTrack.album),
          albumId: field(LinthraLocalTrack.albumId),
          albumArtist: field(LinthraLocalTrack.albumArtist),
          trackNumber: number(LinthraLocalTrack.trackNumber),
          durationUs: number(LinthraLocalTrack.durationUs)!,
          cueEndUs: number(LinthraLocalTrack.cueEndUs),
        );
      } finally {
        linthraMappedFree(mapped);
      }
    });
  }

  static const Map<NativeTrackSource, int> _kinds = <NativeTrackSource, int>{
    NativeTrackSource.path: LinthraLocalTrack.path,
    NativeTrackSource.document: LinthraLocalTrack.document,
    NativeTrackSource.cue: LinthraLocalTrack.cue,
  };

  /// [bytes] as text, a leading byte order mark kept: `utf8.decode` drops
  /// one, and a title can be nothing else.
  static String _decode(Uint8List bytes) {
    int marks = 0;
    while (bytes.length >= 3 * marks + 3 &&
        bytes[3 * marks] == 0xEF &&
        bytes[3 * marks + 1] == 0xBB &&
        bytes[3 * marks + 2] == 0xBF) {
      marks++;
    }
    return '\uFEFF' * marks +
        utf8.decode(Uint8List.sublistView(bytes, 3 * marks));
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
