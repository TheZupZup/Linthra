import '../../models/optical_media.dart';
import 'optical_media_service.dart';

/// An [OpticalMediaService] that looks at nothing and always answers
/// "unsupported".
///
/// It is the real implementation on every platform without optical-media
/// detection — Android above all, whose behaviour #631 must leave exactly as
/// it was — and the default binding everywhere else, so unit and widget tests
/// never open a bus.
///
/// It answers [OpticalMediaAvailability.unsupported] rather than "no drive" on
/// purpose. A phone has no optical drive *and* no way to look for one, and
/// only the second is true of every platform this class stands in for. The
/// difference is what lets a caller hide a disc section entirely instead of
/// showing an empty one.
class UnsupportedOpticalMediaService implements OpticalMediaService {
  const UnsupportedOpticalMediaService();

  @override
  bool get isSupported => false;

  @override
  Future<OpticalMediaSnapshot> inspect() async =>
      const OpticalMediaSnapshot.unsupported();

  /// Nothing to observe: an empty stream that closes immediately, so a
  /// listener is never left waiting on events that cannot come.
  @override
  Stream<OpticalMediaSnapshot> get changes =>
      const Stream<OpticalMediaSnapshot>.empty();

  @override
  Future<void> dispose() async {}
}
