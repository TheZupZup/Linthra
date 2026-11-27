// The player's rules, which run in the Rust core
// (native/linthra_core/src/playback_rules.rs), through the calls the player
// makes: what an engine error reads as, the failure it records, and what an
// audio focus change asks for.
//
// Engine errors are free text, so they are held to the cases in
// test/fixtures/playback_error_cases.txt, which the Rust tests replay too.
// Every [_errors] case must be in it.
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_failure.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/playback_failure_classifier.dart';
import 'package:linthra/core/services/stream_interruption.dart';

const String _fixture = 'test/fixtures/playback_error_cases.txt';

/// Engine errors as the platforms word them, and the traps around them: a
/// status inside a location, a status line's `HTTP/1.1`, an `I/O`.
const List<String> _errors = <String>[
  '(4005) Source error',
  ' (4005) Source error',
  'HTTP/1.1 403 Forbidden',
  'HTTP/1.1x 403',
  'http/2 stream reset by peer',
  'I/O error',
  'I/O error 401',
  'ClientException: Connection closed while receiving data, '
      'uri=https://music.example/Items/401abc/stream?api_key=403',
  "Failed host lookup: 'jellyfin.local'",
  'Connection refused',
  'Network is unreachable',
  'SocketException: OS Error: Connection reset by peer, errno = 104',
  'Unable to instantiate decoder',
  'Parse error in /tmp/stream',
  'UnrecognizedInputFormatException: None of the available extractors',
  'Source error',
  'Timeout\nafter /storage/emulated/401/x',
  'UNAUTHORIZED',
  'EOF',
  'file:///sdcard/Music/403.mp3 not found',
  "open '/home/Ada Lovelace/401/song.flac': Permission denied",
  '/home/Ada Lovelace/403.flac: no such file',
  'a / 401 b',
  'Ünicode timeout',
  'something odd happened',
  '',
];

String _escape(String text) => text
    .replaceAll('\\', r'\\')
    .replaceAll('\t', r'\t')
    .replaceAll('\n', r'\n');

String _unescape(String text) {
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < text.length; i++) {
    if (text[i] != '\\') {
      out.write(text[i]);
      continue;
    }
    i++;
    out.write(switch (text[i]) { 't' => '\t', 'n' => '\n', _ => text[i] });
  }
  return out.toString();
}

void main() {
  final List<(String, String)> cases = <(String, String)>[
    for (final String line in File(_fixture).readAsLinesSync())
      if (line.isNotEmpty && !line.startsWith('#'))
        (
          _unescape(line.substring(0, line.lastIndexOf('\t'))),
          line.substring(line.lastIndexOf('\t') + 1),
        ),
  ];

  test('every engine error reads as its case says', () {
    for (final (String error, String kind) in cases) {
      final StreamInterruption read = classifyEngineError(error);
      expect(read.kind.name, kind, reason: error);
      // A fixed message: nothing of the engine's text is shown.
      expect(read.message, isNot(contains('example')), reason: error);
    }
    expect(
      <String>[for (final (String error, _) in cases) error],
      containsAll(_errors.map(_escape).map(_unescape)),
    );
  });

  test('a session the server refuses asks for a sign-in, not a retry', () {
    final StreamInterruption refused = classifyEngineError('HTTP 401');
    expect(refused.kind, StreamInterruptionKind.sessionExpired);
    expect(refused.retryable, isFalse);
    expect(classifyEngineError('Connection reset').retryable, isTrue);
  });

  test('every resolution failure maps to its kind and cause', () {
    const Map<PlaybackResolutionErrorKind,
            (PlaybackFailureKind, PlaybackFailureCause)>
        expected = <PlaybackResolutionErrorKind,
            (PlaybackFailureKind, PlaybackFailureCause)>{
      PlaybackResolutionErrorKind.notSignedIn: (
        PlaybackFailureKind.sourceSignInRequired,
        PlaybackFailureCause.notSignedIn
      ),
      PlaybackResolutionErrorKind.sessionExpired: (
        PlaybackFailureKind.sourceSignInRequired,
        PlaybackFailureCause.sessionExpired
      ),
      PlaybackResolutionErrorKind.serverUnreachable: (
        PlaybackFailureKind.temporarySource,
        PlaybackFailureCause.serverUnreachable
      ),
      PlaybackResolutionErrorKind.invalidStream: (
        PlaybackFailureKind.temporarySource,
        PlaybackFailureCause.invalidStream
      ),
      PlaybackResolutionErrorKind.serverReturnedWebPage: (
        PlaybackFailureKind.temporarySource,
        PlaybackFailureCause.serverReturnedWebPage
      ),
      PlaybackResolutionErrorKind.streamUnavailable: (
        PlaybackFailureKind.temporarySource,
        PlaybackFailureCause.streamUnavailable
      ),
      PlaybackResolutionErrorKind.localFileMissing: (
        PlaybackFailureKind.localFileUnavailable,
        PlaybackFailureCause.fileUnavailable
      ),
      PlaybackResolutionErrorKind.mediaUnsupported: (
        PlaybackFailureKind.unplayableMedia,
        PlaybackFailureCause.audioNotDecoded
      ),
      PlaybackResolutionErrorKind.playbackEngineUnavailable: (
        PlaybackFailureKind.playbackEngineUnavailable,
        PlaybackFailureCause.engineUnavailable
      ),
    };
    expect(expected.keys, containsAll(PlaybackResolutionErrorKind.values));
    expected.forEach((kind, failure) {
      expect(playbackFailureKindForResolution(kind), failure.$1,
          reason: kind.name);
      expect(playbackFailureCauseForResolution(kind), failure.$2,
          reason: kind.name);
    });
  });

  test('every interruption maps to its kind and cause', () {
    const Map<StreamInterruptionKind,
            (PlaybackFailureKind, PlaybackFailureCause)> expected =
        <StreamInterruptionKind, (PlaybackFailureKind, PlaybackFailureCause)>{
      StreamInterruptionKind.networkDropped: (
        PlaybackFailureKind.temporarySource,
        PlaybackFailureCause.connectionDropped
      ),
      StreamInterruptionKind.serverUnreachable: (
        PlaybackFailureKind.temporarySource,
        PlaybackFailureCause.serverUnreachable
      ),
      StreamInterruptionKind.sessionExpired: (
        PlaybackFailureKind.sourceSignInRequired,
        PlaybackFailureCause.sessionExpired
      ),
      StreamInterruptionKind.formatUnsupported: (
        PlaybackFailureKind.unplayableMedia,
        PlaybackFailureCause.audioNotDecoded
      ),
      StreamInterruptionKind.localFileUnavailable: (
        PlaybackFailureKind.localFileUnavailable,
        PlaybackFailureCause.fileUnavailable
      ),
      StreamInterruptionKind.unknown: (
        PlaybackFailureKind.temporarySource,
        PlaybackFailureCause.unrecognized
      ),
    };
    expect(expected.keys, containsAll(StreamInterruptionKind.values));
    expected.forEach((kind, failure) {
      expect(playbackFailureKindForInterruption(kind), failure.$1,
          reason: kind.name);
      expect(playbackFailureCauseForInterruption(kind), failure.$2,
          reason: kind.name);
    });
  });

  test('every audio focus change asks for its action', () {
    const Map<(bool, AudioInterruptionType), AudioFocusAction> expected =
        <(bool, AudioInterruptionType), AudioFocusAction>{
      (true, AudioInterruptionType.pause): AudioFocusAction.pauseTransient,
      (true, AudioInterruptionType.unknown): AudioFocusAction.pausePermanent,
      (true, AudioInterruptionType.duck): AudioFocusAction.duck,
      (false, AudioInterruptionType.pause): AudioFocusAction.resume,
      (false, AudioInterruptionType.unknown): AudioFocusAction.resume,
      (false, AudioInterruptionType.duck): AudioFocusAction.unduck,
    };
    expected.forEach((input, action) {
      expect(
        JustAudioPlaybackController.audioFocusAction(
          AudioInterruptionEvent(input.$1, input.$2),
        ),
        action,
        reason: '$input',
      );
    });
  });
}
