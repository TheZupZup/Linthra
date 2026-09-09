/// Why the most recent local-folder scan ended the way it did, recorded as a
/// failure *kind* (an enum name) — never a raw error string that could carry a
/// folder path, file name, or device detail.
enum LocalScanError {
  /// The selected folder could not be traversed through Android's Storage
  /// Access Framework (revoked grant, unresolvable provider, unreadable path).
  safTraversal,

  /// Android's device-wide Music and audio / MediaStore access is unavailable
  /// or revoked. This is distinct from SAF because the recovery action is the
  /// normal Android app-permission screen, not re-picking a folder.
  mediaPermission,

  /// The selected folder itself could not be opened on a filesystem scan: it
  /// is missing, unreadable, or (in the Flatpak) the portal document that
  /// exposed it was revoked. Recoverable by reselecting the folder.
  folderUnavailable,

  /// Any other unexpected scan failure (a `dart:io` fault, a plugin error).
  unexpected,
}

/// A secret-free snapshot of the last local-folder scan, so a bug report can
/// show *why* a scan turned up empty without revealing anything private.
class LocalScanReport {
  const LocalScanReport({
    required this.folderSelected,
    required this.isContentUri,
    required this.filesVisited,
    required this.audioCandidates,
    required this.skippedUnsupported,
    required this.readFailures,
    this.foldersVisited = 0,
    this.importedTracks = 0,
    this.recursive = true,
    this.isDeviceLibrary = false,
    this.rootsScanned = 1,
    this.rootsUnavailable = 0,
    this.error,
  }) : assert(
          !(isContentUri && isDeviceLibrary),
          'a scan reads either a SAF tree or the device library, never both',
        );

  /// Builds a failure report (all counts zero) from what the caller knows about
  /// the selection — used when the scan threw before producing any counts.
  const LocalScanReport.failure({
    required this.folderSelected,
    required this.isContentUri,
    required LocalScanError this.error,
    this.isDeviceLibrary = false,
    this.rootsScanned = 1,
    this.rootsUnavailable = 1,
  })  : filesVisited = 0,
        foldersVisited = 0,
        audioCandidates = 0,
        importedTracks = 0,
        skippedUnsupported = 0,
        readFailures = 0,
        recursive = true,
        assert(
          !(isContentUri && isDeviceLibrary),
          'a scan reads either a SAF tree or the device library, never both',
        );

  /// Sums the per-folder reports of one multi-folder scan into the single
  /// report the UI and diagnostics read.
  ///
  /// Counts add up across folders. The kind flags only survive when every
  /// folder agreed on them, because a mixed scan is neither "a SAF tree" nor
  /// "the device library" and recovery advice written for those would be wrong.
  /// [error] is meant for a scan that produced nothing usable: a scan where
  /// some folders were read and others were not is not an error, it is a
  /// partial result, and [rootsUnavailable] is what says so.
  factory LocalScanReport.merged(
    List<LocalScanReport> reports, {
    required int rootsScanned,
    required int rootsUnavailable,
    LocalScanError? error,
  }) {
    int sum(int Function(LocalScanReport report) field) =>
        reports.fold(0, (int total, LocalScanReport r) => total + field(r));
    final bool allContentUri = reports.isNotEmpty &&
        reports.every((LocalScanReport r) => r.isContentUri);
    final bool allDeviceLibrary = reports.isNotEmpty &&
        reports.every((LocalScanReport r) => r.isDeviceLibrary);
    return LocalScanReport(
      folderSelected: rootsScanned > 0,
      isContentUri: allContentUri && !allDeviceLibrary,
      isDeviceLibrary: allDeviceLibrary,
      filesVisited: sum((LocalScanReport r) => r.filesVisited),
      foldersVisited: sum((LocalScanReport r) => r.foldersVisited),
      audioCandidates: sum((LocalScanReport r) => r.audioCandidates),
      importedTracks: sum((LocalScanReport r) => r.importedTracks),
      skippedUnsupported: sum((LocalScanReport r) => r.skippedUnsupported),
      readFailures: sum((LocalScanReport r) => r.readFailures),
      rootsScanned: rootsScanned,
      rootsUnavailable: rootsUnavailable,
      error: error,
    );
  }

  final bool folderSelected;
  final bool isContentUri;

  /// Whether this scan read Android's device-wide MediaStore library rather
  /// than a folder. MediaStore reads no content-URI *tree* and walks no
  /// directories, so without this flag its reports are indistinguishable from a
  /// plain filesystem scan: the diagnostics line would call it `kind=path`, and
  /// recovery text would send the user to a folder chooser for a source that is
  /// not a folder.
  final bool isDeviceLibrary;
  final int filesVisited;
  final int foldersVisited;
  final int audioCandidates;
  final int importedTracks;
  final int skippedUnsupported;
  final int readFailures;
  final bool recursive;

  /// How many selected folders this scan covered. One on Android and for a
  /// single-folder desktop library; zero when nothing is selected.
  final int rootsScanned;

  /// How many of those folders could not be read — unmounted drive, revoked
  /// portal document, deleted directory. Their previously indexed tracks are
  /// kept, so this is a "some music may be missing right now" signal, not a
  /// failure, unless [error] is also set.
  final int rootsUnavailable;

  final LocalScanError? error;

  bool get hadError => error != null;

  /// Some folders were read and others were not. The catalog is up to date for
  /// the folders that answered and unchanged for the ones that did not.
  bool get isPartial => error == null && rootsUnavailable > 0;

  /// How many folders this scan actually read.
  int get rootsAvailable => rootsScanned - rootsUnavailable;
}
