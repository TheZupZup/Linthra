import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins how the vendored Android player answers a seek that is in flight when
/// playback fails (change 4 in third_party/just_audio/PATCHES.md).
///
/// Neither way this can break shows up off a device: the seek never returns
/// (upstream's behaviour), or it is rejected, and the failure the controller
/// already handles from the event stream comes back a second time as an
/// unhandled PlatformException from a seek nobody awaited (the progress bar
/// and the lyrics view fire theirs and move on).
void main() {
  final String java = File(
    'third_party/just_audio/android/src/main/java/com/ryanheise/just_audio/'
    'AudioPlayer.java',
  ).readAsStringSync();

  /// The body of the method declared by [signature], braces included.
  String body(String signature) {
    final int start = java.indexOf(signature);
    expect(start, isNot(-1), reason: '$signature is gone');
    final int open = java.indexOf('{', start);
    int depth = 0;
    for (int i = open; i < java.length; i++) {
      if (java[i] == '{') depth++;
      if (java[i] == '}' && --depth == 0) return java.substring(open, i + 1);
    }
    fail('unbalanced braces after $signature');
  }

  test('every failure goes out through sendError', () {
    expect(RegExp(r'eventChannel\.error\(').allMatches(java), hasLength(1));
    expect(
      body('private void sendError(String errorCode, String errorMsg, '
          'Object details)'),
      contains('eventChannel.error('),
    );
    expect(
      body('public void onPlayerError(PlaybackException error)'),
      contains('sendError('),
    );
  });

  test('a failure releases the pending seek, after reporting itself', () {
    final String sendError = body(
      'private void sendError(String errorCode, String errorMsg, '
      'Object details)',
    );
    expect(sendError, contains('abortSeek();'));
    expect(
      sendError.indexOf('abortSeek();'),
      greaterThan(sendError.indexOf('eventChannel.error(')),
      reason: 'the controller must hear the failure before the seek returns',
    );
  });

  test('a pending seek is only ever answered with success', () {
    expect(java, isNot(contains('seekResult.error(')));
    expect(body('private void abortSeek()'), contains('seekResult.success('));
  });
}
