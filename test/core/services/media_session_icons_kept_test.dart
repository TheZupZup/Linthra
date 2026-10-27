import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/linthra_audio_handler.dart';
import 'package:linthra/core/services/media_browser_tree.dart';

import '../../features/library/fake_music_library_repository.dart';
import '../../features/player/fake_playback_controller.dart';

/// Every icon the media session names survives the release resource shrinker.
///
/// `audio_service` turns each control's `androidIcon` into a resource with
/// `Resources.getIdentifier`, so nothing in the APK's code refers to those
/// drawables and the shrinker can't see them used. Since AGP 9 it removes them
/// from release builds. On Android 13 and later the Stop control then becomes
/// a `CustomAction` with icon 0, whose builder throws: every session update
/// fails, the session never reports playing, and the media foreground service
/// never starts. Music played while the app was open and stopped as soon as
/// the screen went off (v0.2.10). `res/raw/keep.xml` is what keeps them.
void main() {
  Track track(String id) => Track(id: id, title: id, uri: '/$id.mp3');

  /// The resources `res/raw/keep.xml` tells the shrinker to keep, as
  /// `type/name`.
  Set<String> keptResources() {
    final String keep =
        File('android/app/src/main/res/raw/keep.xml').readAsStringSync();
    final String? list =
        RegExp(r'tools:keep="([^"]*)"').firstMatch(keep)?.group(1);
    expect(list, isNotNull, reason: 'keep.xml has no tools:keep list');
    return <String>{
      for (final String entry in list!.split(','))
        if (entry.trim().isNotEmpty) entry.trim().replaceFirst('@', ''),
    };
  }

  test('keep.xml keeps every icon the media session publishes', () async {
    final FakePlaybackController controller = FakePlaybackController();
    final LinthraAudioHandler handler = LinthraAudioHandler(
      controller,
      MediaBrowserTree(FakeMusicLibraryRepository(tracks: const <Track>[])),
    );
    addTearDown(() async {
      await handler.dispose();
      await controller.dispose();
    });

    // Playing in the middle of a queue shows every control the session has
    // (Previous, Pause, Stop, Next and the custom ones), and a pause swaps
    // Pause for Play.
    final Set<String> icons = <String>{};
    for (final PlaybackStatus status in <PlaybackStatus>[
      PlaybackStatus.playing,
      PlaybackStatus.paused,
    ]) {
      controller.emit(PlaybackState(
        status: status,
        currentTrack: track('b'),
        previous: <Track>[track('a')],
        upNext: <Track>[track('c')],
        hasPrevious: true,
      ));
      await Future<void>.delayed(Duration.zero);
      icons.addAll(<String>[
        for (final control in handler.playbackState.value.controls)
          control.androidIcon,
      ]);
    }

    expect(
      icons,
      containsAll(<String>[
        'drawable/audio_service_skip_previous',
        'drawable/audio_service_pause',
        'drawable/audio_service_play_arrow',
        'drawable/audio_service_stop',
        'drawable/audio_service_skip_next',
      ]),
      reason: 'the states above no longer reach every control',
    );
    expect(
      icons.difference(keptResources()),
      isEmpty,
      reason: 'a release build drops these, and on Android 13+ the media '
          'session then never starts its foreground service',
    );
  });
}
