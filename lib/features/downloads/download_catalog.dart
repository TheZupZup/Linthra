import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/models/track.dart';
import '../../core/repositories/download_repository.dart';
import '../../core/repositories/download_store.dart';

/// A track that is in flight or needs attention — queued, downloading, or
/// failed — paired with its live status.
typedef ActiveDownload = ({Track track, DownloadStatus status});

/// The download status map joined with the catalog tracks it is about: what
/// the Downloads screen lists.
@immutable
class DownloadCatalog {
  const DownloadCatalog({required this.downloaded, required this.active});

  /// The catalog tracks fully available offline, in catalog order.
  final List<Track> downloaded;

  /// The catalog tracks queued, downloading or failed, ordered downloading →
  /// queued → failed (then by id), so active work sits on top and the order is
  /// stable.
  final List<ActiveDownload> active;
}

/// Joins every status map from [statuses] with the catalog, reading it
/// ([readCatalog]) only when a map holds a key the last read was not done for.
///
/// Reading the catalog is a full table read, and status maps come in bursts:
/// "Download all" on a 500-song playlist is about 1,500 of them. Reading it
/// for each one, on a large library, mapped the whole catalog on the UI
/// isolate a thousand times over, and the Downloads branch stays mounted once
/// opened, so it went on after leaving the screen (#746). Here a track's walk
/// from queued to downloading to downloaded costs one read, when its key first
/// shows up, and a batch queued at once costs one between them. Maps that
/// arrive while a read is out are coalesced: only the latest is joined once it
/// lands. The first map is always read for, so a catalog that can't be read
/// says so even with nothing downloaded.
///
/// A list that comes out the same as last time is the same instance, so a
/// status change that moves nothing on screen (a queued track starting, for
/// the finished list) rebuilds nothing.
///
/// The tracks the keys resolved to are kept until the next read, which a new
/// key brings, so a song renamed by a sync shows its old title until then. A
/// key the catalog doesn't have is not read for again either: it stays off the
/// lists, as it always did, until the status map gains another key.
Stream<DownloadCatalog> joinDownloadsWithCatalog(
  Stream<Map<String, DownloadStatus>> statuses,
  Future<List<Track>> Function() readCatalog,
) {
  late final StreamController<DownloadCatalog> out;
  StreamSubscription<Map<String, DownloadStatus>>? subscription;
  Map<String, DownloadStatus>? pending;
  bool joining = false;
  // Nobody listens any more: drop whatever is in flight.
  bool cancelled = false;
  // The statuses ended: close once the last of them is joined.
  bool ended = false;

  // What the last read was for, and what it found for those keys, in catalog
  // order. Null until the first read.
  Set<String>? readFor;
  Map<String, Track> tracksByKey = const <String, Track>{};
  List<Track> downloaded = const <Track>[];
  Set<String> downloadedKeys = const <String>{};
  List<ActiveDownload> active = const <ActiveDownload>[];
  Map<String, DownloadStatus> activeStatuses = const <String, DownloadStatus>{};

  DownloadCatalog join(Map<String, DownloadStatus> statuses, bool reread) {
    final Set<String> nowDownloaded = <String>{
      for (final MapEntry<String, DownloadStatus> e in statuses.entries)
        if (e.value == DownloadStatus.downloaded) e.key,
    };
    if (reread || !setEquals(nowDownloaded, downloadedKeys)) {
      downloadedKeys = nowDownloaded;
      downloaded = <Track>[
        for (final MapEntry<String, Track> e in tracksByKey.entries)
          if (nowDownloaded.contains(e.key)) e.value,
      ];
    }
    // notDownloaded is never in the map, so "not downloaded *yet*" is exactly
    // queued/downloading/failed.
    final Map<String, DownloadStatus> nowActive = <String, DownloadStatus>{
      for (final MapEntry<String, DownloadStatus> e in statuses.entries)
        if (e.value != DownloadStatus.downloaded) e.key: e.value,
    };
    if (reread || !mapEquals(nowActive, activeStatuses)) {
      activeStatuses = nowActive;
      active = <ActiveDownload>[
        for (final MapEntry<String, DownloadStatus> e in nowActive.entries)
          if (tracksByKey[e.key] case final Track track)
            (track: track, status: e.value),
      ]..sort(_compareActiveDownloads);
    }
    return DownloadCatalog(downloaded: downloaded, active: active);
  }

  Future<void> drain() async {
    if (joining) return;
    joining = true;
    try {
      while (!cancelled) {
        Map<String, DownloadStatus>? next = pending;
        if (next == null) break;
        pending = null;
        bool reread = false;
        final Set<String>? known = readFor;
        if (known == null || !known.containsAll(next.keys)) {
          final List<Track> catalog;
          try {
            catalog = await readCatalog();
          } catch (error, stackTrace) {
            if (!cancelled) out.addError(error, stackTrace);
            continue;
          }
          if (cancelled) break;
          // Maps that came in while it read: the latest one is what to show,
          // and the read covers it unless it brought yet another new key.
          final Map<String, DownloadStatus>? newer = pending;
          final Set<String> keys = <String>{...next.keys};
          if (newer != null && keys.containsAll(newer.keys)) {
            next = newer;
            pending = null;
          }
          tracksByKey = <String, Track>{
            for (final Track track in catalog)
              if (keys.contains(CachedTrack.cacheKeyForTrack(track)))
                CachedTrack.cacheKeyForTrack(track): track,
          };
          readFor = keys;
          reread = true;
        }
        out.add(join(next, reread));
      }
    } finally {
      joining = false;
      if (ended && !cancelled) unawaited(out.close());
    }
  }

  out = StreamController<DownloadCatalog>(
    onListen: () {
      subscription = statuses.listen(
        (Map<String, DownloadStatus> next) {
          pending = next;
          unawaited(drain());
        },
        onError: out.addError,
        onDone: () {
          ended = true;
          if (!joining) unawaited(out.close());
        },
      );
    },
    onCancel: () async {
      cancelled = true;
      await subscription?.cancel();
    },
  );
  return out.stream;
}

int _activeStatusRank(DownloadStatus status) {
  switch (status) {
    case DownloadStatus.downloading:
      return 0;
    case DownloadStatus.queued:
      return 1;
    case DownloadStatus.failed:
      return 2;
    case DownloadStatus.downloaded:
    case DownloadStatus.notDownloaded:
      return 3;
  }
}

int _compareActiveDownloads(ActiveDownload a, ActiveDownload b) {
  final int byStatus =
      _activeStatusRank(a.status).compareTo(_activeStatusRank(b.status));
  return byStatus != 0 ? byStatus : a.track.id.compareTo(b.track.id);
}
