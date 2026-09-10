import '../models/desktop_density.dart';

/// Persists the user's desktop Compact / Comfortable choice.
///
/// The value is a non-secret display preference only. No account, server,
/// library, or playback data is stored here.
abstract interface class DesktopDensityStore {
  /// Returns the stored density, or `null` when the user has never chosen one —
  /// which the caller resolves to [DesktopDensity.fallback].
  Future<DesktopDensity?> read();

  /// Persists [density].
  Future<void> write(DesktopDensity density);
}
