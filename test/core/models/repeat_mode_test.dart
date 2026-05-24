import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/repeat_mode.dart';

void main() {
  group('RepeatMode', () {
    test('next cycles off -> all -> one -> off', () {
      expect(RepeatMode.off.next, RepeatMode.all);
      expect(RepeatMode.all.next, RepeatMode.one);
      expect(RepeatMode.one.next, RepeatMode.off);
    });

    test('cycling three times returns to the start', () {
      var mode = RepeatMode.off;
      mode = mode.next;
      mode = mode.next;
      mode = mode.next;
      expect(mode, RepeatMode.off);
    });

    test('supports off, all, and one', () {
      expect(
          RepeatMode.values,
          containsAll(<RepeatMode>[
            RepeatMode.off,
            RepeatMode.all,
            RepeatMode.one,
          ]));
    });
  });
}
