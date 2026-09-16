import '../../core/repositories/keyboard_shortcut_preferences.dart';

/// A non-persistent [KeyboardShortcutPreferences] for tests and dev runs.
///
/// The default binding, mirroring the other repositories, so a widget test can
/// pump the app with no `shared_preferences` plugin registered.
class InMemoryKeyboardShortcutPreferences
    implements KeyboardShortcutPreferences {
  InMemoryKeyboardShortcutPreferences({
    Map<String, String>? initialOverrides,
  }) : _overrides = <String, String>{...?initialOverrides};

  final Map<String, String> _overrides;

  @override
  Future<Map<String, String>> overrides() async =>
      Map<String, String>.unmodifiable(_overrides);

  @override
  Future<void> setOverride(String storageKey, String? binding) async {
    if (binding == null) {
      _overrides.remove(storageKey);
      return;
    }
    _overrides[storageKey] = binding;
  }

  @override
  Future<void> clear() async => _overrides.clear();
}
