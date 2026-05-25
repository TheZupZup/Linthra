import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cast_state.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/active_playback_controller.dart';
import 'package:linthra/core/services/linthra_audio_handler.dart';
import 'package:linthra/core/services/media_browser_tree.dart';

import '../../features/library/fake_music_library_repository.dart';
import '../../features/player/cast/fake_cast_service.dart';
import '../../features/player/fake_playback_controller.dart';

const _device = CastDevice(id: 'd1', name: 'Living Room');

CastState _casting() => const CastState(
      availability: CastAvailability.connected,
      devices: <CastDevice>[_device],
      connectedDevice: _device,
      isCasting: true,
    );

Track _track(String id) => Track(id: id, title: 'Song $id', uri: '/$id.mp3');

/// Lets the cast-state stream reach the controller before assertions.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  // Requirement: Android Auto controls must not start duplicate *local*
  // playback when a Cast session is active. The handler delegates to the single
  // PlaybackController, which (the ActivePlaybackController) has suspended the
  // local engine for the duration of the cast session — so selecting a track
  // from the car updates the queue and mirrors onto the receiver without the
  // phone making a second sound.
  test('with Cast active, an Android Auto selection starts no local playback',
      () async {
    final library = <Track>[_track('a'), _track('b'), _track('c')];
    final local = FakePlaybackController(
      initial: PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: library.first,
      ),
    );
    final cast = FakeCastService();
    final controller = ActivePlaybackController(local: local, cast: cast);
    final handler = LinthraAudioHandler(
      controller,
      MediaBrowserTree(FakeMusicLibraryRepository(tracks: library)),
    );
    addTearDown(() async {
      await handler.dispose();
      await controller.dispose();
      await cast.dispose();
      await local.dispose();
    });

    // A Cast session begins: the local→cast handoff suspends the local engine.
    cast.emit(_casting());
    await _settle();
    expect(local.isSuspended, isTrue);
    final int playedBefore = local.playedTracks.length;

    // Android Auto selects a library track.
    await handler.playFromMediaId(MediaId.libraryTrack('b'));
    await _settle();

    // The queue advanced (so the receiver can be told what to play), but the
    // local engine played nothing new — no duplicate audio on the phone.
    expect(local.playedTracks.length, playedBefore);
    expect(controller.state.currentTrack?.id, 'b');
  });

  test('without Cast, an Android Auto selection plays locally as normal',
      () async {
    final library = <Track>[_track('a'), _track('b'), _track('c')];
    final local = FakePlaybackController();
    final cast = FakeCastService();
    final controller = ActivePlaybackController(local: local, cast: cast);
    final handler = LinthraAudioHandler(
      controller,
      MediaBrowserTree(FakeMusicLibraryRepository(tracks: library)),
    );
    addTearDown(() async {
      await handler.dispose();
      await controller.dispose();
      await cast.dispose();
      await local.dispose();
    });

    await handler.playFromMediaId(MediaId.libraryTrack('b'));
    await _settle();

    // Local output is active, so the selection really plays on the device.
    expect(local.playedTracks.map((t) => t.id), contains('b'));
    expect(controller.state.currentTrack?.id, 'b');
  });
}
