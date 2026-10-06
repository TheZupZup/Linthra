import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/shared_preferences_local_tag_revision_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  const SharedPreferencesLocalTagRevisionStore store =
      SharedPreferencesLocalTagRevisionStore();

  test('round-trips the revision of each folder', () async {
    await store.save(<String, int>{'/music': 1, '/media/usb': 2});

    expect(await store.load(), <String, int>{'/music': 1, '/media/usb': 2});
  });

  test('nothing stored reads as nothing recorded', () async {
    expect(await store.load(), isEmpty);
  });

  test('a corrupt record reads as nothing recorded', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'local_tag_revisions_v1': 'not json {',
    });

    expect(await store.load(), isEmpty);
  });

  test('an entry that is not a revision is left out', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'local_tag_revisions_v1': '{"/music": 1, "/media/usb": "2", "": 3}',
    });

    expect(await store.load(), <String, int>{'/music': 1});
  });
}
