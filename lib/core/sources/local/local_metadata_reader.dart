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

/// What one read of a file's tags came to: the tags, or null, and whether a
/// null means the file could not be read this time rather than that it holds
/// no tags.
typedef LocalMetadataRead = ({LocalAudioMetadata? metadata, bool failed});

/// The optional half of a [LocalMetadataReader] that can tell its two nulls
/// apart: a file it read and found nothing in, and one it could not read (an
/// I/O error, a parse that threw or ran past its time limit).
///
/// A scan treats the first as settled and the second as worth one more try:
/// it may not happen again (a network share stalling, a drive answering with
/// an error), and a row stored as read would be reused by every later scan,
/// so the tags would never come back (#743).
///
/// Separate from [LocalMetadataReader], and reached through an `is` check, for
/// the reason [LocalArtworkMaintainer] is: a reader that can't tell (Android's,
/// the test fakes) answers nothing, and its nulls count as no tags, as all
/// nulls did before.
abstract interface class LocalMetadataReadOutcomes {
  /// Reads the tags for the file at [path], as [LocalMetadataReader.readFromPath]
  /// does, saying whether a null is a failed read. Must never throw.
  Future<LocalMetadataRead> readWithOutcome(String path);
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

/// The other optional half of a reader that owns an artwork cache: which of
/// the covers the catalog points at it no longer holds.
///
/// That cache lives where the platform keeps data it may reclaim (the XDG
/// cache directory on Linux), so its entries can go while the catalog still
/// points at them: the user clears `~/.cache`, or a cleanup tool does. An
/// incremental scan reuses an unchanged file's row as it is, cover included,
/// so a scan has to ask this before it reuses one, or a cover that went would
/// never come back.
///
/// Separate from [LocalArtworkMaintainer] for the same reason that one is
/// separate from [LocalMetadataReader]: only the reader that owns such a cache
/// has anything to answer.
abstract interface class LocalArtworkInventory {
  /// The URIs among [referenced] that point into this reader's cache at an
  /// entry it no longer holds. A URI that does not point into the cache is
  /// never in the answer.
  ///
  /// Must never throw: a cache that cannot be read answers with nothing, which
  /// leaves every row to be reused as before.
  Future<Set<Uri>> missingArtwork(Set<Uri> referenced);
}

/// The [LocalMetadataReader] for anywhere a filesystem tag read is not wanted:
/// Android, whose tags come from the native SAF walk, and tests. It reads
/// nothing, so the mapper falls back to filename/folder metadata.
class UnsupportedLocalMetadataReader implements LocalMetadataReader {
  const UnsupportedLocalMetadataReader();

  @override
  Future<LocalAudioMetadata?> readFromPath(String path) async => null;
}
