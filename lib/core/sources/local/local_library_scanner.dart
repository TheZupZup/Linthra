import '../../models/local_file_stamp.dart';
import '../../models/track.dart';
import 'folder_location.dart';
import 'folder_scan_exception.dart';
import 'local_catalog_reconciliation.dart';
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
    this.reconciliation = LocalCatalogReconciliation.none,
  });

  /// The complete local catalog to persist: every readable folder's tracks,
  /// plus the retained tracks of folders that were unreachable this time.
  ///
  /// Each carries the on-disk stamp it was parsed at, when it has one, so the
  /// write records what a later scan will compare against. A retained track
  /// keeps the stamp it already had: the folder was not read, so nothing about
  /// it is newly known, and losing the stamp would mean re-parsing that whole
  /// folder the next time it *is* readable.
  final List<StampedTrack> tracks;

  /// The tracks alone, for the callers and assertions that do not care where
  /// the bytes were when they were parsed.
  List<Track> get plainTracks => <Track>[
        for (final StampedTrack stamped in tracks) stamped.track,
      ];

  final LocalScanReport report;
  final List<LocalRootOutcome> roots;

  /// Set when a folder was unreachable *and* the previously indexed tracks
  /// could not be read back, so the retained half of [tracks] is missing.
  /// Writing it would silently drop that folder's music, so callers must not.
  final bool retentionUnavailable;

  /// What happened to files the catalog knew about that a *readable* folder no
  /// longer holds: the ones that turned up at a new path with their identity
  /// proven, and the ones that are confirmed gone.
  ///
  /// [tracks] already reflects both (a moved file is in it under its new path,
  /// a deleted one is simply absent), so this is only for the state that lives
  /// outside the catalog and is keyed on the uri (play counts, hearts, "added
  /// on"). Empty when the caller passed no [LocalLibraryScanner.scan]
  /// `previousTracks`, since without them nothing can be compared.
  final LocalCatalogReconciliation reconciliation;

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
  /// [previousTracks] is the local slice of the catalog as it stands, with the
  /// on-disk stamp each row was written at. It does two jobs: keeping the
  /// tracks of folders that are temporarily unreachable, and giving
  /// [LocalLibraryScan.reconciliation] something to compare against so a file
  /// that changed path can be recognised as the same file. Pass null when it
  /// cannot be read: the scan then reports [
  /// LocalLibraryScan.retentionUnavailable] rather than quietly dropping that
  /// folder's music.
  Future<LocalLibraryScan> scan({
    required List<String> roots,
    List<StampedTrack>? previousTracks,
  }) async {
    final List<String> effective = LocalMusicRoots.normalize(roots);
    if (effective.isEmpty) {
      return const LocalLibraryScan(
        tracks: <StampedTrack>[],
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
    final Map<String, StampedTrack> merged = <String, StampedTrack>{};
    final List<LocalScanReport> reports = <LocalScanReport>[];
    final List<LocalRootOutcome> outcomes = <LocalRootOutcome>[];
    // The folders that actually answered. Only a file under one of these can
    // be called moved or deleted: the others were never looked at.
    final List<String> refreshedRoots = <String>[];
    bool retentionUnavailable = false;

    for (final String root in effective) {
      try {
        final LocalScan scan = await scanRoot(root);
        refreshedRoots.add(root);
        int imported = 0;
        for (final Track track in scan.tracks) {
          if (merged.containsKey(track.uri)) continue;
          merged[track.uri] = StampedTrack(
            track: track,
            stamp: scan.stamps[track.uri],
          );
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
        for (final StampedTrack stamped in previousTracks) {
          final String uri = stamped.track.uri;
          if (LocalMusicRoots.ownerOf(uri, effective) != root) continue;
          if (merged.containsKey(uri)) continue;
          // Stamp and all: this folder was not read, so nothing about these
          // files is newly known, and dropping the stamp would re-parse the
          // whole folder the next time it can be read.
          merged[uri] = stamped;
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
    final List<StampedTrack> tracks = merged.values.toList(growable: false);
    final List<Track> plainTracks = <Track>[
      for (final StampedTrack stamped in tracks) stamped.track,
    ];
    return LocalLibraryScan(
      tracks: tracks,
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
      // Only meaningful against a known previous state, and only worth
      // computing for a scan whose result may actually be written.
      reconciliation: previousTracks == null || everyRootFailed
          ? LocalCatalogReconciliation.none
          : LocalCatalogReconciliation.resolve(
              previous: <Track>[
                for (final StampedTrack stamped in previousTracks)
                  stamped.track,
              ],
              scanned: plainTracks,
              wasRefreshed: (String uri) =>
                  LocalMusicRoots.ownerOf(uri, refreshedRoots) != null,
            ),
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
