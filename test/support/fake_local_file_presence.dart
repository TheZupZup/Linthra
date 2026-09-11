import 'package:linthra/core/services/local_playable_uri_resolver.dart';

/// A [LocalFilePresence] backed by a set of paths, so a test can say which
/// on-device files exist without writing any.
///
/// [FakeLocalFilePresence.all] is the "nothing has gone missing" default that
/// tests about something *other* than a vanished file want.
class FakeLocalFilePresence implements LocalFilePresence {
  FakeLocalFilePresence(this.present);

  /// Every file exists. The shape most tests need.
  FakeLocalFilePresence.all() : present = null;

  /// The paths that exist, or null when everything does.
  Set<String>? present;

  /// Paths this was asked about, in order, so a test can prove the probe
  /// happened (or didn't).
  final List<String> probed = <String>[];

  @override
  bool existsAt(String path) {
    probed.add(path);
    return present?.contains(path) ?? true;
  }
}
