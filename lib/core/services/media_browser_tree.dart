import 'package:flutter/foundation.dart';

import '../models/playback_state.dart';
import '../models/track.dart';
import '../repositories/music_library_repository.dart';

/// Stable media IDs for the browsable tree exposed to Android Auto and other
/// media browsers.
///
/// Category IDs are plain constants; leaf IDs encode where the item lives so a
/// later `playFromMediaId` can be resolved back to a track without extra state:
/// `library/<trackId>` is a catalog track, `queue/<index>` is a position in the
/// current play queue. The two namespaces never collide (`library` vs.
/// `library/...`).
abstract final class MediaId {
  /// The root the platform requests first (audio_service's `browsableRootId`).
  static const String root = 'root';
  static const String library = 'library';
  static const String queue = 'queue';

  static const String _libraryPrefix = 'library/';
  static const String _queuePrefix = 'queue/';

  static String libraryTrack(String trackId) => '$_libraryPrefix$trackId';
  static String queueItem(int index) => '$_queuePrefix$index';

  static bool isLibraryTrack(String id) => id.startsWith(_libraryPrefix);
  static bool isQueueItem(String id) => id.startsWith(_queuePrefix);

  static String libraryTrackId(String id) =>
      id.substring(_libraryPrefix.length);

  /// The queue position encoded in [id], or -1 when it isn't a valid number.
  static int queueIndex(String id) =>
      int.tryParse(id.substring(_queuePrefix.length)) ?? -1;
}

/// One node in the browsable media tree, kept free of any `audio_service` type.
///
/// Browsable nodes (categories) have [playable] `false`; track leaves have it
/// `true` and carry their [track] so the handler can build a rich media item
/// (artist, album, duration, artwork) without re-reading the catalog.
@immutable
class MediaNode {
  const MediaNode({
    required this.id,
    required this.title,
    this.subtitle,
    this.playable = false,
    this.track,
  });

  final String id;
  final String title;
  final String? subtitle;
  final bool playable;
  final Track? track;
}

/// What to play when a browsable item is selected: the [tracks] to load and the
/// [startIndex] within them to begin at. Mirrors [PlaybackController.playTracks]
/// so the rest of the queue becomes up-next, exactly like tapping a track in the
/// in-app library.
@immutable
class MediaPlaybackRequest {
  const MediaPlaybackRequest({required this.tracks, required this.startIndex});

  final List<Track> tracks;
  final int startIndex;
}

/// Builds the browsable media tree from the [MusicLibraryRepository] (catalog)
/// and a [PlaybackState] snapshot (the live queue), and resolves a selected
/// media ID back to a playback request.
///
/// Pure application logic with no audio backend: the handler maps its
/// [MediaNode]s onto `audio_service` media items and drives playback through the
/// [PlaybackController]. That keeps this fully testable with a fake repository.
class MediaBrowserTree {
  const MediaBrowserTree(this._library);

  final MusicLibraryRepository _library;

  /// The children of [parentId], for the given live [playback] snapshot.
  /// Unknown parents yield an empty list rather than throwing, so an unexpected
  /// browse request can never crash the media service.
  Future<List<MediaNode>> childrenOf(
    String parentId,
    PlaybackState playback,
  ) async {
    switch (parentId) {
      case MediaId.root:
        return _rootNodes;
      case MediaId.library:
        return _libraryNodes();
      case MediaId.queue:
        return _queueNodes(playback);
      default:
        return const <MediaNode>[];
    }
  }

  /// Resolves a selected leaf [mediaId] to what should play, or null when it
  /// doesn't name a playable track (e.g. a stale id, or a category).
  Future<MediaPlaybackRequest?> resolve(
    String mediaId,
    PlaybackState playback,
  ) async {
    if (MediaId.isLibraryTrack(mediaId)) {
      final tracks = await _library.getAllTracks();
      final trackId = MediaId.libraryTrackId(mediaId);
      final index = tracks.indexWhere((Track t) => t.id == trackId);
      if (index < 0) return null;
      return MediaPlaybackRequest(tracks: tracks, startIndex: index);
    }
    if (MediaId.isQueueItem(mediaId)) {
      final tracks = _currentQueue(playback);
      final index = MediaId.queueIndex(mediaId);
      if (index < 0 || index >= tracks.length) return null;
      return MediaPlaybackRequest(tracks: tracks, startIndex: index);
    }
    return null;
  }

  static const List<MediaNode> _rootNodes = <MediaNode>[
    MediaNode(id: MediaId.library, title: 'Library'),
    MediaNode(id: MediaId.queue, title: 'Queue'),
  ];

  Future<List<MediaNode>> _libraryNodes() async {
    final tracks = await _library.getAllTracks();
    return <MediaNode>[
      for (final Track track in tracks)
        _trackNode(MediaId.libraryTrack(track.id), track),
    ];
  }

  List<MediaNode> _queueNodes(PlaybackState playback) {
    final tracks = _currentQueue(playback);
    return <MediaNode>[
      for (int i = 0; i < tracks.length; i++)
        _trackNode(MediaId.queueItem(i), tracks[i]),
    ];
  }

  /// The full live queue as a flat list: the current track followed by up-next,
  /// matching the `queue/<index>` ids the queue nodes are built with.
  List<Track> _currentQueue(PlaybackState playback) {
    final current = playback.currentTrack;
    return <Track>[if (current != null) current, ...playback.upNext];
  }

  MediaNode _trackNode(String id, Track track) {
    return MediaNode(
      id: id,
      title: track.title,
      subtitle: _subtitle(track),
      playable: true,
      track: track,
    );
  }

  /// "Artist • Album", dropping whichever parts are missing.
  static String? _subtitle(Track track) {
    final parts = <String>[
      if (track.artistName != null && track.artistName!.isNotEmpty)
        track.artistName!,
      if (track.albumName != null && track.albumName!.isNotEmpty)
        track.albumName!,
    ];
    return parts.isEmpty ? null : parts.join(' • ');
  }
}
