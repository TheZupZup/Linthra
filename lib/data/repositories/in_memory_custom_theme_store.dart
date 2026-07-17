import '../../core/models/custom_theme_settings.dart';
import '../../core/repositories/custom_theme_store.dart';

/// Test-friendly [CustomThemeStore] that keeps one value in memory.
class InMemoryCustomThemeStore implements CustomThemeStore {
  InMemoryCustomThemeStore([this._settings]);

  CustomThemeSettings? _settings;

  @override
  Future<CustomThemeSettings?> read() async => _settings;

  @override
  Future<void> write(CustomThemeSettings? settings) async {
    _settings = settings;
  }
}
