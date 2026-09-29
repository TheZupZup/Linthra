import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_preferences.dart';
import 'package:linthra/core/services/smart_precache_service.dart';
import 'package:linthra/core/services/track_prefetcher.dart';
import 'package:linthra/data/repositories/in_memory_download_preferences.dart';

class _RecordingPrefetcher implements TrackPrefetcher {
  final List<String> ids = <String>[];

  @override
  Future<void> prefetch(
    Track track, {
    Iterable<Track> keep = const <Track>[],
    bool Function()? isStillWanted,
  }) async {
    ids.add(track.id);
  }
}

Track _track(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');

PlaybackState _playing() => PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _track('current'),
      upNext: <Track>[_track('next')],
    );

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('save-data profile pauses automatic smart pre-cache', () async {
    final states = StreamController<PlaybackState>.broadcast();
    final prefetcher = _RecordingPrefetcher();
    final service = SmartPrecacheService(
      playbackStates: states.stream,
      prefetcher: prefetcher,
      preferences: InMemoryDownloadPreferences(
        mobileDataProfile: MobileDataProfile.saveData,
      ),
    );

    states.add(_playing());
    await _settle();

    expect(prefetcher.ids, isEmpty);
    await service.dispose();
    await states.close();
  });

  test('unlimited profile keeps automatic smart pre-cache enabled', () async {
    final states = StreamController<PlaybackState>.broadcast();
    final prefetcher = _RecordingPrefetcher();
    final service = SmartPrecacheService(
      playbackStates: states.stream,
      prefetcher: prefetcher,
      preferences: InMemoryDownloadPreferences(
        mobileDataProfile: MobileDataProfile.unlimited,
      ),
    );

    states.add(_playing());
    await _settle();

    expect(prefetcher.ids, <String>['next']);
    await service.dispose();
    await states.close();
  });
}
