import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/diagnostics/linux_playback_diagnostics.dart';
import 'package:linthra/core/diagnostics/playback_failure_report.dart';
import 'package:linthra/core/models/playback_failure.dart';
import 'package:linthra/core/sources/source_availability.dart';

/// A message the way a careless caller might have built one: everything the
/// details and the report must never repeat.
const String _leakyMessage = 'Exception: GET https://user:hunter2@music.'
    'example.com/Audio/42/stream?api_key=SECRET-TOKEN failed for '
    '/home/alice/Music/private.flac';

const List<String> _secrets = <String>[
  'SECRET-TOKEN',
  'hunter2',
  'music.example.com',
  'https://',
  'api_key',
  '/home/alice',
  'private.flac',
  'Exception',
];

PlaybackFailure _failure(
  PlaybackFailureKind kind, {
  PlaybackFailureCause? cause,
  bool canRetry = false,
  bool canTryAnotherSource = false,
  bool canSkip = false,
}) =>
    PlaybackFailure(
      kind: kind,
      message: _leakyMessage,
      cause: cause,
      canRetry: canRetry,
      canTryAnotherSource: canTryAnotherSource,
      canSkip: canSkip,
    );

void main() {
  group('the details', () {
    test('never repeat the failure message or anything in it', () {
      for (final PlaybackFailureKind kind in PlaybackFailureKind.values) {
        for (final PlaybackFailureCause? cause in <PlaybackFailureCause?>[
          null,
          ...PlaybackFailureCause.values,
        ]) {
          for (final String? source in <String?>[null, 'jellyfin', 'local']) {
            for (final SourceAvailability? availability
                in <SourceAvailability?>[null, ...SourceAvailability.values]) {
              final PlaybackFailureDetails details = PlaybackFailureDetails(
                failure: _failure(kind, cause: cause),
                sourceId: source,
                availability: availability,
                runtimeProblem: LinuxPlaybackRuntimeProblem.libraryMissing,
              );
              final String text = <String?>[
                details.title,
                details.explanation,
                details.sourceState,
                details.attempted,
                details.nextStep,
              ].join('\n');
              for (final String secret in _secrets) {
                expect(text, isNot(contains(secret)),
                    reason: '$kind / $cause / $source / $availability');
              }
            }
          }
        }
      }
    });

    test(
        'a server that could not be reached says so, and that the account '
        'is still set up', () {
      final PlaybackFailureDetails details = PlaybackFailureDetails(
        failure: _failure(PlaybackFailureKind.temporarySource,
            cause: PlaybackFailureCause.serverUnreachable),
        sourceId: 'jellyfin',
        availability: SourceAvailability.unreachable,
      );

      expect(details.title, 'Server unreachable');
      expect(
          details.explanation, "Linthra couldn't reach your Jellyfin server.");
      expect(details.sourceState, contains('still set up'));
      expect(details.nextStep, contains('connection'));
    });

    test('each cause of a source problem gets its own words', () {
      final Map<PlaybackFailureCause?, String> titles =
          <PlaybackFailureCause?, String>{
        PlaybackFailureCause.serverUnreachable: 'Server unreachable',
        PlaybackFailureCause.connectionDropped: 'Connection dropped',
        PlaybackFailureCause.serverReturnedWebPage: 'Server sent a web page',
        PlaybackFailureCause.invalidStream: 'Stream not available',
        PlaybackFailureCause.streamUnavailable: 'Stream not available',
        PlaybackFailureCause.unrecognized: 'Server or connection problem',
        null: 'Server or connection problem',
      };
      for (final MapEntry<PlaybackFailureCause?, String> entry
          in titles.entries) {
        final PlaybackFailureDetails details = PlaybackFailureDetails(
          failure:
              _failure(PlaybackFailureKind.temporarySource, cause: entry.key),
          sourceId: 'subsonic',
        );
        expect(details.title, entry.value, reason: '${entry.key}');
      }
    });

    test('a cause Linthra does not know gets the general words, not a guess',
        () {
      final PlaybackFailureDetails details = PlaybackFailureDetails(
        failure: _failure(PlaybackFailureKind.temporarySource),
      );

      expect(details.title, 'Server or connection problem');
      expect(details.explanation,
          "Linthra couldn't get this track from the server.");
      expect(details.explanation, isNot(contains('reach')));
    });

    test('audio that would not decode is never called a damaged file', () {
      for (final PlaybackFailureCause? cause in <PlaybackFailureCause?>[
        PlaybackFailureCause.audioNotDecoded,
        null,
      ]) {
        final PlaybackFailureDetails details = PlaybackFailureDetails(
          failure: _failure(PlaybackFailureKind.unplayableMedia, cause: cause),
          sourceId: 'local',
        );
        final String text = '${details.title} ${details.explanation}';

        expect(text, isNot(contains('is corrupt')));
        expect(text, isNot(contains('is damaged')));
        expect(details.explanation, contains("can't tell which"));
      }
    });

    test('a sign-in problem says which: none, or one turned down', () {
      final PlaybackFailureDetails none = PlaybackFailureDetails(
        failure: _failure(PlaybackFailureKind.sourceSignInRequired,
            cause: PlaybackFailureCause.notSignedIn),
        sourceId: 'subsonic',
      );
      final PlaybackFailureDetails rejected = PlaybackFailureDetails(
        failure: _failure(PlaybackFailureKind.sourceSignInRequired,
            cause: PlaybackFailureCause.sessionExpired),
        sourceId: 'jellyfin',
      );

      expect(none.title, 'Sign-in required');
      expect(none.explanation, contains('No account is signed in'));
      expect(none.nextStep, 'Sign in to Navidrome in Settings.');
      expect(rejected.explanation, contains('turned the current sign-in down'));
      expect(rejected.nextStep, contains('again'));
    });

    test('a missing local file names what can explain it, and no server', () {
      final PlaybackFailureDetails details = PlaybackFailureDetails(
        failure: _failure(PlaybackFailureKind.localFileUnavailable,
            cause: PlaybackFailureCause.fileUnavailable),
        sourceId: 'local',
      );

      expect(details.title, 'Local file unavailable');
      expect(details.sourceName, 'Local music');
      expect(details.explanation, contains('drive'));
      expect('${details.explanation} ${details.nextStep}',
          isNot(contains('server')));
    });

    test('an engine that would not start says which part, when known', () {
      String nextFor(LinuxPlaybackRuntimeProblem? problem) =>
          PlaybackFailureDetails(
            failure: _failure(PlaybackFailureKind.playbackEngineUnavailable,
                cause: PlaybackFailureCause.engineUnavailable),
            runtimeProblem: problem,
          ).nextStep;

      expect(nextFor(LinuxPlaybackRuntimeProblem.libraryMissing),
          contains('Install libmpv'));
      expect(nextFor(LinuxPlaybackRuntimeProblem.libraryUnloadable),
          contains("couldn't be loaded"));
      expect(nextFor(LinuxPlaybackRuntimeProblem.libraryIncompatible),
          contains("doesn't match"));
      expect(nextFor(LinuxPlaybackRuntimeProblem.backendInitializationFailed),
          contains("didn't start"));
      expect(nextFor(null), contains('needs attention'));
    });

    test('the source state is only what the last check found', () {
      PlaybackFailureDetails detailsFor(
              String? source, SourceAvailability? state) =>
          PlaybackFailureDetails(
            failure: _failure(PlaybackFailureKind.temporarySource),
            sourceId: source,
            availability: state,
          );

      expect(detailsFor('jellyfin', null).sourceState, isNull);
      expect(
          detailsFor(null, SourceAvailability.unreachable).sourceState, isNull);
      expect(detailsFor('jellyfin', SourceAvailability.checking).sourceState,
          isNull,
          reason: 'still checking is not an answer');
      expect(detailsFor('jellyfin', SourceAvailability.available).sourceState,
          contains('answered the last check'));
      expect(
          detailsFor('jellyfin', SourceAvailability.authenticationError)
              .sourceState,
          contains('turned its sign-in down'));
    });

    test('an unknown source is not named', () {
      final PlaybackFailureDetails details = PlaybackFailureDetails(
        failure: _failure(PlaybackFailureKind.temporarySource,
            cause: PlaybackFailureCause.serverUnreachable),
        sourceId: 'something-new',
      );

      expect(details.sourceName, isNull);
      expect(details.explanation, "Linthra couldn't reach the server.");
    });

    test('only a spent retry budget is reported as something already tried',
        () {
      String? attempted(PlaybackFailureKind kind, {required bool canRetry}) =>
          PlaybackFailureDetails(failure: _failure(kind, canRetry: canRetry))
              .attempted;

      expect(attempted(PlaybackFailureKind.temporarySource, canRetry: false),
          contains('as many times as it will'));
      expect(
          attempted(PlaybackFailureKind.localFileUnavailable, canRetry: false),
          isNotNull);
      expect(attempted(PlaybackFailureKind.temporarySource, canRetry: true),
          isNull);
      // Never offered in the first place, so nothing was used up.
      expect(attempted(PlaybackFailureKind.unplayableMedia, canRetry: false),
          isNull);
      expect(
          attempted(PlaybackFailureKind.sourceSignInRequired, canRetry: false),
          isNull);
      expect(
          attempted(PlaybackFailureKind.playbackEngineUnavailable,
              canRetry: false),
          isNull);
    });
  });

  group('the copied report', () {
    PlaybackFailureReportData data(
      PlaybackFailureDetails details, {
      String? sourceStatus,
    }) =>
        PlaybackFailureReportData(
          details: details,
          appVersion: '1.2.3',
          platform: 'linux',
          sourceStatus: sourceStatus,
          playbackStatus: 'error',
          trackIdHash: 'id#1a2b',
        );

    test('carries the safe structured fields', () {
      final String report = PlaybackFailureReport.render(data(
        PlaybackFailureDetails(
          failure: _failure(PlaybackFailureKind.temporarySource,
              cause: PlaybackFailureCause.serverUnreachable,
              canRetry: true,
              canSkip: true),
          sourceId: 'jellyfin',
          availability: SourceAvailability.unreachable,
        ),
        sourceStatus: 'configured (server unreachable)',
      ));

      expect(
        report.split('\n'),
        <String>[
          'Linthra playback failure',
          'App version: 1.2.3',
          'Platform: linux',
          'Failure: temporarySource',
          'Cause: serverUnreachable',
          'Source: Jellyfin',
          'Jellyfin status: configured (server unreachable)',
          'Last source check: unreachable',
          'Playback state: error',
          'Track: id#1a2b',
          'Offered: retry, skip',
        ],
      );
    });

    test('says unknown, or leaves a line out, rather than guess', () {
      final String report = PlaybackFailureReport.render(
        PlaybackFailureReportData(
          details: PlaybackFailureDetails(
            failure: _failure(PlaybackFailureKind.unplayableMedia),
          ),
          appVersion: '1.2.3',
        ),
      );

      expect(report, contains('Cause: unknown'));
      expect(report, contains('Offered: nothing'));
      expect(report, isNot(contains('Source')));
      expect(report, isNot(contains('Platform')));
      expect(report, isNot(contains('Track')));
      expect(report, isNot(contains('Linux audio runtime')));
    });

    test('names the broken part of the Linux runtime when that failed', () {
      final String report = PlaybackFailureReport.render(data(
        PlaybackFailureDetails(
          failure: _failure(PlaybackFailureKind.playbackEngineUnavailable,
              cause: PlaybackFailureCause.engineUnavailable, canRetry: true),
          runtimeProblem: LinuxPlaybackRuntimeProblem.libraryMissing,
        ),
      ));

      expect(report, contains('Linux audio runtime: libmpv not found'));
    });

    test('lists the decoders the device has, when known', () {
      final String report = PlaybackFailureReport.render(
        PlaybackFailureReportData(
          details: PlaybackFailureDetails(
            failure: _failure(PlaybackFailureKind.unplayableMedia,
                cause: PlaybackFailureCause.audioNotDecoded),
            sourceId: 'local',
          ),
          appVersion: '1.2.3',
          androidVersion: '14',
          androidSdkInt: 34,
          platformAudioFormats: const <String>['mp3', 'aac'],
          flacDecoding: 'platform (c2.android.flac.decoder), libFLAC',
        ),
      );

      expect(report, contains('Android SDK: 34'));
      expect(report, contains('Platform audio decoders: mp3, aac'));
      expect(report, contains('FLAC decoding: platform'));
    });

    test('never carries the message, a URL, a token or a path', () {
      for (final PlaybackFailureKind kind in PlaybackFailureKind.values) {
        for (final PlaybackFailureCause? cause in <PlaybackFailureCause?>[
          null,
          ...PlaybackFailureCause.values,
        ]) {
          final String report = PlaybackFailureReport.render(data(
            PlaybackFailureDetails(
              failure: _failure(kind, cause: cause, canRetry: true),
              sourceId: 'jellyfin',
              availability: SourceAvailability.available,
            ),
          ));
          for (final String secret in _secrets) {
            expect(report, isNot(contains(secret)), reason: '$kind / $cause');
          }
        }
      }
    });
  });
}
