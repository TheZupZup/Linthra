import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../models/track.dart';
import 'linthra_core.dart';
import 'linthra_core_ffi.dart';
import 'native_text.dart';

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
    final NativeTextWriter text = NativeTextWriter(count);

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

      final Pointer<LinthraGroupingResult> result =
          linthraLibraryGroup(textPointer, bytes.length, spans, count);
      // Every span was written by [NativeTextWriter] from Dart strings, so a
      // refusal means the two sides of the ABI disagree.
      if (result == nullptr) {
        throw StateError('linthra_library_group refused its input');
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
