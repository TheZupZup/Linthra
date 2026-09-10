import 'dart:async';

import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';

/// What a libmpv probe found.
typedef LinuxMpvProbeResult = ({bool reachable, String? version});

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
///    a property libmpv does not know, a wedged backend — comes back as an
///    absent value. Missing optional information must not fail the view.
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
    if (live.isEmpty) return (reachable: false, version: null);
    try {
      final PlatformPlayer? platform = live.first.platform;
      if (platform is! NativePlayer) return (reachable: false, version: null);
      final String value =
          await platform.getProperty(versionProperty).timeout(timeout);
      return (reachable: true, version: value.isEmpty ? null : value);
    } catch (_) {
      // A player that exists but cannot be asked is still evidence libmpv is
      // loaded — it is the *version* that is missing, not the library.
      return (reachable: true, version: null);
    }
  }
}
