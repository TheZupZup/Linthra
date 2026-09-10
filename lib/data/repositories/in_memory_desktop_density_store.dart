import '../../core/models/desktop_density.dart';
import '../../core/repositories/desktop_density_store.dart';

/// Test-friendly [DesktopDensityStore] that keeps one value in memory.
class InMemoryDesktopDensityStore implements DesktopDensityStore {
  InMemoryDesktopDensityStore([this._density]);

  DesktopDensity? _density;

  /// The last written value, for assertions.
  DesktopDensity? get density => _density;

  @override
  Future<DesktopDensity?> read() async => _density;

  @override
  Future<void> write(DesktopDensity density) async {
    _density = density;
  }
}
