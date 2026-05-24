/// Where the audio the player is currently feeding the engine actually comes
/// from. Decoupled from any audio package and from the source layer so the UI
/// can show an honest "what am I hearing" badge without reaching into the
/// resolver, the cache, or Jellyfin.
///
/// The value is decided by the [PlayableUriResolver] at play time (a cache hit
/// is [offlineCache], a minted Jellyfin URL is [streamingDirect], an on-device
/// path is [localFile]) and carried on the player's state.
enum PlaybackSource {
  /// An on-device file (or Android SAF document) playing from its own path.
  localFile,

  /// A remote (Jellyfin/NAS) track streaming live from the authenticated
  /// session — no download required.
  streamingDirect,

  /// A remote track playing from its downloaded, on-disk copy.
  offlineCache;

  /// Short, all-caps badge text for the now-playing source indicator.
  String get label {
    switch (this) {
      case PlaybackSource.localFile:
        return 'LOCAL FILE';
      case PlaybackSource.streamingDirect:
        return 'STREAMING DIRECT';
      case PlaybackSource.offlineCache:
        return 'OFFLINE CACHE';
    }
  }
}
