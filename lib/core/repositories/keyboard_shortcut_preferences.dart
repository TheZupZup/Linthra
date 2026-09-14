/// The user's keyboard-shortcut overrides (issue #391).
///
/// Deliberately string-to-string. The store knows nothing about which actions
/// exist or what a binding means: it holds whatever the shortcut layer asked it
/// to hold, keyed by that layer's stable storage keys. Keeping it dumb is what
/// lets `core/` own the interface without depending on the app layer, and it
/// means a build that adds an action, renames one, or tightens what a binding
/// may be needs no migration here — the shortcut layer simply ignores a key it
/// no longer knows, and falls back to the default for one it cannot parse.
///
/// Only overrides are stored. An action the user never touched has no row, so
/// changing a default in a later release reaches everybody who never disagreed
/// with it, and nobody who did.
abstract interface class KeyboardShortcutPreferences {
  /// Every stored override, keyed by
  /// `ShortcutActionDefinition.storageKey`. Empty when the user has changed
  /// nothing, which is the ordinary case.
  Future<Map<String, String>> overrides();

  /// Stores [binding] for [storageKey], or removes the override when it is
  /// null (which returns that action to its default).
  Future<void> setOverride(String storageKey, String? binding);

  /// Forgets every override, returning every action to its default.
  Future<void> clear();
}
