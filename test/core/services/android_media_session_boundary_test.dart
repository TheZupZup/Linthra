@TestOn('vm')
library;

import 'dart:io';

import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:audio_service_platform_interface/method_channel_audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/linthra_audio_handler.dart';

import '../../features/library/fake_music_library_repository.dart';
import '../../features/player/fake_playback_controller.dart';

/// The real Android media-session boundary, exercised end to end.
///
/// Everything below crosses the *actual* platform channels `audio_service`'s
/// Android plugin uses, in both directions:
///
///  * **inbound** — `AudioService.MediaSessionCallback.onSkipToNext()` calls
///    `AudioServicePlugin.invokeMethod("skipToNext", mapOf())` on the
///    `com.ryanheise.audio_service.handler.methods` channel. That is precisely
///    the message delivered here, encoded with the same standard codec, so the
///    decode + dispatch path a car's Next press takes is the one under test —
///    not a Dart stand-in for it.
///  * **outbound** — what the plugin's `onMethodCall` would then receive
///    (`setState`, `setMediaItem`, `setQueue`) is captured as the raw argument
///    maps, so the assertions are about the bytes the Android session is
///    actually built from (`PlaybackStateCompat`'s action bits, its active
///    queue item id, its state constant) rather than about Dart objects.
///
/// This is the level the #638 regression lived at: the Dart handler forwarded
/// Next correctly all along, but the session it published told Android Auto it
/// was `STATE_CONNECTING` for the whole of every track change, and the head
/// unit stops dispatching transport presses in that state.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel handlerChannel =
      MethodChannel('com.ryanheise.audio_service.handler.methods');
  const MethodChannel clientChannel =
      MethodChannel('com.ryanheise.audio_service.client.methods');

  const MethodChannel pathProviderChannel =
      MethodChannel('plugins.flutter.io/path_provider');

  /// Every call the plugin would have received since the last reset — used to
  /// count how many times the session was written to.
  final List<MethodCall> published = <MethodCall>[];

  /// The `PlaybackStateCompat` inputs of the session's *current* state: the
  /// last `setState` the plugin was handed, whenever it happened. Kept outside
  /// [published] because a command that is correctly a no-op publishes nothing,
  /// and the session still has to be showing the right thing afterwards.
  Map<Object?, Object?>? sessionState;

  late FakePlaybackController controller;

  Track track(String id) => Track(
        id: id,
        title: 'Song $id',
        uri: '/$id.mp3',
        artistName: 'Artist $id',
        albumName: 'Album $id',
      );

  final List<Track> album = <Track>[track('a'), track('b'), track('c')];

  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Delivers [method] on the handler channel exactly as the Android
  /// `MediaSessionCallback` does when a head unit, a steering-wheel button or
  /// the notification acts on the session.
  Future<void> fromMediaSession(
    String method, [
    Map<String, dynamic> arguments = const <String, dynamic>{},
  ]) async {
    await messenger.handlePlatformMessage(
      handlerChannel.name,
      const StandardMethodCodec()
          .encodeMethodCall(MethodCall(method, arguments)),
      (_) {},
    );
    await _settle();
  }

  /// The argument map of the most recent [method] the plugin would have been
  /// handed, or null when it was never called.
  Map<Object?, Object?>? lastPublished(String method) {
    for (final MethodCall call in published.reversed) {
      if (call.method == method) return call.arguments as Map<Object?, Object?>;
    }
    return null;
  }

  /// The `PlaybackStateCompat` inputs the Android session currently holds.
  Map<Object?, Object?> lastState() => sessionState!;

  List<Map<Object?, Object?>> publishedStates() => <Map<Object?, Object?>>[
        for (final MethodCall call in published)
          if (call.method == 'setState')
            (call.arguments as Map<Object?, Object?>)['state']!
                as Map<Object?, Object?>,
      ];

  setUpAll(() async {
    // The Android implementation, not the Linux no-op the test host defaults to.
    AudioServicePlatform.instance = MethodChannelAudioService();
    // audio_service builds a DefaultCacheManager for remote artwork during
    // init; it needs a temp directory and never gets used here (no track in
    // this suite carries an http cover).
    messenger.setMockMethodCallHandler(
        pathProviderChannel,
        (MethodCall call) async =>
            Directory.systemTemp.createTempSync('linthra_media_session').path);
    messenger.setMockMethodCallHandler(clientChannel, (MethodCall call) async {
      published.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(handlerChannel, (MethodCall call) async {
      published.add(call);
      if (call.method == 'setState') {
        sessionState = (call.arguments as Map<Object?, Object?>)['state']
            as Map<Object?, Object?>;
      }
      return null;
    });

    controller = FakePlaybackController();
    // The app's own attach path — the same call `bootstrapApplication` makes.
    final handler = await connectMediaSession(
      controller,
      FakeMusicLibraryRepository(tracks: album),
    );
    expect(handler, isNotNull,
        reason: 'the media session did not attach at the platform boundary');
  });

  tearDownAll(() async {
    await resetAttachedMediaSession();
    messenger.setMockMethodCallHandler(clientChannel, null);
    messenger.setMockMethodCallHandler(handlerChannel, null);
    messenger.setMockMethodCallHandler(pathProviderChannel, null);
    await controller.dispose();
  });

  /// Starts [tracks] at [startIndex] and clears everything recorded so far, so
  /// each test asserts only on what its own command produced.
  Future<void> startQueue({int startIndex = 0, List<Track>? tracks}) async {
    await controller.playTracks(tracks ?? album, startIndex: startIndex);
    await _settle();
    controller.skipCount = 0;
    controller.previousCount = 0;
    published.clear();
  }

  group('a car Next press crosses the media-session boundary (#638)', () {
    test('reaches the controller exactly once and advances one track',
        () async {
      await startQueue();

      await fromMediaSession('skipToNext');

      expect(controller.skipCount, 1);
      expect(controller.state.currentTrack?.id, 'b');
    });

    test('republishes the new track metadata to the session', () async {
      await startQueue();

      await fromMediaSession('skipToNext');

      final Map<Object?, Object?> item =
          lastPublished('setMediaItem')!['mediaItem']! as Map<Object?, Object?>;
      expect(item['id'], 'b');
      expect(item['title'], 'Song b');
      expect(item['artist'], 'Artist b');
      expect(item['album'], 'Album b');
    });

    test('moves the active queue row the head unit highlights', () async {
      await startQueue();
      await fromMediaSession('skipToNext');
      expect(lastState()['queueIndex'], 1);

      await fromMediaSession('skipToNext');
      expect(lastState()['queueIndex'], 2);

      await fromMediaSession('skipToPrevious');
      expect(lastState()['queueIndex'], 1);
    });

    test('keeps the session out of STATE_CONNECTING while the track opens',
        () async {
      // `AudioProcessingStateMessage.loading` is the one value
      // `AudioService.getPlaybackState()` turns into
      // PlaybackStateCompat.STATE_CONNECTING, and a session in that state has
      // its transport suspended by Android Auto — which is how a Next press
      // could be acknowledged by the car and never arrive here at all.
      await startQueue();

      await fromMediaSession('skipToNext');
      // The controller opens the next track before it can play it; this is the
      // state it publishes while resolving its playable URI.
      controller
          .emit(controller.state.copyWith(status: PlaybackStatus.loading));
      await _settle();

      expect(
        publishedStates()
            .map((Map<Object?, Object?> s) => s['processingState']),
        isNot(contains(AudioProcessingStateMessage.loading.index)),
      );
      expect(lastState()['processingState'],
          AudioProcessingStateMessage.buffering.index);
      // And the foreground service is still held across the change.
      expect(lastState()['playing'], isTrue);
    });

    test('advertises skip to the session even at a queue boundary', () async {
      // A head unit caches the capability set when it connects, so the actions
      // must not be toggled off at the ends of the queue or its buttons die.
      await startQueue(startIndex: album.length - 1);
      await fromMediaSession('skipToNext');

      final List<Object?> systemActions =
          lastState()['systemActions']! as List<Object?>;
      expect(systemActions, contains(MediaActionMessage.skipToNext.index));
      expect(systemActions, contains(MediaActionMessage.skipToPrevious.index));
      expect(systemActions, contains(MediaActionMessage.skipToQueueItem.index));
    });

    test('a Next at the end of the queue changes nothing', () async {
      await startQueue(startIndex: album.length - 1);

      await fromMediaSession('skipToNext');

      expect(controller.skipCount, 1);
      expect(controller.state.currentTrack?.id, 'c');
      expect(lastState()['queueIndex'], 2);
    });

    test('a Previous at the start of the queue changes nothing', () async {
      await startQueue();

      await fromMediaSession('skipToPrevious');

      expect(controller.previousCount, 1);
      expect(controller.state.currentTrack?.id, 'a');
      expect(lastState()['queueIndex'], 0);
    });

    test('navigating while paused still changes the track', () async {
      await startQueue();
      controller.emit(controller.state.copyWith(status: PlaybackStatus.paused));
      await _settle();
      published.clear();

      await fromMediaSession('skipToNext');

      expect(controller.state.currentTrack?.id, 'b');
      final Map<Object?, Object?> item =
          lastPublished('setMediaItem')!['mediaItem']! as Map<Object?, Object?>;
      expect(item['id'], 'b');
    });
  });

  group('the other transports keep sharing the same path', () {
    test('a media-button Next (notification / Bluetooth / steering wheel)',
        () async {
      // Hardware and notification buttons arrive as a KeyEvent, which the
      // plugin forwards as `click` with a MediaButton ordinal rather than as
      // `skipToNext`. Both must land on the same controller call.
      await startQueue();

      await fromMediaSession(
          'click', <String, dynamic>{'button': MediaButtonMessage.next.index});

      expect(controller.skipCount, 1);
      expect(controller.state.currentTrack?.id, 'b');
    });

    test('a media-button Previous', () async {
      await startQueue(startIndex: 1);

      await fromMediaSession('click',
          <String, dynamic>{'button': MediaButtonMessage.previous.index});

      expect(controller.previousCount, 1);
      expect(controller.state.currentTrack?.id, 'a');
    });

    test('tapping a row in the car Up Next list jumps to it', () async {
      await startQueue();

      await fromMediaSession('skipToQueueItem', <String, dynamic>{'index': 2});

      expect(controller.state.currentTrack?.id, 'c');
      expect(lastState()['queueIndex'], 2);
    });
  });

  group('reconnecting does not duplicate the session', () {
    test('a second attach reuses the live handler, never a second one',
        () async {
      // A second `AudioService.init` would install fresh platform callbacks and
      // fresh stream observers while leaving the old handler mirroring into the
      // same session: two writers over one notification and one Up Next list.
      final handlerAgain = await connectMediaSession(
        controller,
        FakeMusicLibraryRepository(tracks: album),
      );
      expect(handlerAgain, isNotNull);

      await startQueue();
      await fromMediaSession('skipToNext');

      // One press, one advance — not two handlers each taking the press.
      expect(controller.skipCount, 1);
      expect(controller.state.currentTrack?.id, 'b');
    });

    test('one media item is published per track change, not two', () async {
      await startQueue();

      await fromMediaSession('skipToNext');

      final Iterable<MethodCall> items =
          published.where((MethodCall c) => c.method == 'setMediaItem');
      expect(items, hasLength(1));
    });
  });
}

/// Lets the controller's broadcast reach the handler and the handler's pushes
/// reach the (mocked) platform channel before assertions read them.
Future<void> _settle() async {
  for (int i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
