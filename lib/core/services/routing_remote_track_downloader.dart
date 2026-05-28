import '../models/track.dart';
import 'remote_track_downloader.dart';

/// A [RemoteTrackDownloader] that delegates to the first member that recognizes
/// a track as its own, so multiple remote sources (Jellyfin, Subsonic/Navidrome)
/// can be downloaded for offline use through one downloader.
///
/// Mirrors `RoutingPlayableUriResolver`/`RoutingCastMediaResolver`: each source
/// contributes its own downloader, composed here. [isRemote] is true when any
/// member claims the track; [open] uses the first member that does. An
/// on-device track (no member claims it) reports `isRemote == false`, so the
/// download policy skips it — it is already local.
class RoutingRemoteTrackDownloader implements RemoteTrackDownloader {
  RoutingRemoteTrackDownloader(this._downloaders);

  final List<RemoteTrackDownloader> _downloaders;

  @override
  bool isRemote(Track track) =>
      _downloaders.any((RemoteTrackDownloader d) => d.isRemote(track));

  @override
  Future<RemoteTrackDownload> open(Track track) async {
    for (final RemoteTrackDownloader downloader in _downloaders) {
      if (downloader.isRemote(track)) {
        return downloader.open(track);
      }
    }
    throw StateError('No remote downloader can fetch this track.');
  }
}
