import 'package:flutter/foundation.dart';

import '../models/playback_failure.dart';
import '../services/playback_source_label.dart';
import '../sources/source_availability.dart';
import 'linux_playback_diagnostics.dart';

/// What the details of a playback failure say, in fixed wording picked from
/// what the controller classified: the kind, the cause when known, the source
/// the track belongs to and what the last check of that source found.
///
/// Nothing here quotes an error. Every sentence is a constant chosen by a
/// switch, with at most a source's safe display name put in, so the details
/// can't carry a URL, a token, a path or a raw exception even if the failure's
/// cause came from one. And nothing here guesses: a cause Linthra doesn't know
/// gives the general wording for the kind, never a likelier-sounding one, and
/// audio that wouldn't decode is never called a damaged file.
@immutable
class PlaybackFailureDetails {
  const PlaybackFailureDetails({
    required this.failure,
    this.sourceId,
    this.availability,
    this.runtimeProblem,
  });

  final PlaybackFailure failure;

  /// The provider the failed track belongs to (`MusicProvider.sourceId`),
  /// when known.
  final String? sourceId;

  /// What the last check of that source found, for the sources Linthra checks
  /// (Jellyfin today). Null when there is no such answer.
  final SourceAvailability? availability;

  /// What stopped the Linux audio runtime, when that is what failed and
  /// Linthra knows which part.
  final LinuxPlaybackRuntimeProblem? runtimeProblem;

  /// The source's display name ("Jellyfin", "Local music"), or null when the
  /// track's source isn't known.
  String? get sourceName {
    final String? id = sourceId;
    if (id == null) return null;
    final String name = PlaybackSourceLabel.forSourceId(id);
    return name == PlaybackSourceLabel.unknown ? null : name;
  }

  /// "your Jellyfin server", or "the server" when the source isn't known.
  String get _server {
    final String? name = sourceName;
    return name == null || sourceId == 'local'
        ? 'the server'
        : 'your $name server';
  }

  /// A short name for the problem.
  String get title => switch (failure.kind) {
        PlaybackFailureKind.temporarySource => switch (failure.cause) {
            PlaybackFailureCause.serverUnreachable => 'Server unreachable',
            PlaybackFailureCause.connectionDropped => 'Connection dropped',
            PlaybackFailureCause.serverReturnedWebPage =>
              'Server sent a web page',
            PlaybackFailureCause.invalidStream ||
            PlaybackFailureCause.streamUnavailable =>
              'Stream not available',
            _ => 'Server or connection problem',
          },
        PlaybackFailureKind.localFileUnavailable => 'Local file unavailable',
        PlaybackFailureKind.sourceSignInRequired => 'Sign-in required',
        PlaybackFailureKind.unplayableMedia =>
          failure.cause == PlaybackFailureCause.audioNotDecoded
              ? "Audio couldn't be decoded"
              : "This track can't be played",
        PlaybackFailureKind.playbackEngineUnavailable =>
          'Audio engine unavailable',
      };

  /// What Linthra knows about what happened, beyond the panel's own message.
  String get explanation => switch (failure.kind) {
        PlaybackFailureKind.temporarySource => switch (failure.cause) {
            PlaybackFailureCause.serverUnreachable =>
              "Linthra couldn't reach $_server.",
            PlaybackFailureCause.connectionDropped =>
              'The connection to $_server dropped while this track was '
                  'playing.',
            PlaybackFailureCause.serverReturnedWebPage =>
              '${_capitalized(_server)} answered with a web page instead of '
                  'the audio.',
            PlaybackFailureCause.invalidStream =>
              "${_capitalized(_server)} answered, but not with audio Linthra "
                  'could play.',
            PlaybackFailureCause.streamUnavailable =>
              "${_capitalized(_server)} didn't have a stream for this track "
                  'when Linthra asked.',
            PlaybackFailureCause.unrecognized =>
              "Playback stopped, and Linthra couldn't tell why.",
            _ => "Linthra couldn't get this track from $_server.",
          },
        PlaybackFailureKind.localFileUnavailable =>
          "The file isn't where your library has it, or can't be read there. "
              'It may have been moved or deleted, or its drive may be '
              'disconnected.',
        PlaybackFailureKind.sourceSignInRequired => switch (failure.cause) {
            PlaybackFailureCause.notSignedIn =>
              "No account is signed in for $_server.",
            _ => '${_capitalized(_server)} turned the current sign-in down.',
          },
        PlaybackFailureKind.unplayableMedia =>
          "The audio engine couldn't play this track's audio. That can be a "
              "format this device can't decode or a damaged file, and Linthra "
              "can't tell which.",
        PlaybackFailureKind.playbackEngineUnavailable =>
          "The audio engine on this machine isn't working, so no track can "
              'play until it is.',
      };

  /// What the last check of the track's source found, when Linthra has one.
  /// Null when there's nothing known to say.
  String? get sourceState {
    final String? name = sourceName;
    final SourceAvailability? state = availability;
    if (name == null || state == null) return null;
    return switch (state) {
      SourceAvailability.available =>
        'Your $name account is set up, and the server answered the last check.',
      SourceAvailability.unreachable =>
        "Your $name account is still set up. The last check couldn't reach "
            'the server.',
      SourceAvailability.authenticationError =>
        'Your $name account is still set up, but the server turned its '
            'sign-in down on the last check.',
      SourceAvailability.notConfigured => 'No $name account is set up.',
      SourceAvailability.checking => null,
    };
  }

  /// What Linthra already did about it, when that shows in the failure.
  /// Null when there's nothing to say.
  String? get attempted {
    final PlaybackFailureKind kind = failure.kind;
    if (!kind.isWorthRetrying || kind.isEngineFailure || failure.canRetry) {
      return null;
    }
    return 'Linthra already tried this track again as many times as it will, '
        "so Retry isn't offered any more.";
  }

  /// What the listener can do next.
  String get nextStep => switch (failure.kind) {
        PlaybackFailureKind.temporarySource => switch (failure.cause) {
            PlaybackFailureCause.serverReturnedWebPage =>
              'A sign-in page or a proxy in front of the server answers like '
                  'this. Check the server address in Settings.',
            PlaybackFailureCause.invalidStream ||
            PlaybackFailureCause.streamUnavailable =>
              'Try again in a moment, or play another copy of the song if one '
                  'is offered.',
            _ => "Check this device's connection to the server, then try "
                'again.',
          },
        PlaybackFailureKind.localFileUnavailable =>
          'Reconnect the drive or put the file back, then try again. If the '
              'file moved, a rescan of its folder finds it.',
        PlaybackFailureKind.sourceSignInRequired => switch (failure.cause) {
            PlaybackFailureCause.notSignedIn =>
              'Sign in to ${sourceName ?? 'the server'} in Settings.',
            _ => 'Sign in to ${sourceName ?? 'the server'} again in Settings '
                'to continue.',
          },
        PlaybackFailureKind.unplayableMedia =>
          'Play another copy of the song if one is offered, or skip it.',
        PlaybackFailureKind.playbackEngineUnavailable => switch (
              runtimeProblem) {
            LinuxPlaybackRuntimeProblem.libraryMissing =>
              'Install libmpv from your distribution, then try again.',
            LinuxPlaybackRuntimeProblem.libraryUnloadable =>
              "libmpv is there but couldn't be loaded. Reinstall it from your "
                  'distribution, then try again.',
            LinuxPlaybackRuntimeProblem.libraryIncompatible =>
              "The libmpv on this machine doesn't match this build of "
                  "Linthra. Install your distribution's own libmpv, then try "
                  'again.',
            LinuxPlaybackRuntimeProblem.backendInitializationFailed =>
              "libmpv loaded, but the audio backend didn't start. The "
                  'diagnostics below help with a bug report.',
            null => 'The audio runtime on this machine (libmpv) needs '
                'attention. Fix it, then try again.',
          },
      };

  static String _capitalized(String text) =>
      text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);
}

/// Everything the copyable report of a playback failure is rendered from.
///
/// Display-safe by construction, like `AppDiagnosticsData`: enums, flags,
/// counts, fixed labels and a hashed track id. There is no field for the
/// failure's message, the track's title or uri, a server address, a path, or
/// anything quoted from an error.
@immutable
class PlaybackFailureReportData {
  const PlaybackFailureReportData({
    required this.details,
    required this.appVersion,
    this.platform,
    this.androidVersion,
    this.androidSdkInt,
    this.sourceStatus,
    this.playbackStatus,
    this.trackIdHash,
    this.platformAudioFormats,
    this.flacDecoding,
  });

  final PlaybackFailureDetails details;
  final String appVersion;

  /// The host platform's name (`linux`, `android`).
  final String? platform;

  final String? androidVersion;
  final int? androidSdkInt;

  /// The settings' own status line for the track's source, as the app
  /// diagnostics render it (`configured (server unreachable)`, `selected`).
  final String? sourceStatus;

  /// The playback status's enum name.
  final String? playbackStatus;

  /// `PlaybackDiagnostics.redactId` of the failed track's id.
  final String? trackIdHash;

  /// The formats the platform decodes, when known (Android).
  final List<String>? platformAudioFormats;

  /// Which FLAC decoders the device has, when known (Android).
  final String? flacDecoding;
}

/// The compact block "Copy diagnostics" puts on the clipboard, for pasting
/// into an issue.
abstract final class PlaybackFailureReport {
  static String render(PlaybackFailureReportData data) {
    final PlaybackFailure failure = data.details.failure;
    final List<String> offered = <String>[
      for (final PlaybackRecoveryAction action in failure.actions)
        switch (action) {
          PlaybackRecoveryAction.retry => 'retry',
          PlaybackRecoveryAction.tryAnotherSource => 'another source',
          PlaybackRecoveryAction.skip => 'skip',
        },
    ];
    final String? source = data.details.sourceName;
    final LinuxPlaybackRuntimeProblem? runtime = data.details.runtimeProblem;
    return <String>[
      'Linthra playback failure',
      'App version: ${data.appVersion}',
      if (_has(data.platform)) 'Platform: ${data.platform}',
      if (_has(data.androidVersion)) 'Android: ${data.androidVersion}',
      if (data.androidSdkInt != null) 'Android SDK: ${data.androidSdkInt}',
      'Failure: ${failure.kind.name}',
      'Cause: ${failure.cause?.name ?? 'unknown'}',
      if (source != null) 'Source: $source',
      if (source != null && _has(data.sourceStatus))
        '$source status: ${data.sourceStatus}',
      if (data.details.availability != null)
        'Last source check: ${data.details.availability!.name}',
      if (_has(data.playbackStatus)) 'Playback state: ${data.playbackStatus}',
      if (_has(data.trackIdHash)) 'Track: ${data.trackIdHash}',
      'Offered: ${offered.isEmpty ? 'nothing' : offered.join(', ')}',
      if (runtime != null) 'Linux audio runtime: ${runtime.label}',
      if (data.platformAudioFormats != null)
        'Platform audio decoders: '
            '${data.platformAudioFormats!.isEmpty ? 'none' : data.platformAudioFormats!.join(', ')}',
      if (_has(data.flacDecoding)) 'FLAC decoding: ${data.flacDecoding}',
    ].join('\n');
  }

  static bool _has(String? value) => value != null && value.isNotEmpty;
}
