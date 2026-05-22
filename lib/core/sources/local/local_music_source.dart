import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/track.dart';
import '../../services/music_source.dart';
import 'audio_file_scanner.dart';
import 'audio_file_types.dart';
import 'local_track_mapper.dart';

/// A [MusicSource] that scans audio files already present on the device.
///
/// This is the first concrete source and the reference implementation of the
/// contract. It does no tag parsing yet: a scan walks [folderPath], keeps only
/// recognized audio files (see [AudioFileTypes]), and maps each one to a
/// [Track] via [LocalTrackMapper]. Album/artist grouping is therefore empty
/// until tag reading lands.
///
/// File-system access is delegated to an [AudioFileScanner] so the scanning
/// logic stays testable without a real disk.
class LocalMusicSource implements MusicSource {
  const LocalMusicSource({
    required this.folderPath,
    AudioFileScanner scanner = const IoAudioFileScanner(),
  }) : _scanner = scanner;

  /// Absolute path of the folder to scan, or `null` when the user has not
  /// chosen one yet — in which case scans simply return nothing.
  final String? folderPath;

  final AudioFileScanner _scanner;

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

    final List<String> files = await _scanner.listFiles(folder);
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
  Future<Uri?> resolvePlayableUri(Track track) async => Uri.file(track.uri);
}
