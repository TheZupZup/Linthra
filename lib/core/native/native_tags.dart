import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../sources/local/local_audio_metadata.dart';
import 'linthra_core.dart';
import 'linthra_core_ffi.dart';

/// What the Rust core made of one file.
enum NativeTagOutcome {
  /// Its tags were read: [NativeTagRead.tags] holds them.
  read,

  /// Not a format the Rust reader handles (today FLAC, Ogg Vorbis, Opus and
  /// MP3), or one whose tags don't hold together: read it another way.
  notHandled,

  /// The file could not be read, so nothing is known about its tags.
  ioError,
}

/// The tags and cover of one file, as the Rust core read them.
typedef NativeTagRead = ({
  NativeTagOutcome outcome,
  LocalAudioMetadata tags,
  Uint8List? cover,
});

/// Reads audio tags in the Rust core (native/linthra_core/src/tags/).
///
/// `FilesystemLocalMetadataReader` asks this first, on its parser isolate,
/// and reads the file the Dart way when there is no Rust core or the format
/// isn't one it handles.
abstract final class NativeTags {
  /// The tags of the file at [path], and its cover when [withCover]; null
  /// when this build has no Rust core.
  static NativeTagRead? read(String path, {required bool withCover}) {
    if (!LinthraCore.isAvailable) return null;
    return using((Arena arena) {
      // dart:io opens a path by its UTF-8 bytes, so Rust is handed the same.
      final Uint8List encoded = utf8.encode(path);
      final Pointer<Uint8> pathBytes = arena<Uint8>(encoded.length + 1);
      pathBytes.asTypedList(encoded.length).setAll(0, encoded);

      final Pointer<LinthraTagsResult> result =
          linthraTagsRead(pathBytes, encoded.length, withCover);
      if (result == nullptr) {
        throw StateError('linthra_tags_read refused its path');
      }
      try {
        final Pointer<Size> length = arena<Size>();
        String? text(int field) {
          final Pointer<Uint8> bytes = linthraTagsText(result, field, length);
          if (bytes == nullptr) return null;
          return utf8.decode(bytes.asTypedList(length.value));
        }

        final NativeTagOutcome outcome = switch (linthraTagsStatus(result)) {
          LinthraTags.read => NativeTagOutcome.read,
          LinthraTags.notHandled => NativeTagOutcome.notHandled,
          _ => NativeTagOutcome.ioError,
        };
        if (outcome != NativeTagOutcome.read) {
          return (
            outcome: outcome,
            tags: LocalAudioMetadata.empty,
            cover: null,
          );
        }
        final int track = linthraTagsTrackNumber(result);
        final int micros = linthraTagsDurationMicros(result);
        // Copied out at once: [length] is reused for every field below.
        final Pointer<Uint8> coverBytes = linthraTagsCover(result, length);
        final Uint8List? cover = coverBytes == nullptr
            ? null
            : Uint8List.fromList(coverBytes.asTypedList(length.value));
        return (
          outcome: outcome,
          tags: LocalAudioMetadata(
            title: text(LinthraTags.title),
            artist: text(LinthraTags.artist),
            albumArtist: text(LinthraTags.albumArtist),
            album: text(LinthraTags.album),
            trackNumber: track > 0 ? track : null,
            duration: micros > 0 ? Duration(microseconds: micros) : null,
          ),
          cover: cover,
        );
      } finally {
        linthraTagsFree(result);
      }
    });
  }
}
