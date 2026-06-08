/// Why the most recent local-folder scan ended the way it did, recorded as a
/// failure *kind* (an enum name) — never a raw error string that could carry a
/// folder path, file name, or device detail.
enum LocalScanError {
  /// The selected folder could not be traversed through Android's Storage
  /// Access Framework (revoked grant, unresolvable provider, unreadable path).
  safTraversal,

  /// Any other unexpected scan failure (a `dart:io` fault, a plugin error).
  unexpected,
}

/// A secret-free snapshot of the last local-folder scan, so a bug report can
/// show *why* a scan turned up empty without revealing anything private.
///
/// Security: by construction this holds only booleans, counts, and a fixed
/// [LocalScanError] enum name. There is deliberately **no** field for the folder
/// path/URI, a file name, or a raw error message — the things that could leak a
/// user's library layout. This mirrors the "diagnostic, never secret" rule the
/// rest of the diagnostics utilities follow.
class LocalScanReport {
  const LocalScanReport({
    required this.folderSelected,
    required this.isContentUri,
    required this.filesVisited,
    required this.audioCandidates,
    required this.skippedUnsupported,
    required this.readFailures,
    this.error,
  });

  /// Builds a failure report (all counts zero) from what the caller knows about
  /// the selection — used when the scan threw before producing any counts.
  const LocalScanReport.failure({
    required this.folderSelected,
    required this.isContentUri,
    required LocalScanError this.error,
  })  : filesVisited = 0,
        audioCandidates = 0,
        skippedUnsupported = 0,
        readFailures = 0;

  /// Whether a music folder was selected at all when the scan ran.
  final bool folderSelected;

  /// Whether the selection was an Android SAF `content://` tree URI (vs a plain
  /// filesystem path). Tells a "no music found" report apart by storage kind.
  final bool isContentUri;

  /// How many non-directory entries the scan walked (audio and non-audio).
  final int filesVisited;

  /// How many of those entries were kept as playable audio candidates.
  final int audioCandidates;

  /// How many entries were skipped because they were not a recognized audio
  /// file (the usual `cover.jpg`/`notes.txt` case).
  final int skippedUnsupported;

  /// How many entries or subfolders could not be read and were skipped — the
  /// scoped-storage / removable-SD-card signal. A non-zero value with zero
  /// candidates points at a permission problem rather than an empty folder.
  final int readFailures;

  /// The failure kind when the scan threw, or null when it completed (even if it
  /// completed with zero candidates).
  final LocalScanError? error;

  bool get hadError => error != null;
}
