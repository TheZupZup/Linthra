/// Persists the user's selected app-icon / branding variant.
///
/// The stored value is a single non-secret variant id (e.g. `classic`,
/// `neon`), or `null` when the user has not chosen one (the default, which
/// resolves to Classic). It carries no credential, URL, or library content, so
/// a lightweight key/value store is the right weight — the same reasoning the
/// default-provider store follows.
abstract interface class AppIconVariantStore {
  /// The persisted variant id, or `null` when the user has not chosen one.
  Future<String?> read();

  /// Persists [variantId], or clears the choice (back to the default) when
  /// `null` or empty.
  Future<void> write(String? variantId);
}
