import 'local_audio_metadata.dart';

/// Reads audio tags from an on-device file *path* (the desktop/Linux and
/// resolved-path case), the filesystem counterpart of the SAF metadata the
/// native content-resolver walk returns.
///
/// This is a seam, deliberately mirroring [SafDocumentLister]: the source
/// depends on this interface, never on a concrete reader, so tag reading can be
/// added without touching the scanner, source, or mapper. The production default
/// is [UnsupportedLocalMetadataReader], which reads nothing — so a filesystem
/// scan currently relies on filename/folder fallback, exactly as before. A real
/// pure-Dart reader (ID3/Vorbis/MP4) can slot in here later as a focused
/// follow-up without changing any caller.
abstract interface class LocalMetadataReader {
  /// Returns the tags for the file at [path], or null when none could be read
  /// (unsupported here, an unreadable file, or a format without tags). Must
  /// never throw: an unreadable file is a null result, not a failed scan.
  Future<LocalAudioMetadata?> readFromPath(String path);
}

/// The default [LocalMetadataReader] for platforms/builds without a real
/// filesystem tag reader (desktop today, and tests): it reads nothing, so the
/// mapper falls back to filename/folder metadata and behaviour is unchanged.
class UnsupportedLocalMetadataReader implements LocalMetadataReader {
  const UnsupportedLocalMetadataReader();

  @override
  Future<LocalAudioMetadata?> readFromPath(String path) async => null;
}
