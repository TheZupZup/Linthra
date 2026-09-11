import 'local_audio_metadata.dart';

/// Reads audio tags from an on-device file *path* (the desktop/Linux and
/// resolved-path case), the filesystem counterpart of the SAF metadata the
/// native content-resolver walk returns.
///
/// This is a seam, deliberately mirroring [SafDocumentLister]: the source
/// depends on this interface, never on a concrete reader, so tag reading can
/// change without touching the scanner, source, or mapper, which is exactly
/// how the real reader arrived (#407) without a caller moving.
///
/// Which implementation runs is `localMetadataReaderProvider`'s decision:
/// `FilesystemLocalMetadataReader` on desktop/Linux, and
/// [UnsupportedLocalMetadataReader] on Android, whose tags already come from
/// the native SAF walk.
abstract interface class LocalMetadataReader {
  /// Returns the tags for the file at [path], or null when none could be read
  /// (unsupported here, an unreadable file, or a format without tags). Must
  /// never throw: an unreadable file is a null result, not a failed scan.
  Future<LocalAudioMetadata?> readFromPath(String path);
}

/// The optional half of [LocalMetadataReader]: a reader that also owns an
/// on-disk artwork cache, and can be asked to drop what the library no longer
/// references.
///
/// Kept as a *separate* interface, and reached through a `is` check at the one
/// call site (`LibraryController._scanLocal`), for the same reason
/// `StampedCatalogWriter` is: it lets the capability exist without every
/// `LocalMetadataReader` — the Android one, and the fakes in six test files —
/// having to answer a question that is meaningless for them.
///
/// It is also the platform seam. Android's tags and artwork come from the
/// native SAF walk, which manages its own cache; its
/// [UnsupportedLocalMetadataReader] is deliberately not a
/// [LocalArtworkMaintainer], so the sweep simply does not happen there and no
/// caller needs a platform conditional to arrange that.
abstract interface class LocalArtworkMaintainer {
  /// Drops every cached cover this reader owns that [live] does not reference.
  ///
  /// [live] is the complete set of artwork URIs the catalog holds after a
  /// scan; anything else in the reader's own cache is a cover for a file that
  /// was deleted, moved, or re-tagged since, and is dead weight.
  ///
  /// Must never throw, and must never touch anything outside the cache it
  /// owns — emphatically including the user's audio files, which Linthra only
  /// ever reads.
  Future<void> retainArtwork(Set<Uri> live);
}

/// The [LocalMetadataReader] for anywhere a filesystem tag read is not wanted:
/// Android, whose tags come from the native SAF walk, and tests. It reads
/// nothing, so the mapper falls back to filename/folder metadata.
class UnsupportedLocalMetadataReader implements LocalMetadataReader {
  const UnsupportedLocalMetadataReader();

  @override
  Future<LocalAudioMetadata?> readFromPath(String path) async => null;
}
