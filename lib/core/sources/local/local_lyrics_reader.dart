/// Reads the raw text of a *sidecar* lyrics file sitting next to a local track —
/// `Song.lrc` (synced) or `Song.txt` (plain) beside `Song.mp3`.
///
/// This is a seam, deliberately mirroring [LocalMetadataReader] and
/// [SafDocumentLister]: [LocalLyricsService] depends on this interface, never on
/// a concrete reader, so *how* a sidecar is located stays platform-specific and
/// swappable — the Android binding finds the sibling SAF document through the
/// content resolver under the folder's existing grant (no broad storage
/// permission, no raw `/storage/...` path), while the desktop binding reads the
/// neighbouring file from the filesystem.
///
/// Contract: [readSidecar] returns the file's text, or `null` when there is no
/// such sidecar (the common case) or it can't be read. It must **never throw** —
/// a missing or unreadable sidecar is just "no lyrics", never a failed lookup,
/// so the lyrics screen, the scan, and playback are never blocked by it.
abstract interface class LocalLyricsReader {
  /// The text of the sidecar with [extension] (e.g. `lrc`, `txt`) next to the
  /// track at [trackUri] (a `content://` SAF document or a file path/URI), or
  /// `null` when absent or unreadable.
  Future<String?> readSidecar(String trackUri, String extension);
}

/// The default [LocalLyricsReader] for platforms/builds with no sidecar support
/// (and tests): it reads nothing, so every local track resolves to "no lyrics"
/// and behaviour is unchanged. Mirrors [UnsupportedLocalMetadataReader].
class UnsupportedLocalLyricsReader implements LocalLyricsReader {
  const UnsupportedLocalLyricsReader();

  @override
  Future<String?> readSidecar(String trackUri, String extension) async => null;
}
