import '../models/custom_theme_settings.dart';

/// Persists the user's optional custom color palette.
///
/// The values are non-secret visual preferences only. No account, server,
/// library, or playback data is stored here.
abstract interface class CustomThemeStore {
  /// Returns the stored settings, or `null` when the user has never customized
  /// the palette.
  Future<CustomThemeSettings?> read();

  /// Persists [settings], or clears the customization when `null`.
  Future<void> write(CustomThemeSettings? settings);
}
