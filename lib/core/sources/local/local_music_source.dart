import '../../catalog/library_grouping.dart';
import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/local_file_stamp.dart';
import '../../models/track.dart';
import '../../services/local_playable_uri_resolver.dart';
import '../../services/music_source.dart';
import 'android_media_library.dart';
import 'audio_file_scanner.dart';
import 'audio_file_types.dart';
import 'folder_location.dart';
import 'local_audio_metadata.dart';
import 'local_file_stat.dart';
import 'local_metadata_reader.dart';
import 'local_scan_report.dart';
import 'local_track_mapper.dart';
import 'saf_document_lister.dart';

/// The tracks a local scan discovered, paired with a secret-free
/// [LocalScanReport] describing what the scan saw.
class LocalScan {
  const LocalScan({
    required this.tracks,
    required this.report,
    this.stamps = const <String, LocalFileStamp>{},
    this.unreadableDirectories = const <String>[],
    this.hasUnlocatedReadFailures = false,
    this.vanished = const <String>{},
  });

  final List<Track> tracks;
  final LocalScanReport report;

  /// What each discovered file looked like on disk, keyed by [Track.uri].
  ///
  /// Empty for the sources that have no such thing: Android SAF documents and
  /// MediaStore rows, and any scan running without a [LocalFileStatReader].
  /// A track missing from here is stored with no stamp, and a track with no
  /// stamp is re-parsed on the next scan, which is what scanning did before
  /// incremental scans existed.
  final Map<String, LocalFileStamp> stamps;

  /// The subfolders the walk could not list, as absolute paths.
  ///
  /// A file under one of these is missing from [tracks] because the walk never
  /// saw it, not because it is gone, so the files indexed under them are kept
  /// rather than removed. Empty when the walk read everything, and for a walk
  /// that cannot name what it missed (see [hasUnlocatedReadFailures]).
  final List<String> unreadableDirectories;

  /// The walk could not read part of the folder and cannot say which part.
  ///
  /// Android's SAF walk counts the subfolders it could not list (a card pulled
  /// mid-walk, a provider that stopped answering) but does not name them, so
  /// any file indexed under this folder could be one it missed, and all of
  /// them are kept until a walk reads the whole folder again.
  final bool hasUnlocatedReadFailures;

  /// The files the walk listed that could then be neither stat'ed nor read,
  /// whose rows were kept as they were (they are in [tracks] under their old
  /// path). The walk saw them, and then they were not there to read: moved or
  /// deleted while the scan ran, or on a drive that went away.
  final Set<String> vanished;

  /// Whether the walk read the whole folder, so that a file it did not return
  /// is really gone.
  bool get isComplete =>
      unreadableDirectories.isEmpty && !hasUnlocatedReadFailures;
}

/// A [MusicSource] that scans audio files already present on the device.
///
/// Three storage strategies sit behind it:
///  - filesystem paths on desktop/Linux;
///  - Android SAF `content://` trees for a targeted folder grant;
///  - Android MediaStore when the user explicitly selects "All music on this
///    device" and grants the normal Music and audio runtime permission.
///
/// Every seam is injectable so scanning stays testable without a real disk,
/// device, permission dialog, or platform channel.
class LocalMusicSource implements MusicSource {
  const LocalMusicSource({
    required this.folderPath,
    AudioFileScanner scanner = const IoAudioFileScanner(),
    SafDocumentLister safDocumentLister = const UnsupportedSafDocumentLister(),
    AndroidMediaLibrary androidMediaLibrary =
        const UnsupportedAndroidMediaLibrary(),
    LocalMetadataReader metadataReader = const UnsupportedLocalMetadataReader(),
    LocalFileStatReader statReader = const UnsupportedLocalFileStatReader(),
    Map<String, StampedTrack> alreadyIndexed = const <String, StampedTrack>{},
    Set<Uri> missingArtwork = const <Uri>{},
  })  : _scanner = scanner,
        _safDocumentLister = safDocumentLister,
        _androidMediaLibrary = androidMediaLibrary,
        _metadataReader = metadataReader,
        _statReader = statReader,
        _alreadyIndexed = alreadyIndexed,
        _missingArtwork = missingArtwork;

  /// Filesystem path, SAF tree URI, [FolderLocation.androidMediaStoreAudio], or
  /// null when the user has not configured local music.
  final String? folderPath;

  final AudioFileScanner _scanner;
  final SafDocumentLister _safDocumentLister;
  final AndroidMediaLibrary _androidMediaLibrary;
  final LocalMetadataReader _metadataReader;

  /// Reads the size and mtime an incremental scan compares against what was
  /// stored. The default reads nothing, so every file is parsed: a scan that
  /// was not handed a stat reader behaves exactly as scans did before
  /// incremental scans existed.
  final LocalFileStatReader _statReader;

  /// What the catalog already holds for this source, keyed by file path, so a
  /// file whose stamp is unchanged can be carried over without being opened.
  /// Empty means "nothing is known", which parses everything: the safe default,
  /// and the one a full rescan asks for.
  final Map<String, StampedTrack> _alreadyIndexed;

  /// Covers that rows in [_alreadyIndexed] point at and that the reader's
  /// artwork cache no longer holds (see [LocalArtworkInventory]). A row whose
  /// cover is one of these is not reused even when its file is unchanged: the
  /// file is read again, which is what brings the cover back.
  final Set<Uri> _missingArtwork;

  @override
  String get id => 'local';

  @override
  String get displayName => 'Local music';

  @override
  Future<List<Track>> fetchTracks() async => (await scanTracks()).tracks;

  Future<LocalScan> scanTracks() async {
    final String? folder = folderPath;
    if (folder == null || folder.isEmpty) {
      return const LocalScan(
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
      );
    }

    final FolderLocation location = FolderLocation.parse(folder);
    if (location.isAndroidMediaStore) {
      return _scanAndroidMediaStore();
    }
    if (location.isContentUri) {
      return _scanSaf(folder);
    }
    return _scanFiles(folder, isContentUri: false);
  }

  Future<LocalScan> _scanAndroidMediaStore() async {
    final SafScanResult result = await _androidMediaLibrary.listDeviceAudio();
    return _scanDocuments(result, isContentUri: false, isDeviceLibrary: true);
  }

  /// Walks an Android SAF tree through the content resolver. Falls back to the
  /// filesystem path scanner only when SAF traversal isn't available here.
  Future<LocalScan> _scanSaf(String folder) async {
    try {
      final SafScanResult result =
          await _safDocumentLister.listAudioDocuments(folder);
      return _scanDocuments(result, isContentUri: true);
    } on SafUnsupportedException {
      return _scanFiles(folder, isContentUri: true);
    }
  }

  /// Turns content-resolver rows (SAF or MediaStore) into local tracks using the
  /// same mapper, so title/artist/album/duration/track-number behavior stays
  /// identical across Android's two local-library modes.
  LocalScan _scanDocuments(
    SafScanResult result, {
    required bool isContentUri,
    bool isDeviceLibrary = false,
  }) {
    final List<Track> tracks = <Track>[];
    for (final SafAudioDocument document in result.documents) {
      if (AudioFileTypes.isSupportedDocument(
        document.name,
        document.mimeType,
      )) {
        tracks.add(LocalTrackMapper.fromSafDocument(document));
      }
    }
    final int candidates = result.documents.length;
    final int imported = tracks.length;
    final int skipped =
        result.filesVisited > candidates ? result.filesVisited - candidates : 0;
    return LocalScan(
      tracks: tracks,
      // The native walk sends back how many subfolders it skipped, not which,
      // so nothing it did not return may be called deleted. MediaStore always
      // reports none: it answers a query and walks no folders.
      hasUnlocatedReadFailures: result.readFailures > 0,
      report: LocalScanReport(
        folderSelected: true,
        isContentUri: isContentUri,
        isDeviceLibrary: isDeviceLibrary,
        filesVisited: result.filesVisited,
        foldersVisited: result.foldersVisited,
        audioCandidates: candidates,
        importedTracks: imported,
        skippedUnsupported: skipped,
        readFailures: result.readFailures,
      ),
    );
  }

  /// Walks [folder] and turns every supported file into a track, **parsing
  /// only the ones that are not already indexed exactly as they are on disk**.
  ///
  /// The incremental rule is one comparison. Each candidate is stat'ed (one
  /// syscall) for its size and mtime; if the catalog already holds a track for
  /// that path with the identical stamp, the stored track is reused verbatim
  /// and its tags are never read again. Anything else falls through to the full
  /// parse: a new file, a file whose size or mtime moved, a file the stat
  /// failed on, a file whose cover the artwork cache no longer holds, and
  /// every file at all when nothing was handed in (the full-rescan path, and
  /// every platform without a stat reader).
  ///
  /// Reuse is deliberately *verbatim*. The stored track was built by this same
  /// mapper, from this same path, under this same root, so rebuilding it would
  /// produce the same object with more work; and reusing it is what keeps a
  /// rescan from touching rows that did not change.
  Future<LocalScan> _scanFiles(
    String folder, {
    required bool isContentUri,
  }) async {
    final List<String> unreadable = <String>[];
    final List<String> files = await _scanner.listFiles(
      folder,
      onUnreadableDirectory: unreadable.add,
    );
    final List<Track> tracks = <Track>[];
    final Map<String, LocalFileStamp> stamps = <String, LocalFileStamp>{};
    final Set<String> vanished = <String>{};
    int reused = 0;
    for (final String path in files) {
      if (!AudioFileTypes.isSupported(path)) continue;
      final LocalFileStamp? stamp = await _statReader.stamp(path);
      if (stamp != null) stamps[path] = stamp;

      final StampedTrack? indexed = _alreadyIndexed[path];
      if (stamp != null &&
          indexed != null &&
          !stamp.differsFrom(indexed.stamp) &&
          !_missingArtwork.contains(indexed.track.artworkUri)) {
        tracks.add(indexed.track);
        reused++;
        continue;
      }

      final LocalMetadataRead read = await _readTags(path);
      final LocalAudioMetadata? metadata = read.metadata;
      // Listed by the walk, but now it can be neither stat'ed nor read: the
      // drive went away, or the file was moved, after the walk got to it.
      // That says nothing about its tags, so the row already indexed for it
      // stays as it was rather than being rebuilt from the file name (which
      // would lose its tags, its cover, and the identity a move is matched
      // by). Still unknown, so no stamp: the next scan parses it again, and
      // if the file really is gone, the next walk drops it.
      if (metadata == null && stamp == null && indexed != null) {
        tracks.add(indexed.track);
        vanished.add(path);
        reused++;
        continue;
      }
      // Unchanged since its row was written, and read again only because the
      // artwork cache no longer holds its cover. A read of those same bytes
      // that failed this time (a drive answering with an I/O error, a parse
      // that ran out of time) says nothing about the tags the row was built
      // from, so the row stays as it was, cover reference included, and the
      // next scan asks for the cover again. Rebuilt from the file name, it
      // would lose its tags for good: an unchanged file is never read again.
      if (metadata == null &&
          stamp != null &&
          indexed != null &&
          !stamp.differsFrom(indexed.stamp)) {
        tracks.add(indexed.track);
        continue;
      }
      // New or changed, and it could not be read this time: a network share
      // stalling past the parse limit, an I/O error. Its row is built from the
      // file name as ever, but stored without its stamp. With it, every later
      // scan would reuse that row as it is, and the tags would never come back
      // short of a full rescan (#743). Without it, the next scan reads the
      // file again. Only once in a row: a file whose row already has no stamp
      // (most likely a read that failed last time too) keeps its stamp now, so
      // a file that can never be read, one the parser loops on, costs one
      // more read rather than one every scan.
      if (read.failed &&
          stamp != null &&
          !(indexed != null && indexed.stamp == null)) {
        stamps.remove(path);
      }
      tracks.add(LocalTrackMapper.fromPath(
        path,
        metadata: metadata,
        scanRoot: folder,
      ));
    }
    final int visited = files.length;
    final int candidates = tracks.length;
    return LocalScan(
      tracks: tracks,
      stamps: stamps,
      unreadableDirectories: List<String>.unmodifiable(unreadable),
      vanished: Set<String>.unmodifiable(vanished),
      report: LocalScanReport(
        folderSelected: true,
        isContentUri: isContentUri,
        filesVisited: visited,
        foldersVisited: 0,
        audioCandidates: candidates,
        importedTracks: candidates,
        reusedTracks: reused,
        skippedUnsupported: visited - candidates,
        // Counted the way the SAF walk counts them, so the Settings card and
        // the diagnostics line say "unreadable" on desktop too.
        readFailures: unreadable.length,
      ),
    );
  }

  /// [path]'s tags, and whether a null is a failed read. A reader that can't
  /// tell ([LocalMetadataReadOutcomes]) answers with no tags.
  Future<LocalMetadataRead> _readTags(String path) async {
    final LocalMetadataReader reader = _metadataReader;
    if (reader is LocalMetadataReadOutcomes) {
      return (reader as LocalMetadataReadOutcomes).readWithOutcome(path);
    }
    return (metadata: await reader.readFromPath(path), failed: false);
  }

  @override
  Future<List<Album>> fetchAlbums() async => groupAlbums(await fetchTracks());

  @override
  Future<List<Artist>> fetchArtists() async =>
      groupArtists(await fetchTracks());

  @override
  Future<Uri?> resolvePlayableUri(Track track) async =>
      LocalPlayableUriResolver.playableUriFor(track.uri);
}
