import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/remote_track_downloader.dart';
import 'package:linthra/core/services/routing_remote_track_downloader.dart';

/// A downloader that claims one scheme and returns canned bytes.
class _FakeDownloader implements RemoteTrackDownloader {
  _FakeDownloader(this.scheme, this.tag);

  final String scheme;
  final String tag;
  final List<String> fetched = <String>[];

  @override
  bool isRemote(Track track) => track.uri.startsWith(scheme);

  @override
  Future<RemoteTrackDownload> open(Track track) async {
    fetched.add(track.id);
    return RemoteTrackDownload(
      chunks: Stream<List<int>>.value(<int>[1]),
      contentLength: 1,
      fileExtension: tag,
    );
  }
}

void main() {
  late _FakeDownloader jellyfin;
  late _FakeDownloader subsonic;
  late RoutingRemoteTrackDownloader router;

  setUp(() {
    jellyfin = _FakeDownloader('jellyfin:', 'j');
    subsonic = _FakeDownloader('subsonic:', 's');
    router = RoutingRemoteTrackDownloader(<RemoteTrackDownloader>[
      jellyfin,
      subsonic,
    ]);
  });

  test('isRemote is true when any member claims the track', () {
    expect(
      router.isRemote(const Track(id: 's1', title: 'x', uri: 'subsonic:s1')),
      isTrue,
    );
    expect(
      router.isRemote(const Track(id: 'j1', title: 'x', uri: 'jellyfin:j1')),
      isTrue,
    );
    expect(
      router.isRemote(const Track(id: 'l', title: 'x', uri: '/music/a.mp3')),
      isFalse,
    );
  });

  test('open routes to the member that owns the scheme', () async {
    final data = await router
        .open(const Track(id: 's1', title: 'x', uri: 'subsonic:s1'));

    expect(data.fileExtension, 's');
    expect(subsonic.fetched, <String>['s1']);
    expect(jellyfin.fetched, isEmpty);
  });

  test('throws for a track no member can fetch', () {
    expect(
      () => router.open(const Track(id: 'l', title: 'x', uri: '/a.mp3')),
      throwsA(isA<StateError>()),
    );
  });
}
