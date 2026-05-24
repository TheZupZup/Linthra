import '../models/track.dart';

/// Looks up whether a track has a usable offline copy on disk.
///
/// The playback layer depends on this narrow, read-only seam to *prefer* a
/// cached file over streaming, without knowing how downloads are stored or
/// managed. Implementations return a path only when the bytes are actually
/// present, so a removed or reclaimed file transparently falls back to
/// streaming.
abstract interface class CachedTrackLocator {
  /// The absolute path to [track]'s cached file, or `null` when it isn't
  /// available offline (not downloaded, or the file is gone).
  Future<String?> cachedFilePath(Track track);
}
