import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/shared_preferences_write.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

/// Preferences whose first write answers only once [refuseFirst] completes,
/// and then refuses. Every later write goes through at once.
class _SlowFirstRefusal extends InMemorySharedPreferencesStore {
  _SlowFirstRefusal() : super.empty();

  final Completer<void> refuseFirst = Completer<void>();
  int _writes = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (_writes++ == 0) {
      await refuseFirst.future;
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'a refused write puts back nothing over a later one to the same key '
      'that went through', () async {
    final _SlowFirstRefusal disk = _SlowFirstRefusal();
    SharedPreferencesStorePlatform.instance = disk;
    SharedPreferences.resetStatic();
    addTearDown(() {
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.empty();
      SharedPreferences.resetStatic();
    });
    final SharedPreferences prefs = await SharedPreferences.getInstance();

    final Future<bool> first =
        writeOrRestore(prefs, 'k', () => prefs.setString('k', 'first'));
    expect(
      await writeOrRestore(prefs, 'k', () => prefs.setString('k', 'second')),
      isTrue,
    );
    disk.refuseFirst.complete();

    expect(await first, isFalse);
    expect(prefs.getString('k'), 'second');
    expect((await disk.getAll())['flutter.k'], 'second');
  });
}
