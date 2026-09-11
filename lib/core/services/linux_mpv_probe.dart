import 'dart:async';

import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';

import '../diagnostics/linux_playback_diagnostics.dart';

/// What a libmpv probe found.
///
/// Three states, not two, and the third one is the point: "nothing was playing
/// so nobody could be asked" and "a player exists and could not answer" are
/// different facts, and only the second is a backend failure worth reporting.
typedef LinuxMpvProbeResult = ({
  LibmpvAvailability availability,
  String? version,
});

/// Asks the live libmpv instance what it is, for the Linux playback
/// diagnostics report.
///
/// Two rules shape this, and both are about not making things worse:
///
///  * **It never creates a player.** Reading a version is not worth a second
///    libmpv handle, and a diagnostics view that spins one up would be exactly
///    the kind of thing that then shows up as a bug. When nothing is playing
///    there is no live player, and the probe honestly answers "not probed".
///  * **It never throws.** Every failure — no player, an uninitialised handle,
///    a property libmpv does not know, a wedged backend — comes back as a
///    value, never an exception. Missing optional information must not fail the
///    view. It does not come back as *silence* either: a player that exists and
///    will not answer is reported as [LibmpvAvailability.unavailable], because
///    a wedged backend reading as "available" would hide the exact failure this
///    report exists to show.
///
/// The one property it reads is `mpv-version`, a compile-time constant inside
/// libmpv. It asks for nothing else, so there is no way for this probe to
/// return a path, a URL, or anything about what is playing.
class LinuxMpvProbe {
  const LinuxMpvProbe();

  /// How long libmpv gets to answer before the probe gives up.
  static const Duration timeout = Duration(seconds: 2);

  /// The libmpv property read. Deliberately a single fixed name.
  static const String versionProperty = 'mpv-version';

  /// Probes the live backend, or reports that there was nothing to ask.
  Future<LinuxMpvProbeResult> probe() async {
    final Iterable<Player> live = JustAudioMediaKit.livePlayers.values;
    // Nothing is playing, so no player exists to ask. Not evidence of absence.
    if (live.isEmpty) {
      return (availability: LibmpvAvailability.notProbed, version: null);
    }
    try {
      final PlatformPlayer? platform = live.first.platform;
      if (platform is! NativePlayer) {
        // A live player Linthra cannot reach through media_kit's native handle:
        // there is nothing to ask, which is not the same as asking and failing.
        return (availability: LibmpvAvailability.notProbed, version: null);
      }
      final String value =
          await platform.getProperty(versionProperty).timeout(timeout);
      return (
        availability: LibmpvAvailability.available,
        version: value.isEmpty ? null : value,
      );
    } catch (_) {
      // A player exists and libmpv would not answer it — a timeout, an
      // uninitialised handle, a wedged backend. That is a failure of the
      // backend, and reporting it as "available" would hide precisely what
      // this report is for.
      return (availability: LibmpvAvailability.unavailable, version: null);
    }
  }
}
