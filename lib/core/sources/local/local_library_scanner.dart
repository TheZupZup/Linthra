import '../../models/track.dart';
import 'folder_location.dart';
import 'folder_scan_exception.dart';
import 'local_music_roots.dart';
import 'local_music_source.dart';
import 'local_scan_report.dart';

/// Scans one selected folder. [LocalMusicSource] is the production
/// implementation; tests pass a closure so the merge rules can be exercised
/// without a disk.
typedef LocalRootScan = Future<LocalScan> Function(String root);

/// What one selected folder contributed to a scan.
class LocalRootOutcome {
  const LocalRootOutcome({
    required this.root,
    required this.importedTracks,
    this.error,
    this.message,
  });

  /// The folder, as [LocalMusicRoots.canonicalize] spells it.
  final String root;

  /// Tracks this folder contributed — freshly scanned, or the ones kept from
  /// the previous scan when the folder could not be read.
  final int importedTracks;

  /// Why the folder could not be read, or null when it was read fine.
  final LocalScanError? error;

  /// The scanner's own user-facing explanation for the failure, when it had
  /// one. Shown as-is; it is not recorded in diagnostics, where only the
  /// [error] kind belongs.
  final String? message;

  bool get available => error == null;
}

/// The result of scanning every selected folder: one merged catalog for the
/// local source, plus what each folder did.
class LocalLibraryScan {
  const LocalLibraryScan({
    required this.tracks,
    required this.report,
    required this.roots,
    this.retentionUnavailable = false,
  });

  /// The complete local catalog to persist: every readable folder's tracks,
  /// plus the retained tracks of folders that were unreachable this time.
  final List<Track> tracks;

  final LocalScanReport report;
  final List<LocalRootOutcome> roots;

  /// Set when a folder was unreachable *and* the previously indexed tracks
  /// could not be read back, so the retained half of [tracks] is missing.
  /// Writing it would silently drop that folder's music, so callers must not.
  final bool retentionUnavailable;

  /// No folder could be read. Nothing new was learned, so the catalog should be
  /// left exactly as it is.
  bool get everyRootFailed =>
      roots.isNotEmpty && roots.every((LocalRootOutcome r) => !r.available);

  /// At least one folder could not be read.
  bool get hasUnavailableRoots =>
      roots.any((LocalRootOutcome r) => !r.available);

  /// The first failure's user-facing message, when a scanner gave one.
  String? get firstFailureMessage {
    for (final LocalRootOutcome outcome in roots) {
      if (!outcome.available && outcome.message != null) return outcome.message;
    }
    return null;
  }

  /// The folders that could not be read this time.
  List<String> get unavailableRoots => <String>[
        for (final LocalRootOutcome outcome in roots)
          if (!outcome.available) outcome.root,
      ];

  /// Whether writing [tracks] to the catalog is safe. A scan where nothing
  /// could be read, or where an unreachable folder's tracks could not be
  /// retained, must not overwrite what the user still has indexed.
  bool get isWritable => !everyRootFailed && !retentionUnavailable;
}

/// Scans the user's local music folders — one on Android, any number on
/// desktop — and merges them into the single catalog slice the local source
/// owns.
///
/// The merge is where multi-folder support actually lives, and it exists to
/// keep three promises:
///
///  * **No duplicates.** Folders are normalized first
///    ([LocalMusicRoots.normalize]), so a folder selected inside another one is
///    never walked twice. Tracks are then keyed by uri as a second guard, which
///    also collapses the same file reached through two different mounts.
///  * **One offline folder doesn't take the others down.** Each folder is
///    scanned independently; a missing drive or a revoked portal document fails
///    that folder alone, and its previously indexed tracks are carried over so
///    the user's library doesn't lose an album because a USB disk was
///    unplugged.
///  * **Removing a folder removes only its music.** Tracks that no selected
///    folder owns are simply not carried over, so a removed folder's tracks
///    disappear on the next scan while everything else stays.
class LocalLibraryScanner {
  const LocalLibraryScanner(this.scanRoot);

  final LocalRootScan scanRoot;

  /// Scans [roots] and merges the result.
  ///
  /// [previousTracks] is the local slice of the catalog as it stands, used to
  /// keep the tracks of folders that are temporarily unreachable. Pass null
  /// when it cannot be read: the scan then reports [
  /// LocalLibraryScan.retentionUnavailable] rather than quietly dropping that
  /// folder's music.
  Future<LocalLibraryScan> scan({
    required List<String> roots,
    List<Track>? previousTracks,
  }) async {
    final List<String> effective = LocalMusicRoots.normalize(roots);
    if (effective.isEmpty) {
      return const LocalLibraryScan(
        tracks: <Track>[],
        report: LocalScanReport(
          folderSelected: false,
          isContentUri: false,
          filesVisited: 0,
          audioCandidates: 0,
          skippedUnsupported: 0,
          readFailures: 0,
          rootsScanned: 0,
        ),
        roots: <LocalRootOutcome>[],
      );
    }

    // Insertion-ordered so the catalog keeps the user's folder order, and so
    // the first folder to claim a uri keeps it.
    final Map<String, Track> merged = <String, Track>{};
    final List<LocalScanReport> reports = <LocalScanReport>[];
    final List<LocalRootOutcome> outcomes = <LocalRootOutcome>[];
    bool retentionUnavailable = false;

    for (final String root in effective) {
      try {
        final LocalScan scan = await scanRoot(root);
        int imported = 0;
        for (final Track track in scan.tracks) {
          if (merged.containsKey(track.uri)) continue;
          merged[track.uri] = track;
          imported++;
        }
        reports.add(scan.report);
        outcomes.add(
          LocalRootOutcome(root: root, importedTracks: imported),
        );
      } catch (error) {
        final LocalScanError classified = classifyRootError(root, error);
        if (previousTracks == null) {
          retentionUnavailable = true;
          outcomes.add(
            LocalRootOutcome(
              root: root,
              importedTracks: 0,
              error: classified,
              message: error is FolderScanException ? error.message : null,
            ),
          );
          continue;
        }
        int retained = 0;
        for (final Track track in previousTracks) {
          if (LocalMusicRoots.ownerOf(track.uri, effective) != root) continue;
          if (merged.containsKey(track.uri)) continue;
          merged[track.uri] = track;
          retained++;
        }
        outcomes.add(
          LocalRootOutcome(
            root: root,
            importedTracks: retained,
            error: classified,
            message: error is FolderScanException ? error.message : null,
          ),
        );
      }
    }

    final int unavailable =
        outcomes.where((LocalRootOutcome o) => !o.available).length;
    final bool everyRootFailed = unavailable == outcomes.length;
    return LocalLibraryScan(
      tracks: merged.values.toList(growable: false),
      report: LocalScanReport.merged(
        reports,
        rootsScanned: effective.length,
        rootsUnavailable: unavailable,
        // A scan that read nothing is a failure the user has to act on; one
        // that read some folders is a partial result, and the counts plus
        // rootsUnavailable already say so.
        error: everyRootFailed
            ? outcomes.first.error ?? LocalScanError.unexpected
            : null,
      ),
      roots: outcomes,
      retentionUnavailable: retentionUnavailable,
    );
  }

  /// Turns a folder's scan failure into the recovery-shaped reason the UI
  /// shows. The kind of selection decides it: a SAF tree points at Android's
  /// folder chooser, the device library at Android's permission screen, and a
  /// filesystem path at reselecting the folder.
  static LocalScanError classifyRootError(String root, Object error) {
    final FolderLocation location = FolderLocation.parse(root);
    if (location.isAndroidMediaStore) {
      return error is FolderScanException && error.code == 'permission_denied'
          ? LocalScanError.mediaPermission
          : LocalScanError.unexpected;
    }
    if (error is! FolderScanException) return LocalScanError.unexpected;
    return location.isContentUri
        ? LocalScanError.safTraversal
        : LocalScanError.folderUnavailable;
  }
}
