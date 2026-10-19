import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audio_stream_quality.dart';
import 'package:linthra/core/models/cast_state.dart';
import 'package:linthra/core/models/playback_failure.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/audio_quality_probe.dart';
import 'package:linthra/data/repositories/audio_quality_probe_provider.dart';
import 'package:linthra/data/repositories/in_memory_playback_preferences.dart';
import 'package:linthra/data/repositories/playback_preferences_provider.dart';
import 'package:linthra/features/player/audio_quality_providers.dart';
import 'package:linthra/features/player/cast/cast_providers.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';
import 'package:linthra/features/player/widgets/playback_progress_bar.dart';
import 'package:linthra/features/settings/playback/show_audio_quality_controller.dart';

import 'cast/fake_cast_service.dart';
import 'fake_playback_controller.dart';

/// An engine whose report the test sets, counting how often it is asked and
/// whether anyone is listening for changes.
class _FakeEngine implements AudioQualityProbe {
  AudioStreamQuality? report;
  int reads = 0;
  int listeners = 0;
  bool everListened = false;

  late final StreamController<void> _changes = StreamController<void>.broadcast(
    onListen: () {
      listeners++;
      everListened = true;
    },
    onCancel: () => listeners--,
  );

  @override
  bool get isAvailable => true;

  @override
  AudioStreamQuality? current() {
    reads++;
    return report;
  }

  @override
  Stream<void> changes() => _changes.stream;

  /// The engine now reports [next] and says so.
  void change(AudioStreamQuality? next) {
    report = next;
    _changes.add(null);
  }
}

const Track _songA = Track(
  id: 'a',
  title: 'Song A',
  uri: 'subsonic:a',
  artistName: 'Artist',
);
const Track _songB = Track(id: 'b', title: 'Song B', uri: 'subsonic:b');

/// The same song as [_songA], from another provider: what a fallback swaps in.
const Track _songAOnJellyfin =
    Track(id: 'a', title: 'Song A', uri: 'jellyfin:a');

const AudioStreamQuality _flac =
    AudioStreamQuality(codec: 'flac', sampleRateHz: 44100);
const AudioStreamQuality _mp3 = AudioStreamQuality(
  codec: 'mp3',
  sampleRateHz: 44100,
  bitrateKbps: 320,
);

PlaybackState _state(
  Track track, {
  PlaybackStatus status = PlaybackStatus.playing,
  PlaybackSource? source = PlaybackSource.streamingDirect,
  PlaybackFailure? failure,
}) {
  return PlaybackState(
    status: status,
    currentTrack: track,
    source: source,
    duration: const Duration(minutes: 3),
    failure: failure,
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required FakePlaybackController controller,
  required _FakeEngine engine,
  bool enabled = true,
  FakeCastService? cast,
  bool settleFrames = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playbackControllerProvider.overrideWithValue(controller),
        playbackPreferencesProvider.overrideWithValue(
          InMemoryPlaybackPreferences(showAudioQuality: enabled),
        ),
        audioQualityProbeProvider.overrideWithValue(engine),
        if (cast != null) castServiceProvider.overrideWithValue(cast),
      ],
      child: const MaterialApp(home: PlayerScreen()),
    ),
  );
  if (settleFrames) {
    await tester.pumpAndSettle();
  } else {
    // A loading spinner never settles; two frames load the preference.
    await tester.pump();
    await tester.pump();
  }
}

/// Lets the newly loaded copy play long enough to be asked about.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(NowPlayingAudioQuality.settleDelay);
  await tester.pump();
}

/// The engine announces a new report, and the frame after it is drawn.
Future<void> _announce(
  WidgetTester tester,
  _FakeEngine engine,
  AudioStreamQuality? report,
) async {
  engine.change(report);
  await tester.pump();
  await tester.pump();
}

Future<void> _emit(
  WidgetTester tester,
  FakePlaybackController controller,
  PlaybackState state,
) async {
  controller.emit(state);
  await tester.pump();
  await tester.pump();
}

final Finder _line = find.byKey(const ValueKey<String>('audio-quality-line'));
final Finder _anyQuality = find.textContaining(' kHz');

void main() {
  testWidgets('off by default: no line, and the engine is never asked',
      (tester) async {
    final _FakeEngine engine = _FakeEngine()..report = _flac;
    await _pump(
      tester,
      controller: FakePlaybackController(initial: _state(_songA)),
      engine: engine,
      enabled: false,
    );
    await _settle(tester);

    expect(_line, findsNothing);
    expect(_anyQuality, findsNothing);
    expect(engine.reads, 0);
    expect(engine.everListened, isFalse);
  });

  testWidgets('shows what the engine reports once the copy has settled',
      (tester) async {
    final _FakeEngine engine = _FakeEngine()..report = _flac;
    await _pump(
      tester,
      controller: FakePlaybackController(initial: _state(_songA)),
      engine: engine,
    );

    expect(_line, findsOneWidget);
    await _settle(tester);

    expect(find.text('FLAC · Lossless · 44.1 kHz'), findsOneWidget);
    expect(find.text('Playing from Navidrome'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Audio quality: FLAC, lossless, 44.1 kilohertz'),
      findsOneWidget,
    );
  });

  testWidgets('an engine with nothing to report shows nothing made up',
      (tester) async {
    final _FakeEngine engine = _FakeEngine();
    await _pump(
      tester,
      controller: FakePlaybackController(initial: _state(_songA)),
      engine: engine,
    );
    await _settle(tester);

    expect(engine.reads, greaterThan(0));
    expect(_line, findsOneWidget);
    expect(_anyQuality, findsNothing);
    expect(find.textContaining('Lossless'), findsNothing);
    expect(find.textContaining('kbps'), findsNothing);
  });

  testWidgets('a skip drops the old report and never shows it for the new song',
      (tester) async {
    final _FakeEngine engine = _FakeEngine()..report = _flac;
    final FakePlaybackController controller =
        FakePlaybackController(initial: _state(_songA));
    await _pump(tester, controller: controller, engine: engine);
    await _settle(tester);
    expect(find.text('FLAC · Lossless · 44.1 kHz'), findsOneWidget);

    await _emit(
      tester,
      controller,
      _state(_songB, status: PlaybackStatus.loading, source: null),
    );
    expect(_anyQuality, findsNothing);

    // Song B has started, but the engine still mirrors song A's track list
    // and even announces it. Nothing is shown until B has settled.
    await _emit(tester, controller, _state(_songB));
    await _announce(tester, engine, _flac);
    expect(_anyQuality, findsNothing);

    engine.report = _mp3;
    await _settle(tester);
    expect(find.text('MP3 · 44.1 kHz · 320 kbps'), findsOneWidget);
    expect(find.textContaining('FLAC'), findsNothing);
  });

  testWidgets('a fallback to another provider re-reads the copy now playing',
      (tester) async {
    final _FakeEngine engine = _FakeEngine()..report = _mp3;
    final FakePlaybackController controller =
        FakePlaybackController(initial: _state(_songA));
    await _pump(tester, controller: controller, engine: engine);
    await _settle(tester);
    expect(find.text('MP3 · 44.1 kHz · 320 kbps'), findsOneWidget);

    // The same song, same status, now playing from Jellyfin's copy.
    engine.report = _flac;
    await _emit(tester, controller, _state(_songAOnJellyfin));
    expect(_anyQuality, findsNothing);

    await _settle(tester);
    expect(find.text('FLAC · Lossless · 44.1 kHz'), findsOneWidget);
    expect(find.text('Playing from Jellyfin'), findsOneWidget);
  });

  testWidgets('moving from the stream to the offline copy re-reads it',
      (tester) async {
    final _FakeEngine engine = _FakeEngine()..report = _mp3;
    final FakePlaybackController controller =
        FakePlaybackController(initial: _state(_songA));
    await _pump(tester, controller: controller, engine: engine);
    await _settle(tester);

    engine.report = _flac;
    await _emit(
      tester,
      controller,
      _state(_songA, source: PlaybackSource.offlineCache),
    );
    expect(_anyQuality, findsNothing);
    await _settle(tester);
    expect(find.text('FLAC · Lossless · 44.1 kHz'), findsOneWidget);
  });

  testWidgets('a report that arrives after the copy settled is picked up',
      (tester) async {
    final _FakeEngine engine = _FakeEngine()
      ..report = const AudioStreamQuality(codec: 'flac');
    await _pump(
      tester,
      controller: FakePlaybackController(initial: _state(_songA)),
      engine: engine,
    );
    await _settle(tester);
    expect(find.text('FLAC · Lossless'), findsOneWidget);

    await _announce(tester, engine, _flac);
    expect(find.text('FLAC · Lossless · 44.1 kHz'), findsOneWidget);
  });

  testWidgets('pausing and buffering keep the report for the same copy',
      (tester) async {
    final _FakeEngine engine = _FakeEngine()..report = _flac;
    final FakePlaybackController controller =
        FakePlaybackController(initial: _state(_songA));
    await _pump(tester, controller: controller, engine: engine);
    await _settle(tester);
    final int readsBefore = engine.reads;

    await _emit(
        tester, controller, _state(_songA, status: PlaybackStatus.paused));
    expect(find.text('FLAC · Lossless · 44.1 kHz'), findsOneWidget);

    await _emit(
        tester, controller, _state(_songA, status: PlaybackStatus.buffering));
    expect(find.text('FLAC · Lossless · 44.1 kHz'), findsOneWidget);
    expect(engine.reads, readsBefore);
  });

  testWidgets('reconnecting and failing clear the report', (tester) async {
    final _FakeEngine engine = _FakeEngine()..report = _flac;
    final FakePlaybackController controller =
        FakePlaybackController(initial: _state(_songA));
    await _pump(tester, controller: controller, engine: engine);
    await _settle(tester);

    await _emit(tester, controller,
        _state(_songA, status: PlaybackStatus.reconnecting));
    expect(_anyQuality, findsNothing);

    await _emit(tester, controller, _state(_songA));
    await _settle(tester);
    expect(find.text('FLAC · Lossless · 44.1 kHz'), findsOneWidget);

    await _emit(
      tester,
      controller,
      _state(
        _songA,
        status: PlaybackStatus.error,
        source: null,
        failure: const PlaybackFailure(
          kind: PlaybackFailureKind.temporarySource,
          message: "Couldn't reach your music server.",
        ),
      ),
    );
    await _settle(tester);
    expect(_anyQuality, findsNothing);
  });

  testWidgets('while casting, the local engine is not described',
      (tester) async {
    const CastDevice device = CastDevice(id: 'd1', name: 'Living Room');
    final FakeCastService cast = FakeCastService(
      initial: const CastState(
        availability: CastAvailability.connected,
        devices: <CastDevice>[device],
        connectedDevice: device,
        isCasting: true,
      ),
    );
    addTearDown(cast.dispose);
    final _FakeEngine engine = _FakeEngine()..report = _flac;

    await _pump(
      tester,
      controller: FakePlaybackController(initial: _state(_songA)),
      engine: engine,
      cast: cast,
    );
    await _settle(tester);

    expect(find.text('Casting to Living Room'), findsOneWidget);
    expect(_anyQuality, findsNothing);
    expect(engine.reads, 0);
  });

  testWidgets('a receiver that is only connected leaves the local line on',
      (tester) async {
    // Connected, but nothing handed off (a local file the receiver cannot
    // take): the engine here is still the one playing.
    const CastDevice device = CastDevice(id: 'd1', name: 'Living Room');
    final FakeCastService cast = FakeCastService(
      initial: const CastState(
        availability: CastAvailability.connected,
        devices: <CastDevice>[device],
        connectedDevice: device,
      ),
    );
    addTearDown(cast.dispose);
    final _FakeEngine engine = _FakeEngine()..report = _flac;

    await _pump(
      tester,
      controller: FakePlaybackController(
        initial: _state(_songA, source: PlaybackSource.localFile),
      ),
      engine: engine,
      cast: cast,
    );
    await _settle(tester);

    expect(find.text('FLAC · Lossless · 44.1 kHz'), findsOneWidget);
  });

  testWidgets('the line keeps its height whether or not a report is known',
      (tester) async {
    final _FakeEngine engine = _FakeEngine()..report = _flac;
    final FakePlaybackController controller = FakePlaybackController(
      initial: _state(_songA, status: PlaybackStatus.loading, source: null),
    );
    await _pump(
      tester,
      controller: controller,
      engine: engine,
      settleFrames: false,
    );

    final Finder title = find.text('Song A');
    final Finder progress = find.byType(PlaybackProgressBar);
    final double lineBefore = tester.getSize(_line).height;
    final Offset titleBefore = tester.getTopLeft(title);
    final Offset progressBefore = tester.getTopLeft(progress);

    await _emit(tester, controller, _state(_songA));
    await _settle(tester);
    expect(find.text('FLAC · Lossless · 44.1 kHz'), findsOneWidget);

    expect(tester.getSize(_line).height, lineBefore);
    expect(tester.getTopLeft(title), titleBefore);
    expect(tester.getTopLeft(progress), progressBefore);
  });

  testWidgets('leaving Now Playing stops listening to the engine',
      (tester) async {
    final _FakeEngine engine = _FakeEngine()..report = _flac;
    await _pump(
      tester,
      controller: FakePlaybackController(initial: _state(_songA)),
      engine: engine,
    );
    await _settle(tester);
    expect(engine.listeners, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(engine.listeners, 0);
  });

  testWidgets('turning the setting off mid-song lets go of the engine',
      (tester) async {
    final _FakeEngine engine = _FakeEngine()..report = _flac;
    final InMemoryPlaybackPreferences preferences =
        InMemoryPlaybackPreferences(showAudioQuality: true);
    final ProviderContainer container = ProviderContainer(
      overrides: [
        playbackControllerProvider
            .overrideWithValue(FakePlaybackController(initial: _state(_songA))),
        playbackPreferencesProvider.overrideWithValue(preferences),
        audioQualityProbeProvider.overrideWithValue(engine),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: PlayerScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await _settle(tester);
    expect(find.text('FLAC · Lossless · 44.1 kHz'), findsOneWidget);

    await container
        .read(showAudioQualityControllerProvider.notifier)
        .setEnabled(false);
    await tester.pump();

    expect(_line, findsNothing);
    expect(engine.listeners, 0);
    expect(await preferences.showAudioQuality(), isFalse);
  });
}
