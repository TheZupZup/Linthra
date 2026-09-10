import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/desktop_density.dart';
import '../../core/repositories/desktop_density_store.dart';

/// Persists the desktop density choice as a single non-secret string.
class SharedPreferencesDesktopDensityStore implements DesktopDensityStore {
  const SharedPreferencesDesktopDensityStore();

  static const String _key = 'desktop_density_v1';

  @override
  Future<DesktopDensity?> read() async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final String? stored = preferences.getString(_key);
    if (stored == null) return null;
    // An unrecognised value (a downgrade, or a hand-edited preference file)
    // resolves to the default rather than throwing.
    return DesktopDensity.fromStorageId(stored);
  }

  @override
  Future<void> write(DesktopDensity density) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.setString(_key, density.storageId);
  }
}
