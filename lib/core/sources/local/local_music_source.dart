import '../../catalog/library_grouping.dart';
import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/track.dart';
import '../../services/local_playable_uri_resolver.dart';
import '../../services/music_source.dart';
import 'android_media_library.dart';
import 'audio_file_scanner.dart';
import 'audio_file_types.dart';
import 'folder_location.dart';
import 'local_audio_metadata.dart';
import 'local_metadata_reader.dart';
import 'local_scan_report.dart';
import 'local_track_mapper.dart';
import 'saf_document_lister.dart';

/// The tracks a local scan discovered, paired with a secret-free
/// [LocalScanReport] describing what the scan saw.
class LocalScan {
  const LocalScan({required this.tracks, required this.report});

  final List<Track> tracks;
  final LocalScanReport report;
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
  })  : _scanner = scanner,
        _safDocumentLister = safDocumentLister,
        _androidMediaLibrary = androidMediaLibrary,
        _metadataReader = metadataReader;

  /// Filesystem path, SAF tree URI, [FolderLocation.androidMediaStoreAudio], or
  /// null when the user has not configured local music.
  final String? folderPath;

  final AudioFileScanner _scanner;
  final SafDocumentLister _safDocumentLister;
  final AndroidMediaLibrary _androidMediaLibrary;
  final LocalMetadataReader _metadataReader;

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

  Future<LocalScan> _scanFiles(
    String folder, {
    required bool isContentUri,
  }) async {
    final List<String> files = await _scanner.listFiles(folder);
    final List<Track> tracks = <Track>[];
    for (final String path in files) {
      if (AudioFileTypes.isSupported(path)) {
        final LocalAudioMetadata? metadata =
            await _metadataReader.readFromPath(path);
        tracks.add(LocalTrackMapper.fromPath(
          path,
          metadata: metadata,
          scanRoot: folder,
        ));
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
        foldersVisited: 0,
        audioCandidates: candidates,
        importedTracks: candidates,
        skippedUnsupported: visited - candidates,
        readFailures: 0,
      ),
    );
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
