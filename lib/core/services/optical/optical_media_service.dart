import '../../models/optical_media.dart';

/// Reports which optical drives this machine has and whether an audio CD is in
/// one of them.
///
/// This is a *detection* seam and nothing else. It opens no disc, reads no
/// table of contents, mounts nothing, writes nothing and plays nothing — those
/// are the later parts of #631 and they build on top of this rather than
/// inside it. Keeping the boundary here is what lets the state machine above
/// be tested with no drive, no disc and no D-Bus anywhere near the machine
/// running the tests.
///
/// Implementations must never throw into their caller. A host with no
/// detection service, a refused connection, a drive that vanished mid-look —
/// all of them come back as an [OpticalMediaSnapshot] value, because "Linthra
/// could not tell" is an answer a UI can show and an exception is not.
abstract interface class OpticalMediaService {
  /// Whether this build can look for optical drives at all.
  ///
  /// Answerable without touching the host: it is a fact about the platform and
  /// the packaging, not about the hardware. `false` off Linux, and `false`
  /// inside the Flatpak today (see `docs/optical-media.md`), so a caller can
  /// leave a disc section out entirely rather than showing one that can only
  /// ever say "no drive".
  bool get isSupported;

  /// Looks now, and reports what the host says.
  ///
  /// The one-shot read: what a "refresh" action calls, and what a caller uses
  /// to get a first answer before [changes] has anything to report. Cheap —
  /// one query to a service that already knows — and never a device scan.
  Future<OpticalMediaSnapshot> inspect();

  /// Emits a new snapshot whenever the host's optical state changes: a disc
  /// inserted or ejected, a USB drive plugged in or pulled out, a disc that
  /// finished being identified.
  ///
  /// Event-driven, never polled (see `LinuxOpticalMediaService`), and
  /// deduplicated: a snapshot equal to the last one published is not
  /// republished, so a burst of platform events about one insertion is one
  /// event here.
  ///
  /// Each event is the whole picture, in the same shape [inspect] returns, so
  /// a listener that joined late or missed an event is still correct. A
  /// broadcast stream: several listeners are fine and none of them changes
  /// what the others see. Implementations that cannot observe return an empty
  /// stream rather than throwing, so a caller never has to ask whether
  /// watching is supported before listening.
  Stream<OpticalMediaSnapshot> get changes;

  /// Releases whatever the implementation holds — a bus connection, a
  /// subscription, a stream controller.
  ///
  /// Must be safe to call more than once, and safe to call while a look is in
  /// flight: the app's shutdown does not get to wait for a drive that is still
  /// spinning up.
  Future<void> dispose();
}
