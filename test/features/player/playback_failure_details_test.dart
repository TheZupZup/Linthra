import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/diagnostics/app_diagnostics.dart';
import 'package:linthra/core/diagnostics/linux_playback_diagnostics.dart';
import 'package:linthra/core/diagnostics/playback_failure_report.dart';
import 'package:linthra/core/models/playback_failure.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/sources/source_availability.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_playback_preferences.dart';
import 'package:linthra/data/repositories/playback_preferences_provider.dart';
import 'package:linthra/features/library/source_availability_providers.dart';
import 'package:linthra/features/player/playback_failure_details_providers.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';
import 'package:linthra/features/player/widgets/playback_error_notice.dart';
import 'package:linthra/features/player/widgets/playback_failure_details_sheet.dart';
import 'package:linthra/features/settings/diagnostics/linux_playback_diagnostics_collector.dart';

import 'fake_playback_controller.dart';

const Track _track = Track(
  id: 'jf-item-SECRETID',
  title: 'Private Song Title',
  uri: 'jellyfin:jf-item-SECRETID',
  artistName: 'Artist',
  albumName: 'Album',
);

/// A message the way a careless caller might have built one. Nothing copied
/// may repeat any of it.
const String _leakyMessage = 'Exception: GET https://user:hunter2@music.'
    'example.com/Audio/42/stream?api_key=SECRET-TOKEN';

const List<String> _secrets = <String>[
  'SECRET-TOKEN',
  'SECRETID',
  'hunter2',
  'music.example.com',
  'api_key',
  'https://',
  '/home/alice',
  'Private Song Title',
  'Exception',
];

PlaybackState _errorState(PlaybackFailure failure) => PlaybackState(
      status: PlaybackStatus.error,
      currentTrack: _track,
      upNext: const <Track>[
        Track(id: 'n', title: 'Next', uri: 'jellyfin:n'),
      ],
      failure: failure,
    );

/// The rest of the app's diagnostics as a snapshot, carrying the kinds of
/// values that must never reach the failure report.
AppDiagnosticsData _appDiagnostics() => const AppDiagnosticsData(
      appVersion: '9.9.9',
      jellyfinState: 'configured (server unreachable)',
      jellyfinHost: 'https://user:hunter2@music.example.com/jf?api_key=SECRET-'
          'TOKEN',
      localFolderSelected: true,
    );

Future<List<String>> _captureClipboard(WidgetTester tester,
    {bool fail = false}) async {
  final List<String> copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (MethodCall call) async {
      if (call.method == 'Clipboard.setData') {
        if (fail) throw PlatformException(code: 'clipboard-unavailable');
        copied
            .add((call.arguments as Map<Object?, Object?>)['text']! as String);
      }
      return null;
    },
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));
  return copied;
}

Future<void> _pumpPlayer(
  WidgetTester tester,
  FakePlaybackController controller, {
  LinuxPlaybackRuntimeProblem? runtimeProblem,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playbackControllerProvider.overrideWithValue(controller),
        playbackPreferencesProvider.overrideWithValue(
          InMemoryPlaybackPreferences(autoSkipUnplayable: false),
        ),
        sourceAvailabilityProvider.overrideWithValue(
          const <String, SourceAvailability>{
            'jellyfin': SourceAvailability.unreachable,
          },
        ),
        hostPlatformProvider.overrideWithValue(HostPlatform.linux),
        linuxPlaybackRuntimeProblemProvider
            .overrideWithValue(() => runtimeProblem),
        playbackFailureAppDiagnosticsProvider
            .overrideWithValue(() async => _appDiagnostics()),
      ],
      child: const MaterialApp(home: PlayerScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openDetails(WidgetTester tester) async {
  await tester.tap(find.byKey(PlaybackErrorNotice.detailsKey));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('every kind of failure has Details, and they say what is known',
      (WidgetTester tester) async {
    for (final (PlaybackFailureKind kind, PlaybackFailureCause cause)
        in <(PlaybackFailureKind, PlaybackFailureCause)>[
      (
        PlaybackFailureKind.temporarySource,
        PlaybackFailureCause.serverUnreachable
      ),
      (
        PlaybackFailureKind.localFileUnavailable,
        PlaybackFailureCause.fileUnavailable
      ),
      (
        PlaybackFailureKind.sourceSignInRequired,
        PlaybackFailureCause.sessionExpired
      ),
      (
        PlaybackFailureKind.unplayableMedia,
        PlaybackFailureCause.audioNotDecoded
      ),
      (
        PlaybackFailureKind.playbackEngineUnavailable,
        PlaybackFailureCause.engineUnavailable
      ),
    ]) {
      final PlaybackFailure failure =
          PlaybackFailure(kind: kind, message: 'Fixed text.', cause: cause);
      await _pumpPlayer(
        tester,
        FakePlaybackController(initial: _errorState(failure)),
        runtimeProblem: LinuxPlaybackRuntimeProblem.libraryMissing,
      );
      final PlaybackFailureDetails expected = PlaybackFailureDetails(
        failure: failure,
        sourceId: 'jellyfin',
        availability: SourceAvailability.unreachable,
        runtimeProblem: kind.isEngineFailure
            ? LinuxPlaybackRuntimeProblem.libraryMissing
            : null,
      );

      await _openDetails(tester);

      expect(find.byKey(PlaybackFailureDetailsSheet.sheetKey), findsOneWidget,
          reason: '$kind');
      expect(find.text(expected.title), findsOneWidget, reason: '$kind');
      expect(find.text(expected.explanation), findsOneWidget, reason: '$kind');
      expect(find.text(expected.nextStep), findsOneWidget, reason: '$kind');
      expect(find.text('Source: Jellyfin'), findsOneWidget, reason: '$kind');
      expect(find.text(expected.sourceState!), findsOneWidget, reason: '$kind');
      expect(find.byKey(PlaybackFailureDetailsSheet.copyKey), findsOneWidget);
      // A fresh app for the next kind, without this one's sheet on top.
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('Copy diagnostics copies the safe report, and says so',
      (WidgetTester tester) async {
    final List<String> copied = await _captureClipboard(tester);
    await _pumpPlayer(
      tester,
      FakePlaybackController(
        initial: _errorState(const PlaybackFailure(
          kind: PlaybackFailureKind.temporarySource,
          message: _leakyMessage,
          cause: PlaybackFailureCause.serverUnreachable,
          canRetry: true,
          canSkip: true,
        )),
      ),
    );
    await _openDetails(tester);

    await tester.tap(find.byKey(PlaybackFailureDetailsSheet.copyKey));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    final String report = copied.single;
    expect(report, contains('App version: 9.9.9'));
    expect(report, contains('Platform: linux'));
    expect(report, contains('Failure: temporarySource'));
    expect(report, contains('Cause: serverUnreachable'));
    expect(report, contains('Source: Jellyfin'));
    expect(
        report, contains('Jellyfin status: configured (server unreachable)'));
    expect(report, contains('Last source check: unreachable'));
    expect(report, contains('Playback state: error'));
    expect(report, contains('Track: id#'));
    expect(report, contains('Offered: retry, skip'));
    for (final String secret in _secrets) {
      expect(report, isNot(contains(secret)), reason: secret);
    }
    expect(find.text('Copied. Paste it into a bug report.'), findsOneWidget);
  });

  testWidgets('a copy the clipboard refuses says so instead of claiming it',
      (WidgetTester tester) async {
    await _captureClipboard(tester, fail: true);
    await _pumpPlayer(
      tester,
      FakePlaybackController(
        initial: _errorState(const PlaybackFailure(
          kind: PlaybackFailureKind.unplayableMedia,
          message: 'Fixed text.',
        )),
      ),
    );
    await _openDetails(tester);

    await tester.tap(find.byKey(PlaybackFailureDetailsSheet.copyKey));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't copy the diagnostics."), findsOneWidget);
    expect(find.textContaining('Copied'), findsNothing);
  });

  testWidgets('a report with no app diagnostics still carries the failure',
      (WidgetTester tester) async {
    final List<String> copied = await _captureClipboard(tester);
    final FakePlaybackController controller = FakePlaybackController(
      initial: _errorState(const PlaybackFailure(
        kind: PlaybackFailureKind.localFileUnavailable,
        message: 'Fixed text.',
        cause: PlaybackFailureCause.fileUnavailable,
      )),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          playbackControllerProvider.overrideWithValue(controller),
          playbackPreferencesProvider.overrideWithValue(
            InMemoryPlaybackPreferences(autoSkipUnplayable: false),
          ),
          sourceAvailabilityProvider
              .overrideWithValue(const <String, SourceAvailability>{}),
          hostPlatformProvider.overrideWithValue(HostPlatform.android),
          playbackFailureAppDiagnosticsProvider.overrideWithValue(
              () async => throw StateError('collector failed')),
        ],
        child: const MaterialApp(home: PlayerScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await _openDetails(tester);

    await tester.tap(find.byKey(PlaybackFailureDetailsSheet.copyKey));
    await tester.pumpAndSettle();

    expect(copied.single, contains('Failure: localFileUnavailable'));
    expect(copied.single, contains('Platform: android'));
    // Nothing checked a source here, so nothing is said about one.
    expect(copied.single, isNot(contains('Last source check')));
  });

  testWidgets('opening the details changes nothing about playback',
      (WidgetTester tester) async {
    final FakePlaybackController controller = FakePlaybackController(
      initial: _errorState(const PlaybackFailure(
        kind: PlaybackFailureKind.temporarySource,
        message: 'Fixed text.',
        cause: PlaybackFailureCause.serverUnreachable,
        canRetry: true,
        canSkip: true,
      )),
    );
    await _captureClipboard(tester);
    await _pumpPlayer(tester, controller);
    final int emitted = controller.emitCount;

    await _openDetails(tester);
    await tester.tap(find.byKey(PlaybackFailureDetailsSheet.copyKey));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10)); // outside the sheet
    await tester.pumpAndSettle();

    expect(find.byKey(PlaybackFailureDetailsSheet.sheetKey), findsNothing);
    expect(controller.retryCount, 0);
    expect(controller.skipCount, 0);
    expect(controller.anotherSourceCount, 0);
    expect(controller.playCount, 0);
    expect(controller.emitCount, emitted);
    // The panel's recoveries are still there, and still the controller's.
    await tester.tap(find
        .byKey(PlaybackErrorNotice.keyForAction(PlaybackRecoveryAction.retry)));
    await tester.pumpAndSettle();
    expect(controller.retryCount, 1);
  });

  testWidgets('Details and Copy diagnostics are labelled for a screen reader',
      (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _pumpPlayer(
      tester,
      FakePlaybackController(
        initial: _errorState(const PlaybackFailure(
          kind: PlaybackFailureKind.sourceSignInRequired,
          message: 'Fixed text.',
          cause: PlaybackFailureCause.sessionExpired,
        )),
      ),
    );

    expect(
      tester.getSemantics(find.byKey(PlaybackErrorNotice.detailsKey)),
      matchesSemantics(
        label: 'Details about this problem',
        isButton: true,
        hasTapAction: true,
        hasFocusAction: true,
        isEnabled: true,
        hasEnabledState: true,
        isFocusable: true,
      ),
    );

    await _openDetails(tester);

    expect(
      tester.getSemantics(find.text('Sign-in required')),
      matchesSemantics(label: 'Sign-in required', isHeader: true),
    );
    expect(
      tester.getSemantics(find.byKey(PlaybackFailureDetailsSheet.copyKey)),
      matchesSemantics(
        label: 'Copy diagnostics',
        isButton: true,
        hasTapAction: true,
        hasFocusAction: true,
        isEnabled: true,
        hasEnabledState: true,
        isFocusable: true,
      ),
    );
    semantics.dispose();
  });

  testWidgets('at a large text size the details scroll rather than overflow',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 2.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pumpPlayer(
      tester,
      FakePlaybackController(
        initial: _errorState(const PlaybackFailure(
          kind: PlaybackFailureKind.playbackEngineUnavailable,
          message: 'Fixed text.',
          cause: PlaybackFailureCause.engineUnavailable,
          canRetry: true,
        )),
      ),
      runtimeProblem: LinuxPlaybackRuntimeProblem.libraryIncompatible,
    );

    await tester.ensureVisible(find.byKey(PlaybackErrorNotice.detailsKey));
    await _openDetails(tester);
    await tester.scrollUntilVisible(
      find.byKey(PlaybackFailureDetailsSheet.copyKey),
      200,
      scrollable: find.descendant(
        of: find.byKey(PlaybackFailureDetailsSheet.sheetKey),
        matching: find.byType(Scrollable),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(PlaybackFailureDetailsSheet.copyKey).hitTestable(),
        findsOneWidget);
  });
}
