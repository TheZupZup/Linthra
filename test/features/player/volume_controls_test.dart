import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cast_state.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/features/player/cast/cast_providers.dart';
import 'package:linthra/features/player/mini_player.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';
import 'package:linthra/features/player/widgets/volume_controls.dart';
import 'package:linthra/shared/scroll/pointer_scroll_policy.dart';

import 'cast/fake_cast_service.dart';
import 'fake_playback_controller.dart';

const Track _track = Track(
  id: '1',
  title: 'Song One',
  uri: '/music/song1.mp3',
  artistName: 'Artist A',
);

const CastDevice _device = CastDevice(id: 'd1', name: 'Living Room');

PlaybackState _playing() => const PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _track,
    );

/// Pumps the volume control on its own, so the assertions are about the widget
/// rather than the screen that hosts it.
Future<FakePlaybackController> _pumpControls(
  WidgetTester tester, {
  PlaybackState? initial,
}) async {
  final FakePlaybackController controller =
      FakePlaybackController(initial: initial ?? _playing());
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playbackControllerProvider.overrideWithValue(controller),
      ],
      child: const MaterialApp(
        home: Scaffold(body: Center(child: VolumeControls())),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _pumpPlayer(
  WidgetTester tester, {
  required HostPlatform host,
  FakeCastService? cast,
  Size size = const Size(1400, 1000),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        hostPlatformProvider.overrideWithValue(host),
        playbackControllerProvider
            .overrideWithValue(FakePlaybackController(initial: _playing())),
        if (cast != null) castServiceProvider.overrideWithValue(cast),
      ],
      child: const MaterialApp(home: PlayerScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

/// Pumps the mini-player bar at [width], the way the shell hosts it.
Future<void> _pumpBar(
  WidgetTester tester, {
  required HostPlatform host,
  required double width,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 800);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        hostPlatformProvider.overrideWithValue(host),
        playbackControllerProvider
            .overrideWithValue(FakePlaybackController(initial: _playing())),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(),
          bottomNavigationBar: MiniPlayer(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('VolumeControls', () {
    testWidgets('drives the controller as the slider moves', (tester) async {
      final controller = await _pumpControls(tester);

      final Finder slider = find.byType(Slider);
      final Rect box = tester.getRect(slider);
      // Drag to roughly a quarter of the track.
      await tester.dragFrom(
        box.centerLeft + const Offset(4, 0),
        Offset(box.width * 0.25, 0),
      );
      await tester.pumpAndSettle();

      expect(controller.state.volume, greaterThan(0.0));
      expect(controller.state.volume, lessThan(1.0));
    });

    testWidgets('the mute button mutes and unmutes', (tester) async {
      final controller = await _pumpControls(tester);

      await tester.tap(find.byTooltip('Mute'));
      await tester.pumpAndSettle();
      expect(controller.state.muted, isTrue);
      expect(find.byIcon(Icons.volume_off), findsOneWidget);

      await tester.tap(find.byTooltip('Unmute'));
      await tester.pumpAndSettle();
      expect(controller.state.muted, isFalse);
    });

    testWidgets('unmuting comes back to the level that was playing',
        (tester) async {
      final controller = await _pumpControls(tester);
      controller.setVolume(0.4);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Mute'));
      await tester.pumpAndSettle();
      expect(controller.state.effectiveVolume, 0.0);

      await tester.tap(find.byTooltip('Unmute'));
      await tester.pumpAndSettle();
      expect(controller.state.effectiveVolume, 0.4);
    });

    testWidgets('the scroll wheel steps the level up and down', (tester) async {
      final controller = await _pumpControls(tester);
      controller.setVolume(0.5);
      await tester.pumpAndSettle();

      final Offset over = tester.getCenter(find.byType(Slider));
      final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
      pointer.hover(over);
      await tester.sendEventToBinding(
        pointer.scroll(const Offset(0, -wheelNotchExtent)),
      );
      await tester.pumpAndSettle();
      expect(controller.state.volume, closeTo(0.5 + volumeStep, 0.0001));

      await tester.sendEventToBinding(
        pointer.scroll(const Offset(0, wheelNotchExtent)),
      );
      await tester.pumpAndSettle();
      expect(controller.state.volume, closeTo(0.5, 0.0001));
    });

    testWidgets('a trackpad moves the level one step, not one per event',
        (tester) async {
      // The same physical gesture as one wheel click, delivered the way a
      // trackpad delivers it. Stepping per event took a two-finger flick from
      // half volume to silence in a handful of frames.
      final controller = await _pumpControls(tester);
      controller.setVolume(0.5);
      await tester.pumpAndSettle();

      final TestPointer pointer = TestPointer(1, PointerDeviceKind.trackpad);
      pointer.hover(tester.getCenter(find.byType(Slider)));
      for (int i = 0; i < 10; i++) {
        await tester.sendEventToBinding(
          pointer.scroll(const Offset(0, -wheelNotchExtent / 10)),
        );
      }
      await tester.pumpAndSettle();

      expect(controller.state.volume, closeTo(0.5 + volumeStep, 0.0001));
    });

    testWidgets('the page behind the control stays where it was',
        (tester) async {
      // The bug this control had: the wheel changed the volume *and* scrolled
      // whatever it was sitting on, because reading a scroll signal is not the
      // same as taking it.
      final FakePlaybackController controller =
          FakePlaybackController(initial: _playing());
      addTearDown(controller.dispose);
      final ScrollController page = ScrollController();
      addTearDown(page.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            playbackControllerProvider.overrideWithValue(controller),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: ListView(
                controller: page,
                children: <Widget>[
                  const VolumeControls(),
                  for (int i = 0; i < 30; i++)
                    SizedBox(height: 80, child: Text('row $i')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.setVolume(0.5);
      await tester.pumpAndSettle();

      final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
      pointer.hover(tester.getCenter(find.byType(Slider)));
      await tester.sendEventToBinding(
        pointer.scroll(const Offset(0, wheelNotchExtent)),
      );
      await tester.pumpAndSettle();

      expect(controller.state.volume, closeTo(0.5 - volumeStep, 0.0001));
      expect(page.offset, 0);
    });

    testWidgets('scrolling down while muted keeps the level to come back to',
        (tester) async {
      final controller = await _pumpControls(tester);
      controller.setVolume(0.6);
      controller.setMuted(true);
      await tester.pumpAndSettle();

      final Offset over = tester.getCenter(find.byType(Slider));
      final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
      pointer.hover(over);
      await tester.sendEventToBinding(
        pointer.scroll(const Offset(0, wheelNotchExtent)),
      );
      await tester.pumpAndSettle();

      expect(controller.state.volume, 0.6);
      expect(controller.state.muted, isTrue);
    });

    testWidgets('the keyboard adjusts the focused slider', (tester) async {
      final controller = await _pumpControls(tester);
      controller.setVolume(0.5);
      await tester.pumpAndSettle();

      // Tab to the slider (the mute button is the first stop on the way there),
      // then step it down with an arrow key.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();

      expect(controller.state.volume, lessThan(0.5));
    });

    testWidgets('never leaves the 0-1 range however far it is dragged',
        (tester) async {
      final controller = await _pumpControls(tester);

      final Rect box = tester.getRect(find.byType(Slider));
      await tester.dragFrom(box.center, const Offset(2000, 0));
      await tester.pumpAndSettle();
      expect(controller.state.volume, 1.0);

      await tester.dragFrom(box.center, const Offset(-2000, 0));
      await tester.pumpAndSettle();
      expect(controller.state.volume, 0.0);
    });

    testWidgets('announces itself as the volume, not a bare percentage',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final controller = await _pumpControls(tester);
      controller.setVolume(0.7);
      await tester.pumpAndSettle();

      // One node carrying both the name and the value: a screen reader landing
      // on the slider has to hear which slider it is, since Now Playing also
      // has a position one.
      final SemanticsData data =
          tester.getSemantics(find.byType(Slider)).getSemanticsData();
      expect(data.label, 'Volume');
      expect(data.value, '70%');
      expect(data.flagsCollection.isSlider, isTrue);
      expect(data.hasAction(SemanticsAction.increase), isTrue);

      handle.dispose();
    });

    testWidgets('follows a level set somewhere else', (tester) async {
      final controller = await _pumpControls(tester);

      // Stands in for MPRIS, or the other copy of this control.
      controller.setVolume(0.2);
      await tester.pumpAndSettle();

      final Slider slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.value, closeTo(0.2, 0.0001));
    });
  });

  group('Now Playing placement', () {
    testWidgets('desktop shows the volume control', (tester) async {
      await _pumpPlayer(tester, host: HostPlatform.linux);

      expect(find.byType(VolumeControls), findsOneWidget);
    });

    testWidgets('mobile playback UI is unchanged', (tester) async {
      await _pumpPlayer(tester, host: HostPlatform.android);

      expect(find.byType(VolumeControls), findsNothing);
    });

    testWidgets('a narrow desktop window keeps the actions it had',
        (tester) async {
      // The five actions and a slider do not both fit; the slider is the one
      // that gives way.
      await _pumpPlayer(
        tester,
        host: HostPlatform.linux,
        size: const Size(420, 900),
      );

      expect(find.byType(VolumeControls), findsNothing);
    });

    testWidgets('hidden while casting, where the receiver owns the level',
        (tester) async {
      final FakeCastService cast = FakeCastService(
        initial: const CastState(
          availability: CastAvailability.connected,
          devices: <CastDevice>[_device],
          connectedDevice: _device,
          isCasting: true,
        ),
      );
      addTearDown(cast.dispose);

      await _pumpPlayer(tester, host: HostPlatform.linux, cast: cast);

      expect(find.byType(VolumeControls), findsNothing);
    });
  });

  group('mini-player placement', () {
    testWidgets('a wide desktop bar carries the volume control',
        (tester) async {
      await _pumpBar(tester, host: HostPlatform.linux, width: 1200);

      expect(find.byType(VolumeControls), findsOneWidget);
    });

    testWidgets('a narrow bar leaves it out rather than squeezing the title',
        (tester) async {
      await _pumpBar(tester, host: HostPlatform.linux, width: 700);

      expect(find.byType(VolumeControls), findsNothing);
    });

    testWidgets('the phone bar is unchanged', (tester) async {
      await _pumpBar(tester, host: HostPlatform.android, width: 1200);

      expect(find.byType(VolumeControls), findsNothing);
    });
  });
}
