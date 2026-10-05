import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/shared/format/playback_time.dart';

void main() {
  test('prints minutes and seconds under an hour', () {
    expect(formatPlaybackTime(Duration.zero), '0:00');
    expect(formatPlaybackTime(const Duration(seconds: 9)), '0:09');
    expect(formatPlaybackTime(const Duration(minutes: 4, seconds: 5)), '4:05');
    expect(
        formatPlaybackTime(const Duration(minutes: 59, seconds: 59)), '59:59');
  });

  test('widens to hours past an hour', () {
    expect(formatPlaybackTime(const Duration(hours: 1)), '1:00:00');
    expect(
      formatPlaybackTime(const Duration(hours: 2, minutes: 3, seconds: 4)),
      '2:03:04',
    );
  });

  test('drops the milliseconds rather than rounding them up', () {
    expect(
      formatPlaybackTime(const Duration(seconds: 59, milliseconds: 999)),
      '0:59',
    );
  });
}
