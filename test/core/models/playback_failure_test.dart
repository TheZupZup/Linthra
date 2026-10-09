import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_failure.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/playback_failure_classifier.dart';
import 'package:linthra/core/services/stream_interruption.dart';

void main() {
  group('offered actions', () {
    test('are listed cheapest-first and only when valid', () {
      const PlaybackFailure failure = PlaybackFailure(
        kind: PlaybackFailureKind.temporarySource,
        message: "Couldn't reach your music server.",
        canRetry: true,
        canTryAnotherSource: true,
        canSkip: true,
      );

      expect(failure.actions, <PlaybackRecoveryAction>[
        PlaybackRecoveryAction.retry,
        PlaybackRecoveryAction.tryAnotherSource,
        PlaybackRecoveryAction.skip,
      ]);
      expect(failure.hasActions, isTrue);
    });

    test('a failure with nothing to offer says so rather than pretending', () {
      const PlaybackFailure failure = PlaybackFailure(
        kind: PlaybackFailureKind.unplayableMedia,
        message: "This track's format isn't supported on this device.",
      );

      expect(failure.actions, isEmpty);
      expect(failure.hasActions, isFalse);
    });
  });

  group('what is worth retrying', () {
    test('a source or a drive can come back; a session and a codec cannot', () {
      expect(PlaybackFailureKind.temporarySource.isWorthRetrying, isTrue);
      expect(PlaybackFailureKind.localFileUnavailable.isWorthRetrying, isTrue);
      expect(PlaybackFailureKind.sourceSignInRequired.isWorthRetrying, isFalse);
      expect(PlaybackFailureKind.unplayableMedia.isWorthRetrying, isFalse);
    });

    test('so can a machine whose audio runtime has been repaired', () {
      expect(
        PlaybackFailureKind.playbackEngineUnavailable.isWorthRetrying,
        isTrue,
      );
    });
  });

  group('an engine failure is not a track failure', () {
    test('exactly one kind is about the engine', () {
      expect(
        <PlaybackFailureKind>[
          for (final PlaybackFailureKind kind in PlaybackFailureKind.values)
            if (kind.isEngineFailure) kind,
        ],
        <PlaybackFailureKind>[PlaybackFailureKind.playbackEngineUnavailable],
      );
    });

    test('every kind has its own short label for the mini-player', () {
      final Set<String> labels = <String>{
        for (final PlaybackFailureKind kind in PlaybackFailureKind.values)
          kind.shortLabel,
      };

      expect(labels, hasLength(PlaybackFailureKind.values.length));
    });
  });

  group('classifying the failures playback already has', () {
    test('every resolution kind maps to the recovery that fits it', () {
      const Map<PlaybackResolutionErrorKind, PlaybackFailureKind> expected =
          <PlaybackResolutionErrorKind, PlaybackFailureKind>{
        PlaybackResolutionErrorKind.notSignedIn:
            PlaybackFailureKind.sourceSignInRequired,
        PlaybackResolutionErrorKind.sessionExpired:
            PlaybackFailureKind.sourceSignInRequired,
        PlaybackResolutionErrorKind.serverUnreachable:
            PlaybackFailureKind.temporarySource,
        PlaybackResolutionErrorKind.invalidStream:
            PlaybackFailureKind.temporarySource,
        PlaybackResolutionErrorKind.serverReturnedWebPage:
            PlaybackFailureKind.temporarySource,
        PlaybackResolutionErrorKind.streamUnavailable:
            PlaybackFailureKind.temporarySource,
        PlaybackResolutionErrorKind.localFileMissing:
            PlaybackFailureKind.localFileUnavailable,
        PlaybackResolutionErrorKind.mediaUnsupported:
            PlaybackFailureKind.unplayableMedia,
        PlaybackResolutionErrorKind.playbackEngineUnavailable:
            PlaybackFailureKind.playbackEngineUnavailable,
      };

      // Every kind is covered, so a new one cannot slip through untested.
      expect(expected.keys, containsAll(PlaybackResolutionErrorKind.values));
      expected.forEach((
        PlaybackResolutionErrorKind kind,
        PlaybackFailureKind failure,
      ) {
        expect(playbackFailureKindForResolution(kind), failure,
            reason: '$kind');
      });
    });

    test('every mid-stream interruption maps too', () {
      const Map<StreamInterruptionKind, PlaybackFailureKind> expected =
          <StreamInterruptionKind, PlaybackFailureKind>{
        StreamInterruptionKind.networkDropped:
            PlaybackFailureKind.temporarySource,
        StreamInterruptionKind.serverUnreachable:
            PlaybackFailureKind.temporarySource,
        StreamInterruptionKind.unknown: PlaybackFailureKind.temporarySource,
        StreamInterruptionKind.sessionExpired:
            PlaybackFailureKind.sourceSignInRequired,
        StreamInterruptionKind.formatUnsupported:
            PlaybackFailureKind.unplayableMedia,
        StreamInterruptionKind.localFileUnavailable:
            PlaybackFailureKind.localFileUnavailable,
      };

      expect(expected.keys, containsAll(StreamInterruptionKind.values));
      expected.forEach((
        StreamInterruptionKind kind,
        PlaybackFailureKind failure,
      ) {
        expect(
          playbackFailureKindForInterruption(kind),
          failure,
          reason: '$kind',
        );
      });
    });
  });

  group('the cause the details are worded from', () {
    test('every resolution kind records one, and agrees with its kind', () {
      const Map<PlaybackResolutionErrorKind, PlaybackFailureCause> expected =
          <PlaybackResolutionErrorKind, PlaybackFailureCause>{
        PlaybackResolutionErrorKind.notSignedIn:
            PlaybackFailureCause.notSignedIn,
        PlaybackResolutionErrorKind.sessionExpired:
            PlaybackFailureCause.sessionExpired,
        PlaybackResolutionErrorKind.serverUnreachable:
            PlaybackFailureCause.serverUnreachable,
        PlaybackResolutionErrorKind.invalidStream:
            PlaybackFailureCause.invalidStream,
        PlaybackResolutionErrorKind.serverReturnedWebPage:
            PlaybackFailureCause.serverReturnedWebPage,
        PlaybackResolutionErrorKind.streamUnavailable:
            PlaybackFailureCause.streamUnavailable,
        PlaybackResolutionErrorKind.localFileMissing:
            PlaybackFailureCause.fileUnavailable,
        PlaybackResolutionErrorKind.mediaUnsupported:
            PlaybackFailureCause.audioNotDecoded,
        PlaybackResolutionErrorKind.playbackEngineUnavailable:
            PlaybackFailureCause.engineUnavailable,
      };

      expect(expected.keys, containsAll(PlaybackResolutionErrorKind.values));
      expected.forEach((
        PlaybackResolutionErrorKind kind,
        PlaybackFailureCause cause,
      ) {
        expect(playbackFailureCauseForResolution(kind), cause, reason: '$kind');
      });
    });

    test('every mid-stream interruption records one too', () {
      const Map<StreamInterruptionKind, PlaybackFailureCause> expected =
          <StreamInterruptionKind, PlaybackFailureCause>{
        StreamInterruptionKind.networkDropped:
            PlaybackFailureCause.connectionDropped,
        StreamInterruptionKind.serverUnreachable:
            PlaybackFailureCause.serverUnreachable,
        StreamInterruptionKind.unknown: PlaybackFailureCause.unrecognized,
        StreamInterruptionKind.sessionExpired:
            PlaybackFailureCause.sessionExpired,
        StreamInterruptionKind.formatUnsupported:
            PlaybackFailureCause.audioNotDecoded,
        StreamInterruptionKind.localFileUnavailable:
            PlaybackFailureCause.fileUnavailable,
      };

      expect(expected.keys, containsAll(StreamInterruptionKind.values));
      expected.forEach((
        StreamInterruptionKind kind,
        PlaybackFailureCause cause,
      ) {
        expect(playbackFailureCauseForInterruption(kind), cause,
            reason: '$kind');
      });
    });

    test('is part of what makes two failures the same, and safe to log', () {
      const PlaybackFailure unreachable = PlaybackFailure(
        kind: PlaybackFailureKind.temporarySource,
        message: 'm',
        cause: PlaybackFailureCause.serverUnreachable,
      );
      const PlaybackFailure dropped = PlaybackFailure(
        kind: PlaybackFailureKind.temporarySource,
        message: 'm',
        cause: PlaybackFailureCause.connectionDropped,
      );

      expect(unreachable == dropped, isFalse);
      expect(unreachable.toString(), contains('cause: serverUnreachable'));
      expect(unreachable.toString(), isNot(contains('m,')));
    });
  });

  group('on the playback state', () {
    const PlaybackFailure failure = PlaybackFailure(
      kind: PlaybackFailureKind.temporarySource,
      message: "Couldn't reach your music server.",
      canRetry: true,
    );

    test('the message reads through for the surfaces that only want it', () {
      const PlaybackState state = PlaybackState(
        status: PlaybackStatus.error,
        failure: failure,
      );

      expect(state.errorMessage, "Couldn't reach your music server.");
      expect(const PlaybackState().errorMessage, isNull);
    });

    test('it clears on the next state change but survives a volume stamp', () {
      const PlaybackState errored = PlaybackState(
        status: PlaybackStatus.error,
        failure: failure,
      );

      // A derived state is a *new* situation: the failure does not ride along.
      expect(errored.copyWith(status: PlaybackStatus.loading).failure, isNull);
      // A re-stamp of the same situation keeps it.
      expect(
        errored.withVolume(volume: 0.4, muted: false).failure,
        failure,
      );
      expect(errored.withTransientFocusInterruption(true).failure, failure);
    });

    test('two states differing only in their failure are not equal', () {
      const PlaybackState a = PlaybackState(
        status: PlaybackStatus.error,
        failure: failure,
      );
      const PlaybackState b = PlaybackState(
        status: PlaybackStatus.error,
        failure: PlaybackFailure(
          kind: PlaybackFailureKind.unplayableMedia,
          message: "Couldn't reach your music server.",
          canRetry: true,
        ),
      );

      expect(a, isNot(b));
      expect(
          a,
          const PlaybackState(
            status: PlaybackStatus.error,
            failure: failure,
          ));
    });
  });
}
