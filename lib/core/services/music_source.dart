import '../models/album.dart';
import '../models/artist.dart';
import '../models/track.dart';

/// A backend that *provides* media to Halcyon.
///
/// This is the core extension point for the project's roadmap. The MVP ships a
/// `LocalMusicSource` (scans on-device files); future `JellyfinMusicSource`,
/// `WebDavMusicSource`, and NAS sources implement this same contract. Nothing
/// in the UI or storage layers should depend on a concrete source — only on
/// this interface — which is what keeps the app vendor-lock-in free.
///
/// A source's job is discovery and resolution. Persisting the results into the
/// local SQLite cache is the [MusicLibraryRepository]'s responsibility, not the
/// source's, so that offline-first behavior stays centralized.
abstract interface class MusicSource {
  /// Stable identifier for this source, e.g. `'local'` or `'jellyfin:<id>'`.
  String get id;

  /// Human-readable name for settings/UI, e.g. "On this device".
  String get displayName;

  Future<List<Track>> fetchTracks();
  Future<List<Album>> fetchAlbums();
  Future<List<Artist>> fetchArtists();

  /// Resolves a [Track] to a URI the audio backend can actually open.
  ///
  /// For local files this is typically a no-op returning the file path; for
  /// remote sources it may mint a streaming/auth'd URL or return the path to a
  /// previously downloaded copy when offline.
  Future<Uri?> resolvePlayableUri(Track track);
}
