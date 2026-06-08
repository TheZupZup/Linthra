/// One audio document discovered by walking an Android SAF tree.
///
/// Carries the `content://` document [uri] the platform can open, the display
/// [name] (with extension), and the provider-reported [mimeType] when known. The
/// name is kept because a bare content URI does not reliably expose a real title
/// or file type; the MIME type is kept so an audio file the platform recognises
/// by content (e.g. `audio/mpeg`) is still treated as audio even when its name
/// lacks a known extension — the catalog needs both signals to recognise audio.
class SafAudioDocument {
  const SafAudioDocument({
    required this.uri,
    required this.name,
    this.mimeType,
  });

  /// The `content://` document URI, openable by the platform and stable enough
  /// to use as a track id.
  final String uri;

  /// The document's display name, including its extension (e.g. `Song.flac`).
  final String name;

  /// The provider-reported MIME type (e.g. `audio/flac`), or null when the
  /// provider did not expose one.
  final String? mimeType;
}

/// The result of walking an Android SAF tree: the audio documents found plus
/// secret-free counters the diagnostics layer surfaces.
///
/// [filesVisited] counts every non-directory entry the walk saw (audio and
/// non-audio); [documents] are the audio ones; [readFailures] counts subfolders
/// whose listing failed and were skipped — the scoped-storage / removable-SD
/// signal that tells an empty result apart from a permission problem.
class SafScanResult {
  const SafScanResult({
    this.documents = const <SafAudioDocument>[],
    this.filesVisited = 0,
    this.readFailures = 0,
  });

  final List<SafAudioDocument> documents;
  final int filesVisited;
  final int readFailures;
}

/// Thrown when SAF document traversal is not available on this build/platform,
/// so the caller can fall back to the legacy path-resolution scanner instead of
/// surfacing an error. Deliberately distinct from a real traversal failure
/// (which is a `FolderScanException`).
class SafUnsupportedException implements Exception {
  const SafUnsupportedException();

  @override
  String toString() => 'SAF document traversal is not available here.';
}

/// Lists the audio documents under an Android SAF `content://` tree URI using
/// the platform content resolver — the scoped-storage-friendly way to read a
/// user-picked folder without any broad storage permission.
///
/// This is the seam that lets a content-URI folder actually be scanned. The
/// production binding is `MethodChannelSafDocumentLister` (Android only); tests
/// inject a fake. An implementation either:
///  - returns a [SafScanResult] for the tree (possibly with no documents), or
///  - throws [SafUnsupportedException] when traversal isn't available on this
///    build (the caller then falls back to filesystem path resolution), or
///  - throws a `FolderScanException` when traversal is available but fails.
abstract interface class SafDocumentLister {
  Future<SafScanResult> listAudioDocuments(String treeUri);
}

/// The default [SafDocumentLister] for platforms without native SAF traversal
/// (desktop, tests): it always reports SAF traversal unavailable, so the caller
/// falls back to the existing filesystem path scanner and behaviour there is
/// unchanged.
class UnsupportedSafDocumentLister implements SafDocumentLister {
  const UnsupportedSafDocumentLister();

  @override
  Future<SafScanResult> listAudioDocuments(String treeUri) async {
    throw const SafUnsupportedException();
  }
}
