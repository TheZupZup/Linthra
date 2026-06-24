/// Switches the device's **real** Android launcher icon to match a selected
/// branding variant.
///
/// This is the seam the Appearance picker drives so that choosing a variant also
/// changes the icon on the home screen / app drawer (not just the in-app mark).
/// It is intentionally tiny and best-effort: implementations must never throw
/// into the UI, and on a platform or device without runtime icon switching the
/// no-op binding ([isSupported] == false) keeps the in-app selection working
/// unchanged.
abstract interface class LauncherIconService {
  /// Whether real launcher-icon switching is available here. `false` off
  /// Android (and in tests), so the UI can skip the "icon updated" hint and the
  /// feature degrades to in-app branding only.
  bool get isSupported;

  /// Applies the launcher icon for [variantId] (an `AppIconVariant.id`).
  ///
  /// Returns `true` when the switch was applied. Implementations resolve the id
  /// to a launcher alias via `LauncherIconAliases` and must swallow platform
  /// errors, returning `false` rather than throwing, so a failed or unsupported
  /// switch can never break selection or playback.
  Future<bool> applyVariant(String variantId);
}
