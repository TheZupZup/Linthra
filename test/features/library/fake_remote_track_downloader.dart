import 'dart:async';

import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';

/// A plugin-free [RemoteTrackDownloader] for widget tests.
///
/// Treats any `jellyfin:` track as remote (mirroring the real Jellyfin
/// downloader) and returns canned bytes on fetch, so the Library row's
/// offline actions can be exercised without a server. A local (`file://`)
/// track stays local, exactly as in production.
class FakeRemoteTrackDownloader implements RemoteTrackDownloader {
  @override
  bool isRemote(Track track) => track.uri.startsWith('jellyfin:');

  @override
  Future<RemoteTrackDownload> open(Track track) async {
    return RemoteTrackDownload(
      chunks: Stream<List<int>>.value(<int>[1, 2, 3, 4]),
      contentLength: 4,
      fileExtension: 'mp3',
    );
  }
}
