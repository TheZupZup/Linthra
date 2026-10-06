import 'package:path/path.dart' as p;

import '../../models/local_file_stamp.dart';
import '../../models/track.dart';
import 'audio_file_scanner.dart';
import 'folder_location.dart';
import 'folder_scan_exception.dart';
import 'local_catalog_reconciliation.dart';
import 'local_music_roots.dart';
import 'local_music_source.dart';
import 'local_root_fault.dart';
import 'local_scan_report.dart';
import 'local_track_identity.dart';

/// Scans one selected folder. [LocalMusicSource] is the production
/// implementation; tests pass a closure so the merge rules can be exercised
/// without a disk.
typedef LocalRootScan = Future<LocalScan> Function(String root);

/// Whether [path], inside the selected folder [root], is gone from where it
/// was: see `LocalFileAbsence.isGone`.
typedef LocalPathGone = Future<bool> Function(String path, String root);

/// What one selected folder contributed to a scan.
class LocalRootOutcome {
  const LocalRootOutcome({
    required this.root,
    required this.importedTracks,
    this.carriedOver = 0,
    this.error,
    this.fault,
    this.message,
  });

  /// The folder, as [LocalMusicRoots.canonicalize] spells it.
  final String root;

  /// Tracks this folder contributed: freshly scanned, plus the ones kept from
  /// the previous scan for whatever part of the folder, or all of it, could
  /// not be read.
  final int importedTracks;

  /// Of [importedTracks], the ones kept from a part of the folder the walk
  /// could not read, though the folder itself answered: nothing about their
  /// files was looked at this time.
  final int carriedOver;

  /// Why the folder could not be read, or null when it was read fine.
  final LocalScanError? error;

  /// The same failure in the shape the recovery UI needs: is the folder gone,
  /// is it unreadable, or is the storage behind it not answering? Null when the
  /// folder was read fine, and on a failure that named no kind.
  ///
  /// [error] says which *screen* recovers this (a folder chooser, Android's
  /// permission page); this says what to tell the user and which of Retry,
  /// Reselect and Remove leads the way out.
  final LocalRootFault? fault;

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
  /// plus the retained tracks of folders, or parts of folders, that were
  /// unreachable this time.
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

  /// Set when a folder, or part of one, was unreachable *and* the previously
  /// indexed tracks could not be read back, so the retained half of [tracks]
  /// is missing. Writing it would silently drop that music, so callers must
  /// not.
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

  /// The folders that could not be read, each with why. What availability
  /// tracking adopts, so the state the UI reads carries the diagnosis the scan
  /// already made instead of re-probing to guess at it.
  Map<String, LocalRootFault> get rootFaults => <String, LocalRootFault>{
        for (final LocalRootOutcome outcome in roots)
          if (!outcome.available)
            outcome.root: outcome.fault ?? LocalRootFault.unknown,
      };

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
///    unplugged. The same goes one level down: a subfolder the walk could not
///    list keeps what was indexed under it, while the rest of its folder is
///    refreshed.
///  * **Removing a folder removes only its music.** Tracks that no selected
///    folder owns are simply not carried over, so a removed folder's tracks
///    disappear on the next scan while everything else stays.
class LocalLibraryScanner {
  const LocalLibraryScanner(this.scanRoot, {this.isGone});

  final LocalRootScan scanRoot;

  /// Asks whether a file this scan could not see at its own path is gone
  /// from it, or null where nothing can answer (Android, and tests about
  /// something else): such files are then always kept until a later walk.
  final LocalPathGone? isGone;

  /// Scans [roots] and merges the result.
  ///
  /// [previousTracks] is the local slice of the catalog as it stands, with the
  /// on-disk stamp each row was written at. It does two jobs: keeping the
  /// tracks of folders, or parts of folders, that are temporarily unreachable,
  /// and giving [LocalLibraryScan.reconciliation] something to compare against
  /// so a file that changed path can be recognised as the same file. Pass null
  /// when it cannot be read: the scan then reports [
  /// LocalLibraryScan.retentionUnavailable] rather than quietly dropping that
  /// folder's music.
  ///
  /// A filesystem folder whose walk found no files at all, while the library
  /// has music from it, is not read as a folder that was emptied: it is what an
  /// unmounted drive or network share looks like when its mount point stays
  /// behind (#737). It is reported unavailable for [LocalRootFault.empty] and
  /// its music is kept, unless it is in [acceptEmpty], the folders the user has
  /// said really are empty.
  Future<LocalLibraryScan> scan({
    required List<String> roots,
    List<StampedTrack>? previousTracks,
    Set<String> acceptEmpty = const <String>{},
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
    // be called moved or deleted: the others were never looked at. Within
    // them, a file under a part the walk could not read is carried over below,
    // so it is never missing from the result either.
    final List<String> refreshedRoots = <String>[];
    bool retentionUnavailable = false;
    // Rows carried over for files this scan did not see at their own path,
    // in a folder it did read: listed and then unreadable, or under a
    // subfolder that stopped answering. See [_dropMovedAway].
    final Set<String> unseen = <String>{};

    final Set<String> confirmedEmpty = <String>{
      for (final String root in acceptEmpty) LocalMusicRoots.canonicalize(root),
    };
    for (final String root in effective) {
      try {
        final LocalScan scan = await scanRoot(root);
        if (scan.foundNoFiles &&
            scan.isComplete &&
            !confirmedEmpty.contains(root) &&
            _hadMusic(root, effective, previousTracks)) {
          // Raised like any folder that could not be read, so its music is
          // kept below the same way.
          throw rootFaultException(root, LocalRootFault.empty);
        }
        refreshedRoots.add(root);
        int imported = 0;
        int carriedOver = 0;
        for (final Track track in scan.tracks) {
          if (merged.containsKey(track.uri)) continue;
          merged[track.uri] = StampedTrack(
            track: track,
            stamp: scan.stamps[track.uri],
          );
          if (scan.vanished.contains(track.uri)) unseen.add(track.uri);
          imported++;
        }
        if (!scan.isComplete) {
          // The folder answered, but the walk could not read all of it, so it
          // returned only the part it reached. A file indexed under the rest
          // was not found, which is not the same as not there: it is kept,
          // stamp and all, exactly as for a folder that could not be read at
          // all. Without this, one subfolder that stopped answering would
          // delete every track indexed under it, and the artwork sweep after
          // the write would take their covers with them.
          if (previousTracks == null) {
            retentionUnavailable = true;
          } else {
            final bool Function(String uri) unread =
                _unreadPartOf(scan, root, effective);
            for (final StampedTrack stamped in previousTracks) {
              final String uri = stamped.track.uri;
              if (merged.containsKey(uri) || !unread(uri)) continue;
              merged[uri] = stamped;
              unseen.add(uri);
              imported++;
              carriedOver++;
            }
          }
        }
        reports.add(scan.report);
        outcomes.add(
          LocalRootOutcome(
            root: root,
            importedTracks: imported,
            carriedOver: carriedOver,
          ),
        );
      } catch (error) {
        final LocalScanError classified = classifyRootError(root, error);
        final LocalRootFault fault = classifyRootFault(error);
        if (previousTracks == null) {
          retentionUnavailable = true;
          outcomes.add(
            LocalRootOutcome(
              root: root,
              importedTracks: 0,
              error: classified,
              fault: fault,
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
            fault: fault,
            message: error is FolderScanException ? error.message : null,
          ),
        );
      }
    }

    final LocalPathGone? gone = isGone;
    if (gone != null && previousTracks != null && unseen.isNotEmpty) {
      await _dropMovedAway(
        merged,
        unseen: unseen,
        previousTracks: previousTracks,
        roots: effective,
        isGone: gone,
      );
    }

    final int unavailable =
        outcomes.where((LocalRootOutcome o) => !o.available).length;
    final bool everyRootFailed = unavailable == outcomes.length;
    // The first folder that could not be read. Its kind is what the diagnostics
    // line records, so a bug report says "permission_denied" rather than only
    // "the local scan failed".
    LocalRootFault? firstFault;
    for (final LocalRootOutcome outcome in outcomes) {
      if (outcome.available) continue;
      firstFault = outcome.fault;
      break;
    }
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
        fault: firstFault,
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

  /// Whether the library had music from the filesystem folder [root] before
  /// this scan. When the previous tracks could not be read it may have had,
  /// and an empty walk is then not taken as the music being gone either.
  static bool _hadMusic(
    String root,
    List<String> roots,
    List<StampedTrack>? previousTracks,
  ) {
    if (!FolderLocation.parse(root).isFilesystemPath) return false;
    if (previousTracks == null) return true;
    for (final StampedTrack stamped in previousTracks) {
      if (LocalMusicRoots.ownerOf(stamped.track.uri, roots) == root) {
        return true;
      }
    }
    return false;
  }

  /// Drops the rows in [unseen] whose file this same scan found at a new path,
  /// when the folder they were in now answers without them.
  ///
  /// A file moved while the walk runs can be listed at both paths: at the old
  /// one before the move, at the new one after it. The old path then cannot be
  /// read, and its row is kept, because a file that cannot be read is not
  /// known to be gone. Kept beside the file it is, though, the row outlives
  /// the move: the next scan finds the old path gone and the new one already
  /// indexed, with nothing left to match it to, and the file loses its heart,
  /// its play count and its "added on" date (or, for an album folder moved
  /// while the walk was inside the library, every track of it does).
  ///
  /// So a row goes here only when two things hold: a file with its identity
  /// ([LocalTrackIdentity]) turned up at a path this scan saw for the first
  /// time, and [isGone] answers that the old path is gone, which is the
  /// evidence a later walk would have. Both go into
  /// [LocalCatalogReconciliation.resolve] as usual, which matches them by the
  /// same rules as any move: an identity two files share is still no move.
  /// Without such a file the row stays, so a move to a folder the walk had
  /// already listed is still recognised by the next scan, as before. Without
  /// that evidence it stays too: a file on a drive that went away, or one that
  /// failed to read for a moment, beside a copy of it that is new, is not a
  /// move.
  static Future<void> _dropMovedAway(
    Map<String, StampedTrack> merged, {
    required Set<String> unseen,
    required List<StampedTrack> previousTracks,
    required List<String> roots,
    required LocalPathGone isGone,
  }) async {
    final Set<String> previousUris = <String>{
      for (final StampedTrack stamped in previousTracks) stamped.track.uri,
    };
    final Set<LocalTrackIdentity> appeared = <LocalTrackIdentity>{};
    for (final StampedTrack stamped in merged.values) {
      if (previousUris.contains(stamped.track.uri)) continue;
      final LocalTrackIdentity? identity = LocalTrackIdentity.of(stamped.track);
      if (identity != null) appeared.add(identity);
    }
    if (appeared.isEmpty) return;
    for (final String uri in unseen) {
      final StampedTrack? kept = merged[uri];
      if (kept == null) continue;
      final LocalTrackIdentity? identity = LocalTrackIdentity.of(kept.track);
      if (identity == null || !appeared.contains(identity)) continue;
      final String? root = LocalMusicRoots.ownerOf(uri, roots);
      if (root == null) continue;
      bool gone;
      try {
        gone = await isGone(uri, root);
      } catch (_) {
        gone = false;
      }
      if (gone) merged.remove(uri);
    }
  }

  /// Answers, for a track indexed before and missing from [scan], whether it
  /// sits under a part of [root] the walk could not read, so that not finding
  /// it says nothing about whether it is still there.
  ///
  /// The desktop walk names every subfolder it could not list, so only what is
  /// under those is kept, and the rest of the folder is refreshed as usual: a
  /// file deleted from a subfolder that was read still goes. No ownership
  /// check is needed there, since a named subfolder lies inside the walk of
  /// [root], and one would wrongly skip a SAF folder walked through its
  /// resolved path, whose tracks are paths that a `content://` selection never
  /// owns. Android's SAF walk only counts what it skipped, so any track [root]
  /// owns could be one it missed.
  static bool Function(String uri) _unreadPartOf(
    LocalScan scan,
    String root,
    List<String> roots,
  ) {
    // Spelled once per walk rather than once per indexed track, of which a
    // library can hold a hundred thousand.
    final List<String> directories = <String>[
      for (final String directory in scan.unreadableDirectories)
        LocalMusicRoots.canonicalize(directory),
    ];
    return (String uri) {
      if (scan.hasUnlocatedReadFailures &&
          LocalMusicRoots.ownerOf(uri, roots) == root) {
        return true;
      }
      // Only a path can sit under a folder; a `content://` uri never does.
      if (!p.isAbsolute(uri)) return false;
      for (final String directory in directories) {
        if (p.isWithin(directory, uri)) return true;
      }
      return false;
    };
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

  /// Turns a folder's scan failure into the recovery *state* the UI shows for
  /// that folder: gone, not permitted, or storage not answering.
  ///
  /// The scanner already classified it (a [FolderScanException] raised for a
  /// root carries the kind on its [FolderScanException.code]), so this is a
  /// lookup, not a second diagnosis, and the two can never disagree. A raw
  /// `dart:io` failure that reached here unwrapped is classified from its
  /// errno; anything else is [LocalRootFault.unknown], which is honest about
  /// the app not knowing rather than guessing.
  static LocalRootFault classifyRootFault(Object error) {
    if (error is FolderScanException) {
      return LocalRootFault.fromCode(error.code) ?? LocalRootFault.unknown;
    }
    return classifyFilesystemFault(error);
  }
}
