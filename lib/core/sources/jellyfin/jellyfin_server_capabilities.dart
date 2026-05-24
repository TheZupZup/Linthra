/// Version- and capability-awareness for a Jellyfin server.
///
/// This is intentionally *diagnostic only*: it parses the version string a
/// server reports and classifies how well Linthra expects to work with it, so
/// the user (and a bug report) can see "you're on an older, untested server".
///
/// It must never be used to branch request behavior — the endpoints Linthra
/// uses (see [JellyfinEndpoints] and docs/jellyfin-compatibility.md) are stable
/// across the Jellyfin 10.x line, so there is no need for version-sniffing
/// hacks, and adding them would be exactly the kind of fragile coupling this
/// hardening pass is meant to avoid.
library;

/// A parsed Jellyfin `major.minor.patch` version.
///
/// Pure and comparable so the support classification and any future "is this at
/// least X" check stay unit-testable without a server. Extra build/suffix parts
/// (e.g. `-rc1`, `+build`) are ignored.
class JellyfinServerVersion implements Comparable<JellyfinServerVersion> {
  const JellyfinServerVersion(this.major, [this.minor = 0, this.patch = 0]);

  final int major;
  final int minor;
  final int patch;

  /// Parses `"10.9.11"` / `"10.9"` / `"10.9.11-rc1"`, or returns `null` when the
  /// string carries no recognizable `major.minor` version.
  static JellyfinServerVersion? tryParse(String raw) {
    final RegExpMatch? match =
        RegExp(r'(\d+)\.(\d+)(?:\.(\d+))?').firstMatch(raw.trim());
    if (match == null) {
      return null;
    }
    return JellyfinServerVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3) ?? '0'),
    );
  }

  @override
  int compareTo(JellyfinServerVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator >=(JellyfinServerVersion other) => compareTo(other) >= 0;
  bool operator <(JellyfinServerVersion other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) =>
      other is JellyfinServerVersion &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

/// How well Linthra expects to work with a server's reported version.
enum JellyfinServerSupport {
  /// At or above the oldest version Linthra is tested against.
  supported,

  /// Older than the tested minimum. Linthra may still work — the endpoints it
  /// uses are long-standing — but the combination is untested.
  untested,

  /// The version string was absent or unparseable, so support is unknown.
  unknown;

  /// A short, user-facing label for diagnostics and the settings note.
  String get label {
    switch (this) {
      case JellyfinServerSupport.supported:
        return 'supported';
      case JellyfinServerSupport.untested:
        return 'untested (older than recommended)';
      case JellyfinServerSupport.unknown:
        return 'unknown';
    }
  }
}

/// The oldest Jellyfin version Linthra is actively tested against.
///
/// This is a conservative floor, **not** a hard gate: an older server is
/// labelled [JellyfinServerSupport.untested] (and the user is gently warned),
/// never blocked, because the REST endpoints Linthra relies on predate it.
const JellyfinServerVersion kMinimumTestedJellyfinVersion =
    JellyfinServerVersion(10, 8, 0);

/// Classifies a reported [version] string against [kMinimumTestedJellyfinVersion].
JellyfinServerSupport jellyfinServerSupportFor(String? version) {
  if (version == null || version.trim().isEmpty) {
    return JellyfinServerSupport.unknown;
  }
  final JellyfinServerVersion? parsed = JellyfinServerVersion.tryParse(version);
  if (parsed == null) {
    return JellyfinServerSupport.unknown;
  }
  return parsed >= kMinimumTestedJellyfinVersion
      ? JellyfinServerSupport.supported
      : JellyfinServerSupport.untested;
}
