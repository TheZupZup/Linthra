import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/shared_preferences_desktop_notification_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('SharedPreferencesDesktopNotificationPreferences', () {
    const SharedPreferencesDesktopNotificationPreferences preferences =
        SharedPreferencesDesktopNotificationPreferences();

    test('nothing stored reads as off', () async {
      // The conservative default, and what a build without this feature did.
      expect(await preferences.trackChangeNotifications(), isFalse);
    });

    test('round-trips the choice', () async {
      await preferences.setTrackChangeNotifications(true);
      expect(await preferences.trackChangeNotifications(), isTrue);

      await preferences.setTrackChangeNotifications(false);
      expect(await preferences.trackChangeNotifications(), isFalse);
    });

    test('reads a value an earlier run stored', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'desktop_track_change_notifications': true,
      });

      expect(await preferences.trackChangeNotifications(), isTrue);
    });
  });
}
