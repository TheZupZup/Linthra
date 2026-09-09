import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/desktop_close_behavior.dart';

void main() {
  test('quit is what a fresh install gets', () {
    expect(DesktopCloseBehavior.defaultBehavior, DesktopCloseBehavior.quit);
  });

  test('every value survives a round trip through storage', () {
    for (final DesktopCloseBehavior behavior in DesktopCloseBehavior.values) {
      expect(
        DesktopCloseBehavior.fromStorage(behavior.storageValue),
        behavior,
      );
    }
  });

  test('an unknown or missing stored value reads as quit', () {
    // A value written by a newer build, or a corrupted entry: the app has to
    // start, and the behaviour it starts with is the conservative one.
    expect(DesktopCloseBehavior.fromStorage(null), DesktopCloseBehavior.quit);
    expect(DesktopCloseBehavior.fromStorage(''), DesktopCloseBehavior.quit);
    expect(
      DesktopCloseBehavior.fromStorage('minimise_to_tray'),
      DesktopCloseBehavior.quit,
    );
  });

  test('stored values are stable strings, not enum names or indexes', () {
    // Renaming or reordering the enum must not change what an installed copy
    // of Linthra reads back out of storage.
    expect(DesktopCloseBehavior.quit.storageValue, 'quit');
    expect(DesktopCloseBehavior.keepPlaying.storageValue, 'keep_playing');
  });
}
