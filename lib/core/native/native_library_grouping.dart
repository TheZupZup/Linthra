import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../models/track.dart';
import 'linthra_core.dart';
import 'linthra_core_ffi.dart';

/// The Rust core's grouping of a catalog, as raw arrays. Track indices point
/// into the list that was grouped, and [LinthraGrouping.noTrack] means none.
typedef NativeLibraryGroups = ({
  List<String> albumIds,

  /// [LinthraGrouping.albumFields] values per album: the first track with a
  /// title, with an album artist, with an artist, then the track count.
  Uint32List albumFields,
  List<String> artistIds,

  /// [LinthraGrouping.artistFields] values per artist: the first track with
  /// a name, then the album count and the track count.
  Uint32List artistFields,

  /// For each track, its album's position in [albumIds].
  Uint32List trackAlbum,

  /// For each track, its artist's position in [artistIds].
  Uint32List trackArtist,
});

/// Runs the album/artist grouping in the Rust core
/// (native/linthra_core/src/library_grouping.rs).
///
/// Use `groupAlbums`, `groupArtists` or `groupLibrary`
/// (lib/core/catalog/library_grouping.dart), which build the models from this
/// and fall back to the Dart grouping without the Rust core.
abstract final class NativeLibraryGrouping {
  /// The grouping of [tracks], or null when this build has no Rust core or a
  /// name holds text UTF-8 cannot carry (an unpaired surrogate), which would
  /// make its ids differ from the ones Dart computes.
  static NativeLibraryGroups? group(List<Track> tracks) {
    if (!LinthraCore.isAvailable) return null;
    final int count = tracks.length;
    final _Utf8Writer text = _Utf8Writer(count);

    return using((Arena arena) {
      final Pointer<Uint32> spans = arena<Uint32>(8 * count + 8);
      final Uint32List spanList = spans.asTypedList(8 * count);
      for (int i = 0; i < count; i++) {
        final Track track = tracks[i];
        // Lower-cased here, not in Rust: Dart's case table is the one the
        // Dart ids are built from (see library_grouping.rs).
        text.add(spanList, 8 * i, track.albumId ?? '');
        text.add(spanList, 8 * i + 2, track.albumName?.toLowerCase() ?? '');
        text.add(spanList, 8 * i + 4, track.artistName?.toLowerCase() ?? '');
        text.add(
          spanList,
          8 * i + 6,
          track.albumArtistName?.toLowerCase() ?? '',
        );
      }
      if (text.lossy) return null;

      final Uint8List bytes = text.bytes();
      final Pointer<Uint8> textPointer = arena<Uint8>(bytes.length + 1);
      textPointer.asTypedList(bytes.length).setAll(0, bytes);

      final Pointer<LinthraGroupingResult> result = linthraLibraryGroup(
        textPointer,
        bytes.length,
        spans,
        count,
      );
      // Every span was written by [_Utf8Writer] from Dart strings, so a
      // refusal means the two sides of the ABI disagree.
      if (result == nullptr) {
        // Refused, or it panicked: the caller groups the Dart way.
        return null;
      }
      try {
        return _read(linthraGroupingResultView(result), count);
      } finally {
        linthraGroupingResultFree(result);
      }
    });
  }

  /// Copies everything out of [view] before the result is freed.
  static NativeLibraryGroups _read(LinthraLibraryGroupsView view, int count) {
    final int albums = view.albumCount;
    final int artists = view.artistCount;
    final Uint32List albumOffsets = view.albumIds.asTypedList(albums + 1);
    final Uint32List artistOffsets = view.artistIds.asTypedList(artists + 1);
    // Artist ids follow album ids, so the last artist offset is the end.
    final Uint8List ids = view.ids.asTypedList(artistOffsets[artists]);
    // Ids are base64url behind an ASCII prefix, so each byte is one code unit.
    List<String> names(Uint32List offsets, int length) => <String>[
          for (int i = 0; i < length; i++)
            String.fromCharCodes(ids, offsets[i], offsets[i + 1]),
        ];
    return (
      albumIds: names(albumOffsets, albums),
      albumFields: Uint32List.fromList(
        view.albumFields.asTypedList(albums * LinthraGrouping.albumFields),
      ),
      artistIds: names(artistOffsets, artists),
      artistFields: Uint32List.fromList(
        view.artistFields.asTypedList(artists * LinthraGrouping.artistFields),
      ),
      trackAlbum: Uint32List.fromList(view.trackAlbum.asTypedList(count)),
      trackArtist: Uint32List.fromList(view.trackArtist.asTypedList(count)),
    );
  }
}

/// One UTF-8 buffer holding every field, and the spans that point into it.
///
/// ASCII (most metadata) is written byte by byte with no allocation; anything
/// else goes through the codec.
class _Utf8Writer {
  /// Sized for [tracks] typical tracks, so a normal catalog never grows it.
  _Utf8Writer(int tracks) : _bytes = Uint8List(64 + tracks * 48);

  Uint8List _bytes;
  int _length = 0;

  /// Whether a string held an unpaired surrogate, which UTF-8 cannot carry:
  /// the codec writes U+FFFD instead, so Rust would see different text.
  bool lossy = false;

  /// Writes [part] and its span (start, length) into [spans] at [at].
  void add(Uint32List spans, int at, String part) {
    final int start = _length;
    spans[at] = start;
    // At most three UTF-8 bytes per UTF-16 code unit.
    _reserve(part.length * 3);
    for (int i = 0; i < part.length; i++) {
      final int unit = part.codeUnitAt(i);
      if (unit >= 0x80) {
        _length = start;
        if (_hasUnpairedSurrogate(part, i)) lossy = true;
        final Uint8List encoded = utf8.encode(part);
        _bytes.setRange(_length, _length + encoded.length, encoded);
        _length += encoded.length;
        break;
      }
      _bytes[_length++] = unit;
    }
    spans[at + 1] = _length - start;
  }

  void _reserve(int more) {
    if (_length + more <= _bytes.length) return;
    int capacity = _bytes.length * 2;
    while (capacity < _length + more) {
      capacity *= 2;
    }
    _bytes = Uint8List(capacity)..setRange(0, _length, _bytes);
  }

  /// The bytes written so far, as a view (no copy).
  Uint8List bytes() => Uint8List.sublistView(_bytes, 0, _length);
}

/// Whether [text], from [from] on, has a surrogate without its other half.
bool _hasUnpairedSurrogate(String text, int from) {
  for (int i = from; i < text.length; i++) {
    final int unit = text.codeUnitAt(i);
    if (unit < 0xD800 || unit > 0xDFFF) continue;
    if (unit > 0xDBFF) return true;
    if (i + 1 == text.length) return true;
    final int next = text.codeUnitAt(i + 1);
    if (next < 0xDC00 || next > 0xDFFF) return true;
    i++;
  }
  return false;
}
