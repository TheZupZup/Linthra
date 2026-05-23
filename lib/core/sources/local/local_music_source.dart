import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/track.dart';
import '../../services/local_playable_uri_resolver.dart';
import '../../services/music_source.dart';
import 'audio_file_scanner.dart';
import 'audio_file_types.dart';
import 'folder_location.dart';
import 'local_track_mapper.dart';
import 'saf_document_lister.dart';

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
  Future<List<Track>> fetchTracks() async {
    final String? folder = folderPath;
    if (folder == null || folder.isEmpty) {
      return const <Track>[];
    }
    if (FolderLocation.parse(folder).isContentUri) {
      return _fetchSafTracks(folder);
    }
    return _fetchFileTracks(await _scanner.listFiles(folder));
  }

  /// Walks an Android SAF tree through the content resolver. Falls back to the
  /// filesystem path scanner only when SAF traversal isn't available on this
  /// build (e.g. desktop); a genuine traversal failure propagates as a
  /// `FolderScanException`.
  Future<List<Track>> _fetchSafTracks(String folder) async {
    try {
      final List<SafAudioDocument> documents =
          await _safDocumentLister.listAudioDocuments(folder);
      final List<Track> tracks = <Track>[];
      for (final SafAudioDocument document in documents) {
        if (AudioFileTypes.isSupported(document.name)) {
          tracks.add(LocalTrackMapper.fromSafDocument(document));
        }
      }
      return tracks;
    } on SafUnsupportedException {
      return _fetchFileTracks(await _scanner.listFiles(folder));
    }
  }

  List<Track> _fetchFileTracks(List<String> files) {
    final List<Track> tracks = <Track>[];
    for (final String path in files) {
      if (AudioFileTypes.isSupported(path)) {
        tracks.add(LocalTrackMapper.fromPath(path));
      }
    }
    return tracks;
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
