import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/desktop_close_behavior.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/desktop_window_controller.dart';
import 'package:linthra/core/services/desktop_window_lifecycle_service.dart';

import '../../features/player/fake_playback_controller.dart';

/// A [DesktopWindowController] that records what the app asked the window to
/// do, and lets a test play the runner's side of the conversation.
class _RecordingWindow implements DesktopWindowController {
  final List<bool> hideOnClose = <bool>[];
  int showCount = 0;
  int quitCount = 0;

  final StreamController<DesktopWindowVisibility> _visibility =
      StreamController<DesktopWindowVisibility>.broadcast();

  @override
  Stream<DesktopWindowVisibility> get visibility => _visibility.stream;

  /// The runner reporting a close that hid the window, or a window presented
  /// again.
  Future<void> report(DesktopWindowVisibility value) async {
    _visibility.add(value);
    await pumpEventQueue();
  }

  @override
  Future<void> setHideOnClose(bool value) async => hideOnClose.add(value);

  @override
  Future<void> showWindow() async => showCount++;

  @override
  Future<void> quit() async => quitCount++;

  Future<void> dispose() => _visibility.close();
}

const Track _track = Track(id: 't1', title: 'A Song', uri: '/music/a.flac');

PlaybackState _playing() => const PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _track,
    );

void main() {
  late FakePlaybackController playback;
  late _RecordingWindow window;
  late DesktopWindowLifecycleService service;

  setUp(() {
    playback = FakePlaybackController();
    window = _RecordingWindow();
    service = DesktopWindowLifecycleService(
      window: window,
      playback: playback,
    );
  });

  tearDown(() async {
    await service.dispose();
    await window.dispose();
    await playback.dispose();
  });

  test('tells the runner to quit on close until the user asks otherwise', () {
    service.start();

    expect(window.hideOnClose, <bool>[false]);
  });

  test('hides on close only once both the choice and the audio are there',
      () async {
    service.start();
    window.hideOnClose.clear();

    // The preference alone changes nothing: there is nothing playing yet.
    service.setCloseBehavior(DesktopCloseBehavior.keepPlaying);
    expect(window.hideOnClose, isEmpty);

    playback.emit(_playing());
    await pumpEventQueue();
    expect(window.hideOnClose, <bool>[true]);

    // And it is taken back the moment the music stops, so a close after the
    // queue ends quits instead of hiding a silent window.
    playback.emit(const PlaybackState(status: PlaybackStatus.completed));
    await pumpEventQueue();
    expect(window.hideOnClose, <bool>[true, false]);
  });

  test('pushes each answer once rather than on every position tick', () async {
    service.start();
    service.setCloseBehavior(DesktopCloseBehavior.keepPlaying);
    window.hideOnClose.clear();

    playback.emit(_playing());
    await pumpEventQueue();
    playback.emit(const PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _track,
      position: Duration(seconds: 3),
    ));
    await pumpEventQueue();

    expect(window.hideOnClose, <bool>[true]);
  });

  test('a hidden Linthra quits itself when the queue runs out', () async {
    final List<String> order = <String>[];
    service.installShutdown(() async => order.add('shutdown'));
    service.start();
    service.setCloseBehavior(DesktopCloseBehavior.keepPlaying);
    playback.emit(_playing());
    await pumpEventQueue();

    await window.report(DesktopWindowVisibility.hidden);
    expect(window.quitCount, 0);

    playback.emit(const PlaybackState(status: PlaybackStatus.completed));
    await pumpEventQueue();

    expect(order, <String>['shutdown']);
    expect(window.quitCount, 1);
  });

  test('a pause with the window hidden keeps the app running', () async {
    service.start();
    service.setCloseBehavior(DesktopCloseBehavior.keepPlaying);
    playback.emit(_playing());
    await pumpEventQueue();
    await window.report(DesktopWindowVisibility.hidden);

    playback.emit(const PlaybackState(
      status: PlaybackStatus.paused,
      currentTrack: _track,
    ));
    await pumpEventQueue();

    expect(window.quitCount, 0);
  });

  test('a visible Linthra never quits itself when playback ends', () async {
    service.start();
    service.setCloseBehavior(DesktopCloseBehavior.keepPlaying);
    playback.emit(_playing());
    await pumpEventQueue();
    playback.emit(PlaybackState.idle);
    await pumpEventQueue();

    expect(window.quitCount, 0);
  });

  test('quit releases the app before the window goes away', () async {
    final List<String> order = <String>[];
    service.installShutdown(() async {
      await Future<void>.delayed(Duration.zero);
      order.add('shutdown');
    });
    service.start();

    await service.quit();

    expect(order, <String>['shutdown']);
    expect(window.quitCount, 1);
  });

  test('quit runs once, however many times it is asked for', () async {
    int shutdowns = 0;
    service.installShutdown(() async => shutdowns++);
    service.start();

    await service.quit();
    await service.quit();

    expect(shutdowns, 1);
    expect(window.quitCount, 1);
  });

  test('a shutdown that throws still ends the process', () async {
    service.installShutdown(() async => throw StateError('teardown failed'));
    service.start();

    await service.quit();

    expect(window.quitCount, 1);
  });

  test('raise asks the runner to show the window', () async {
    service.start();

    await service.raise();

    expect(window.showCount, 1);
  });

  test('the window is left alone when the container is disposed', () async {
    service.start();

    await service.dispose();

    expect(window.quitCount, 0);
    // And a late playback state cannot reach a torn-down container.
    window.hideOnClose.clear();
    playback.emit(_playing());
    await pumpEventQueue();
    expect(window.hideOnClose, isEmpty);
  });
}
