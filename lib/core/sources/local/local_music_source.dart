import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/track.dart';
import '../../services/local_playable_uri_resolver.dart';
import '../../services/music_source.dart';
import 'audio_file_scanner.dart';
import 'audio_file_types.dart';
import 'folder_location.dart';
import 'local_scan_report.dart';
import 'local_track_mapper.dart';
import 'saf_document_lister.dart';

/// The tracks a local scan discovered, paired with a secret-free
/// [LocalScanReport] describing what the scan saw (visited/candidates/skipped/
/// read-failure counts). The controller persists the [tracks] and records the
/// [report] for diagnostics.
class LocalScan {
  const LocalScan({required this.tracks, required this.report});

  final List<Track> tracks;
  final LocalScanReport report;
}

/// A [MusicSource] that scans audio files already present on the device.
///
/// This is the first concrete source and the reference implementation of the
/// contract. It does no tag parsing yet: a scan keeps only recognized audio
/// files (see [AudioFileTypes]) and maps each one to a [Track] via
/// [LocalTrackMapper]. Album/artist grouping is therefore empty until tag
/// reading lands.
///
/// Two storage strategies sit behind it, chosen by what the picker returned:
///  - a filesystem path (desktop/Linux, and any path Android hands back) is
///    walked by an [AudioFileScanner];
///  - an Android SAF `content://` tree URI is traversed through the content
///    resolver by a [SafDocumentLister], the scoped-storage-friendly path. When
///    that traversal isn't available on the build, it falls back to the
///    filesystem scanner so behaviour never regresses.
///
/// Both seams are injectable so scanning stays testable without a real disk,
/// device, or platform channel.
class LocalMusicSource implements MusicSource {
  const LocalMusicSource({
    required this.folderPath,
    AudioFileScanner scanner = const IoAudioFileScanner(),
    SafDocumentLister safDocumentLister = const UnsupportedSafDocumentLister(),
  })  : _scanner = scanner,
        _safDocumentLister = safDocumentLister;

  /// Absolute path or SAF tree URI of the folder to scan, or `null` when the
  /// user has not chosen one yet — in which case scans simply return nothing.
  final String? folderPath;

  final AudioFileScanner _scanner;
  final SafDocumentLister _safDocumentLister;

  @override
  String get id => 'local';

  @override
  String get displayName => 'On this device';

  @override
  Future<List<Track>> fetchTracks() async => (await scanTracks()).tracks;

  /// Scans the selected folder and returns the discovered [Track]s alongside a
  /// secret-free [LocalScanReport]. This is the richer entry point the library
  /// controller uses so it can both persist the tracks and record diagnostics;
  /// [fetchTracks] is the thin [MusicSource] view over it.
  ///
  /// A genuine traversal failure still throws a `FolderScanException` (the
  /// caller turns it into a clear message and an error report); an empty or
  /// permission-blocked folder instead returns an empty result whose report
  /// counts explain why.
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
        ),
      );
    }
    if (FolderLocation.parse(folder).isContentUri) {
      return _scanSaf(folder);
    }
    return _scanFiles(folder, isContentUri: false);
  }

  /// Walks an Android SAF tree through the content resolver. Falls back to the
  /// filesystem path scanner only when SAF traversal isn't available on this
  /// build (e.g. desktop); a genuine traversal failure propagates as a
  /// `FolderScanException`.
  Future<LocalScan> _scanSaf(String folder) async {
    try {
      final SafScanResult result =
          await _safDocumentLister.listAudioDocuments(folder);
      final List<Track> tracks = <Track>[];
      for (final SafAudioDocument document in result.documents) {
        // Accept either signal the provider offered — a known extension or an
        // `audio/*` MIME — so an audio file the platform recognised by content
        // type isn't dropped just because its name has no known extension.
        if (AudioFileTypes.isSupportedDocument(
          document.name,
          document.mimeType,
        )) {
          tracks.add(LocalTrackMapper.fromSafDocument(document));
        }
      }
      final int candidates = tracks.length;
      final int skipped = result.filesVisited > candidates
          ? result.filesVisited - candidates
          : 0;
      return LocalScan(
        tracks: tracks,
        report: LocalScanReport(
          folderSelected: true,
          isContentUri: true,
          filesVisited: result.filesVisited,
          audioCandidates: candidates,
          skippedUnsupported: skipped,
          readFailures: result.readFailures,
        ),
      );
    } on SafUnsupportedException {
      return _scanFiles(folder, isContentUri: true);
    }
  }

  Future<LocalScan> _scanFiles(
    String folder, {
    required bool isContentUri,
  }) async {
    final List<String> files = await _scanner.listFiles(folder);
    final List<Track> tracks = <Track>[];
    for (final String path in files) {
      if (AudioFileTypes.isSupported(path)) {
        tracks.add(LocalTrackMapper.fromPath(path));
      }
    }
    final int visited = files.length;
    final int candidates = tracks.length;
    return LocalScan(
      tracks: tracks,
      report: LocalScanReport(
        folderSelected: true,
        isContentUri: isContentUri,
        filesVisited: visited,
        audioCandidates: candidates,
        skippedUnsupported: visited - candidates,
        readFailures: 0,
      ),
    );
  }

  /// Empty until tag parsing exists: albums can't be grouped from file paths
  /// alone.
  @override
  Future<List<Album>> fetchAlbums() async => const <Album>[];

  /// Empty until tag parsing exists — see [fetchAlbums].
  @override
  Future<List<Artist>> fetchArtists() async => const <Artist>[];

  @override
  Future<Uri?> resolvePlayableUri(Track track) async =>
      LocalPlayableUriResolver.playableUriFor(track.uri);
}
