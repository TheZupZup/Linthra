import 'package:flutter/foundation.dart';

/// Which audio backend a Linux build is playing through.
enum LinuxPlaybackBackend {
  /// just_audio's Linux federated implementation: `just_audio_media_kit` →
  /// media_kit → libmpv. The only one Linthra ships on Linux today.
  mediaKitLibmpv('media_kit / libmpv (just_audio_media_kit)'),

  /// No on-device engine on this host. Reported rather than hidden, because a
  /// "nothing plays" report from a host with no engine is a different bug from
  /// one where libmpv is present and failing.
  none('none (no on-device engine on this host)');

  const LinuxPlaybackBackend(this.label);

  final String label;
}

/// Whether libmpv could be found, as far as the app can tell without loading it
/// on purpose.
enum LibmpvAvailability {
  /// A live player answered, so the library is loaded and working.
  available('available'),

  /// Nothing is playing, so no player could be asked. Not evidence of absence.
  notProbed('not probed (nothing playing)'),

  /// A player was asked and could not answer.
  unavailable('unavailable');

  const LibmpvAvailability(this.label);

  final String label;
}

/// Which audio subsystem an output device belongs to.
///
/// Derived from the driver prefix of libmpv's device name (`pipewire/…`,
/// `pulse/…`, `alsa/…`), never from anything the user typed. A closed enum, so
/// the report can name the subsystem without carrying the device string.
enum AudioOutputDriver {
  pipewire('pipewire'),
  pulse('pulse'),
  alsa('alsa'),
  jack('jack'),
  systemDefault('system default'),
  other('other');

  const AudioOutputDriver(this.label);

  final String label;

  /// Classifies a backend device id by its driver prefix.
  ///
  /// Only the part *before* the first `/` is looked at, and only against this
  /// fixed list — the node name after it is never read, let alone reported.
  static AudioOutputDriver fromDeviceId(String? id) {
    if (id == null || id.isEmpty || id == 'auto') return systemDefault;
    final int slash = id.indexOf('/');
    final String prefix =
        (slash < 0 ? id : id.substring(0, slash)).toLowerCase();
    for (final AudioOutputDriver driver in values) {
      if (driver != systemDefault &&
          driver != other &&
          driver.label == prefix) {
        return driver;
      }
    }
    return other;
  }
}

/// What kind of thing an output device is.
///
/// Classified from a handful of fixed substrings in the backend's device name
/// (`hdmi`, `bluez`, `usb`, …). The result is one of these constants, so a
/// Bluetooth sink's node name — which embeds the adapter's MAC address, and a
/// speaker name the listener chose — never reaches the report. That is the
/// point: the useful fact for debugging is "the selected output is HDMI", not
/// which HDMI port on whose machine.
enum AudioOutputKind {
  analog('analog'),
  hdmi('hdmi'),
  bluetooth('bluetooth'),
  usb('usb'),
  digital('digital'),
  virtual('virtual'),
  systemDefault('system default'),
  other('other');

  const AudioOutputKind(this.label);

  final String label;

  /// Classifies a backend device id into one of these kinds.
  static AudioOutputKind fromDeviceId(String? id) {
    if (id == null || id.isEmpty || id == 'auto') return systemDefault;
    final String lower = id.toLowerCase();
    if (lower.contains('bluez') || lower.contains('bluetooth')) {
      return bluetooth;
    }
    if (lower.contains('hdmi') || lower.contains('displayport')) return hdmi;
    if (lower.contains('usb')) return usb;
    if (lower.contains('iec958') ||
        lower.contains('spdif') ||
        lower.contains('digital')) {
      return digital;
    }
    if (lower.contains('null') ||
        lower.contains('dummy') ||
        lower.contains('monitor') ||
        lower.contains('loopback')) {
      return virtual;
    }
    if (lower.contains('analog') ||
        lower.contains('headphone') ||
        lower.contains('speaker') ||
        lower.contains('lineout')) {
      return analog;
    }
    return other;
  }
}

/// One kind of playback failure and how often it has been seen this session.
@immutable
class LinuxPlaybackFailure {
  const LinuxPlaybackFailure({required this.kind, required this.count});

  /// A structural failure label — an enum name or fixed token such as `load`,
  /// `resolution`, `timeout`, `suspend-resume-recovery`. Never a raw error
  /// string: these come from [SafeEventLog], which has no field for one.
  final String kind;

  /// How many times it occurred in the retained window.
  final int count;

  @override
  bool operator ==(Object other) =>
      other is LinuxPlaybackFailure &&
      other.kind == kind &&
      other.count == count;

  @override
  int get hashCode => Object.hash(kind, count);
}

/// An immutable, display-safe snapshot of the Linux playback stack.
///
/// **Security: safe by construction, not by redaction.** Every field here is
/// one of four things — a value from a closed enum, a bool, an int, or a
/// version string that has already been through
/// [LinuxPlaybackDiagnostics.sanitizeVersion]. There is deliberately no field
/// for a stream URL, a token, a header, a device node name, a file path, or a
/// raw backend error, so nothing sensitive can be assembled here in the first
/// place and the renderer has nothing to strip.
///
/// Two collection choices carry most of that weight:
///
///  * the **output device** is reported as a driver and a kind
///    ([AudioOutputDriver], [AudioOutputKind]), never as libmpv's device name.
///    A PipeWire Bluetooth sink is named `bluez_output.AC_12_2F_…` — the
///    adapter's MAC — and its description is a speaker name the listener chose.
///    "bluetooth, via pipewire" answers the debugging question without either.
///  * **failures** come from [SafeEventLog], whose entries are already fixed
///    structural labels, aggregated to kind + count. The raw engine error —
///    the one thing that can carry a tokenized URL — is never collected, which
///    is why it cannot be leaked.
@immutable
class LinuxPlaybackDiagnosticsData {
  const LinuxPlaybackDiagnosticsData({
    required this.backend,
    this.libmpv = LibmpvAvailability.notProbed,
    this.libmpvVersion,
    this.mpvProperties = const <String, String>{},
    this.outputSelectionSupported = false,
    this.outputsEnumerated,
    this.outputEnumerationFailed = false,
    this.selectedOutputDriver = AudioOutputDriver.systemDefault,
    this.selectedOutputKind = AudioOutputKind.systemDefault,
    this.selectedOutputIsSystemDefault = true,
    this.selectedOutputRemembered = false,
    this.savedOutputUnavailable = false,
    this.lastSelectionFailed = false,
    this.suspendRecoveryEnabled = false,
    this.playbackStatus,
    this.recentFailures = const <LinuxPlaybackFailure>[],
  });

  final LinuxPlaybackBackend backend;

  final LibmpvAvailability libmpv;

  /// libmpv's own version string, when a live player could be asked for it
  /// (`mpv 0.38.0`). Null when nothing was playing, when the property was not
  /// answered, or when the value did not survive [
  /// LinuxPlaybackDiagnostics.sanitizeVersion].
  final String? libmpvVersion;

  /// The libmpv properties Linthra sets, filtered to
  /// [LinuxPlaybackDiagnostics.reportableMpvProperties]. An allowlist of keys,
  /// not a blocklist: a property added later is invisible here until someone
  /// decides it is safe to show.
  final Map<String, String> mpvProperties;

  /// Whether this build can enumerate and choose an output at all.
  final bool outputSelectionSupported;

  /// How many outputs the backend reported, when it answered. Null when the
  /// list has never been asked for, and null when the ask *failed* — see
  /// [outputEnumerationFailed]. A count is only ever a real count.
  final int? outputsEnumerated;

  /// Whether an enumeration was attempted and the backend did not answer.
  ///
  /// Distinct from a count of zero, and never reported as one. A successful
  /// enumeration always contains at least the system default (
  /// `audioOutputDevicesFromBackend` prepends it), so an empty list can only
  /// mean the backend could not be asked — which is one of the failures this
  /// report exists to surface, not a machine with no outputs.
  final bool outputEnumerationFailed;

  final AudioOutputDriver selectedOutputDriver;
  final AudioOutputKind selectedOutputKind;
  final bool selectedOutputIsSystemDefault;

  /// Whether the selected output's id is stable enough to be remembered across
  /// restarts.
  final bool selectedOutputRemembered;

  /// Whether a previously chosen output was missing, so playback fell back to
  /// the system default.
  final bool savedOutputUnavailable;

  /// Whether the last attempt to route audio was refused by the backend.
  final bool lastSelectionFailed;

  /// Whether the Linux-only post-suspend reload is armed for this controller.
  final bool suspendRecoveryEnabled;

  /// The current playback status as a stable enum name (`playing`,
  /// `buffering`, `error`, …). Never an error message.
  final String? playbackStatus;

  /// Recent failure kinds and their counts, most frequent first.
  final List<LinuxPlaybackFailure> recentFailures;
}

/// Renders [LinuxPlaybackDiagnosticsData] as the copyable report.
///
/// Pure and free of any I/O or plugin, like [BugReport]: it is handed an
/// already-safe snapshot and returns text. It has no redaction step because
/// there is nothing to redact — see the class doc on
/// [LinuxPlaybackDiagnosticsData].
abstract final class LinuxPlaybackDiagnostics {
  /// The libmpv property keys the report may show, and nothing else.
  ///
  /// All three are values Linthra itself writes:
  ///  * `cache-on-disk` — Linthra always sets `no` (#405);
  ///  * `ao` — set only by the headless audio smoke;
  ///  * `audio-device` — reported as *set / not set*, never as its value, for
  ///    the same reason the selected output is reported as a driver and a kind.
  static const Set<String> reportableMpvProperties = <String>{
    'cache-on-disk',
    'ao',
    'audio-device',
  };

  /// Property keys whose value is replaced with `set` / `not set`.
  static const Set<String> _valueWithheldProperties = <String>{'audio-device'};

  /// The most failure kinds listed, so a wedged session cannot produce an
  /// unbounded report.
  static const int maxReportedFailureKinds = 8;

  /// Longest a version string may be in the report.
  static const int maxVersionLength = 48;

  /// What a backend version is allowed to look like: letters, digits and the
  /// handful of separators a version string actually uses.
  static final RegExp _versionShape = RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._+-]*$');

  /// Accepts a backend version string, or rejects it outright.
  ///
  /// Belt and braces: `mpv-version` is a compile-time constant inside libmpv,
  /// not user data, so in practice this changes nothing. It exists so that the
  /// one free-form string in the whole snapshot cannot carry a URL, a query
  /// string, a path, a header or a newline into the report if a future backend
  /// answers with something unexpected.
  ///
  /// It **rejects** rather than strips, and that is the point: stripping the
  /// punctuation out of `mpv 1.0\nAuthorization: Bearer abc` leaves the words
  /// behind, which is worse than saying nothing. A value that is not
  /// version-shaped returns null and its line is simply omitted.
  static String? sanitizeVersion(String? version) {
    if (version == null) return null;
    final String trimmed = version.trim();
    if (trimmed.isEmpty || !_versionShape.hasMatch(trimmed)) return null;
    return trimmed.length <= maxVersionLength
        ? trimmed
        : trimmed.substring(0, maxVersionLength);
  }

  /// The only shape a property value may be shown in: a single short token.
  ///
  /// The values Linthra writes are all of this shape (`no`, `alsa`), so the
  /// pattern costs nothing in practice. What it buys is that *no* multi-word,
  /// spaced, or punctuated value can ever be printed — a header, a URL, or a
  /// key/value pair does not match, and is reported as `set` instead.
  static final RegExp _reportableValue = RegExp(r'^[A-Za-z0-9_.+-]{1,24}$');

  /// Keeps only [reportableMpvProperties] from [properties], withholding the
  /// values of [_valueWithheldProperties] and anything that is not a plain
  /// token.
  static Map<String, String> filterMpvProperties(
    Map<String, String> properties,
  ) {
    final Map<String, String> filtered = <String, String>{};
    for (final String key in reportableMpvProperties) {
      final String? value = properties[key];
      if (value == null) continue;
      final String trimmed = value.trim();
      filtered[key] = _valueWithheldProperties.contains(key) ||
              !_reportableValue.hasMatch(trimmed)
          ? 'set'
          : trimmed;
    }
    return filtered;
  }

  /// Assembles the multi-line report.
  ///
  /// Every optional line is emitted only when its value is known, so a report
  /// built before anything has played is still valid and still useful — an
  /// unprobed libmpv and an un-enumerated output list are honest answers, not
  /// failures.
  static String report(LinuxPlaybackDiagnosticsData data) {
    final List<String> lines = <String>[
      'Linthra Linux playback diagnostics',
      'Backend: ${data.backend.label}',
      'libmpv: ${data.libmpv.label}',
      if (data.libmpvVersion != null) 'libmpv version: ${data.libmpvVersion}',
      for (final MapEntry<String, String> entry
          in data.mpvProperties.entries.toList()
            ..sort((MapEntry<String, String> a, MapEntry<String, String> b) =>
                a.key.compareTo(b.key)))
        'mpv ${entry.key}: ${entry.value}',
      'Output selection: '
          '${data.outputSelectionSupported ? 'supported' : 'unsupported'}',
      if (data.outputEnumerationFailed)
        'Outputs found: unknown (the backend did not answer)'
      else if (data.outputsEnumerated != null)
        'Outputs found: ${data.outputsEnumerated}',
      'Selected output: ${_selectedOutputLine(data)}',
      if (!data.selectedOutputIsSystemDefault)
        'Selected output remembered: ${_yesNo(data.selectedOutputRemembered)}',
      if (data.savedOutputUnavailable)
        'Saved output: unavailable (using the system default)',
      if (data.lastSelectionFailed) 'Last output switch: refused by backend',
      'Suspend/resume recovery: '
          '${data.suspendRecoveryEnabled ? 'enabled' : 'disabled'}',
      if (data.playbackStatus != null) 'Playback state: ${data.playbackStatus}',
      _failuresLine(data),
    ];
    return lines.join('\n');
  }

  static String _selectedOutputLine(LinuxPlaybackDiagnosticsData data) {
    if (data.selectedOutputIsSystemDefault) return 'system default';
    return '${data.selectedOutputKind.label}, via '
        '${data.selectedOutputDriver.label}';
  }

  static String _failuresLine(LinuxPlaybackDiagnosticsData data) {
    if (data.recentFailures.isEmpty) return 'Recent playback failures: none';
    final Iterable<LinuxPlaybackFailure> shown =
        data.recentFailures.take(maxReportedFailureKinds);
    final String body = <String>[
      for (final LinuxPlaybackFailure failure in shown)
        '${failure.kind} ×${failure.count}',
    ].join(', ');
    return 'Recent playback failures: $body';
  }

  static String _yesNo(bool value) => value ? 'yes' : 'no';
}
