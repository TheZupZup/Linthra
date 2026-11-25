// The player's rules give the same answers in Dart and in the Rust core
// (native/linthra_core/src/playback_rules.rs).
//
// Engine errors are free text, so they are held to the cases in
// test/fixtures/playback_error_cases.txt, which the Rust tests replay too.
// Everything else takes enum codes, so every input is compared outright.
//
// To add an error case, add it to [_errors] and rewrite the file from the
// Dart rule, then review its diff:
//
//     LINTHRA_WRITE_PLAYBACK_FIXTURES=1 flutter test test/core/services/playback_rules_parity_test.dart
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_failure.dart';
import 'package:linthra/core/native/linthra_core.dart';
import 'package:linthra/core/services/just_audio_playback_controller.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/playback_failure_classifier.dart';
import 'package:linthra/core/services/playback_recovery_policy.dart';
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
  final bool write =
      Platform.environment['LINTHRA_WRITE_PLAYBACK_FIXTURES'] == '1';
  final Object skip =
      LinthraCore.isAvailable ? false : 'Rust core not built in this build';

  test('the error fixture is what the Dart rule says', () {
    final List<String> lines = <String>[
      for (final String error in _errors)
        '${_escape(error)}\t${classifyEngineError(error, useNative: false).kind.name}',
    ];
    if (write) {
      File(_fixture).writeAsStringSync('''
# Engine errors and the StreamInterruptionKind each one reads as. Written from
# the Dart rule by test/core/services/playback_rules_parity_test.dart, which
# holds the Rust core to it too, as does
# native/linthra_core/src/playback_rules.rs. TAB-separated: the error (\\t,
# \\n and \\\\ escaped), then the kind.
${lines.join('\n')}
''');
    }
    final List<String> stored = File(_fixture)
        .readAsLinesSync()
        .where((String line) => line.isNotEmpty && !line.startsWith('#'))
        .toList();
    expect(stored, lines);
  });

  test('the Rust core reads every engine error the same way', skip: skip, () {
    for (final String line in File(_fixture).readAsLinesSync()) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final int tab = line.lastIndexOf('\t');
      final String error = _unescape(line.substring(0, tab));
      final StreamInterruption native = classifyEngineError(error);
      expect(native.kind.name, line.substring(tab + 1), reason: error);
      final StreamInterruption dart =
          classifyEngineError(error, useNative: false);
      expect(native.message, dart.message, reason: error);
      expect(native.retryable, dart.retryable, reason: error);
    }
  });

  test('every failure mapping matches', skip: skip, () {
    for (final PlaybackResolutionErrorKind kind
        in PlaybackResolutionErrorKind.values) {
      expect(playbackFailureKindForResolution(kind),
          playbackFailureKindForResolution(kind, useNative: false),
          reason: kind.name);
      expect(playbackFailureCauseForResolution(kind),
          playbackFailureCauseForResolution(kind, useNative: false),
          reason: kind.name);
    }
    for (final StreamInterruptionKind kind in StreamInterruptionKind.values) {
      expect(playbackFailureKindForInterruption(kind),
          playbackFailureKindForInterruption(kind, useNative: false),
          reason: kind.name);
      expect(playbackFailureCauseForInterruption(kind),
          playbackFailureCauseForInterruption(kind, useNative: false),
          reason: kind.name);
    }
  });

  test('every recovery decision matches', skip: skip, () {
    const List<PlaybackRecoveryPolicy> policies = <PlaybackRecoveryPolicy>[
      PlaybackRecoveryPolicy(),
      PlaybackRecoveryPolicy(
        retryDelay: Duration(seconds: 3),
        advanceDelay: Duration(seconds: 2),
        maxAdvanceDelay: Duration(seconds: 30),
        maxConsecutiveFailures: 4,
      ),
      PlaybackRecoveryPolicy(maxConsecutiveFailures: 1),
    ];
    int compared = 0;
    for (final PlaybackRecoveryPolicy native in policies) {
      final PlaybackRecoveryPolicy dart = PlaybackRecoveryPolicy(
        retryDelay: native.retryDelay,
        advanceDelay: native.advanceDelay,
        maxAdvanceDelay: native.maxAdvanceDelay,
        maxConsecutiveFailures: native.maxConsecutiveFailures,
        useNative: false,
      );
      for (final PlaybackFailureKind kind in PlaybackFailureKind.values) {
        for (int failures = 0; failures <= 7; failures++) {
          for (final bool retrySpent in <bool>[false, true]) {
            for (final String? next in <String?>[
              null,
              'failed',
              'old',
              'new'
            ]) {
              final PlaybackFailureStreak streak = PlaybackFailureStreak();
              for (int i = 0; i < failures; i++) {
                streak.record('old');
              }
              if (retrySpent) streak.noteRetry();
              PlaybackRecoveryDecision decide(PlaybackRecoveryPolicy p) =>
                  p.decide(
                    kind: kind,
                    failedUri: 'failed',
                    nextUri: next,
                    streak: streak,
                  );
              final PlaybackRecoveryDecision a = decide(native);
              final PlaybackRecoveryDecision b = decide(dart);
              expect('${a.step} ${a.delay}', '${b.step} ${b.delay}',
                  reason: '$kind failures=$failures spent=$retrySpent '
                      'next=$next');
              compared++;
            }
          }
        }
      }
    }
    expect(compared, 3 * 5 * 8 * 2 * 4);
  });

  test('every audio focus change maps the same way', skip: skip, () {
    for (final bool begin in <bool>[true, false]) {
      for (final AudioInterruptionType type in AudioInterruptionType.values) {
        final AudioInterruptionEvent event =
            AudioInterruptionEvent(begin, type);
        expect(
            JustAudioPlaybackController.audioFocusAction(event),
            JustAudioPlaybackController.audioFocusAction(event,
                useNative: false),
            reason: '$begin $type');
      }
    }
  });
}
