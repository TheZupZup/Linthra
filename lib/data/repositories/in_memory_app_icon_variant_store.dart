import '../../core/repositories/app_icon_variant_store.dart';

/// An in-memory [AppIconVariantStore] for tests and the default provider
/// binding.
///
/// Holds the selected variant id in a field so widget and unit tests stay free
/// of platform plugins; the running app swaps in the `shared_preferences`
/// implementation so the choice persists across restarts. An optional [initial]
/// value seeds a "already chosen" state for tests.
class InMemoryAppIconVariantStore implements AppIconVariantStore {
  InMemoryAppIconVariantStore([String? initial])
      : _variantId = (initial == null || initial.isEmpty) ? null : initial;

  String? _variantId;

  @override
  Future<String?> read() async => _variantId;

  @override
  Future<void> write(String? variantId) async {
    _variantId = (variantId == null || variantId.isEmpty) ? null : variantId;
  }
}
