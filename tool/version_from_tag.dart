/// Derives Android/app version metadata from a Git release tag.
///
/// This is the **single source of truth** for how a `v*` tag becomes the
/// `versionName`/`versionCode` baked into a release build. The release workflow
/// (`.github/workflows/android-release-build.yml`) runs this on the pushed tag
/// and feeds the result to `flutter build` (`--build-name`/`--build-number`)
/// and to the in-app version (`--dart-define=LINTHRA_VERSION_NAME=...`).
/// `test/tooling/version_from_tag_test.dart` exercises the rules below.
///
/// ## Tag format
///
/// `vMAJOR.MINOR.PATCH` with an optional `-alpha.N` / `-beta.N` / `-rc.N`
/// pre-release suffix. A leading `v` is optional and stripped. Examples:
/// `v0.1.0-alpha.16`, `v0.1.0-beta.1`, `v0.1.0-rc.1`, `v0.1.0`, `v1.2.3`.
/// Anything else (`v1.2`, `v1.2.3-preview.1`, `v1.2.3-alpha`, …) is rejected
/// with a non-zero exit so a release never ships stale or guessed metadata.
///
/// ## versionName
///
/// The tag with its leading `v` stripped, pre-release suffix preserved:
/// `v0.1.0-alpha.16` → `0.1.0-alpha.16`.
///
/// ## versionCode (fully encoded, strictly monotonic)
///
/// ```
/// versionCode = MAJOR*10_000_000 + MINOR*100_000 + PATCH*1_000 + preReleaseRank
/// ```
///
/// where `preReleaseRank` orders the pre-release tiers below the stable
/// release of the *same* `x.y.z`:
///
/// | release   | rank        |
/// | --------- | ----------- |
/// | `alpha.N` | `N`         |
/// | `beta.N`  | `300 + N`   |
/// | `rc.N`    | `600 + N`   |
/// | stable    | `999`       |
///
/// Because every field has a fixed weight, the code **strictly increases** for
/// every higher version with no special cases and can never go backwards:
///
/// ```
/// v0.1.0-alpha.16 -> 100016
/// v0.1.0-beta.1   -> 100301
/// v0.1.0-rc.1     -> 100601
/// v0.1.0          -> 100999
/// v0.1.1-alpha.1  -> 101001
/// v0.2.0-alpha.1  -> 200001
/// v1.2.3          -> 10203999
/// ```
///
/// The fields are bounded so the result stays a valid Android `versionCode`
/// (1..2_100_000_000) and the tiers never collide: minor/patch ≤ 99, the
/// pre-release `N` ≤ 299. Out-of-range values fail loudly rather than wrapping.
library;

import 'dart:io';

/// The `versionName`/`versionCode` pair derived from a release tag.
class TagVersion {
  const TagVersion(this.name, this.code);

  /// The user-facing `versionName`, e.g. `0.1.0-alpha.16` (no leading `v`).
  final String name;

  /// The Android `versionCode`, e.g. `100016`.
  final int code;
}

const int _majorWeight = 10000000;
const int _minorWeight = 100000;
const int _patchWeight = 1000;

/// The maximum `versionCode` Android / Google Play accept.
const int _maxVersionCode = 2100000000;

/// Field bounds that keep the encoding unambiguous and within [_maxVersionCode].
const int _maxMinor = 99;
const int _maxPatch = 99;
const int _maxPreNumber = 299;

/// The stable (no pre-release) rank — above every pre-release of the same patch.
const int _stableRank = 999;

/// Per-tier base rank; the pre-release number is added on top.
const Map<String, int> _tierBase = <String, int>{
  'alpha': 0,
  'beta': 300,
  'rc': 600,
};

final RegExp _tagPattern =
    RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta|rc)\.(\d+))?$');

/// Parses [tag] into its [TagVersion], throwing [FormatException] (with an
/// actionable message) for anything that is not a supported release tag or
/// whose fields fall outside the encodable range.
TagVersion versionFromTag(String tag) {
  final RegExpMatch? match = _tagPattern.firstMatch(tag.trim());
  if (match == null) {
    throw FormatException(
      'Malformed release tag "$tag". Expected vMAJOR.MINOR.PATCH with an '
      'optional -alpha.N / -beta.N / -rc.N pre-release suffix, e.g. '
      'v0.1.0-alpha.16, v0.1.0-rc.1, or v1.2.3.',
    );
  }

  final int major = int.parse(match.group(1)!);
  final int minor = int.parse(match.group(2)!);
  final int patch = int.parse(match.group(3)!);
  final String? tier = match.group(4); // null for a stable release
  final String? preNumber = match.group(5);

  if (minor > _maxMinor) {
    throw FormatException(
      'Minor version $minor in tag "$tag" exceeds the supported range '
      '(0..$_maxMinor); the versionCode encoding cannot represent it.',
    );
  }
  if (patch > _maxPatch) {
    throw FormatException(
      'Patch version $patch in tag "$tag" exceeds the supported range '
      '(0..$_maxPatch); the versionCode encoding cannot represent it.',
    );
  }

  final int rank;
  final String name;
  if (tier == null) {
    rank = _stableRank;
    name = '$major.$minor.$patch';
  } else {
    final int n = int.parse(preNumber!);
    if (n > _maxPreNumber) {
      throw FormatException(
        'Pre-release number $n in tag "$tag" exceeds the supported range '
        '(0..$_maxPreNumber); raise the encoding bounds or use a higher '
        'patch/minor.',
      );
    }
    rank = _tierBase[tier]! + n;
    name = '$major.$minor.$patch-$tier.$n';
  }

  final int code =
      major * _majorWeight + minor * _minorWeight + patch * _patchWeight + rank;
  if (code <= 0 || code > _maxVersionCode) {
    throw FormatException(
      'Derived versionCode $code for tag "$tag" is outside the valid Android '
      'range (1..$_maxVersionCode); the major version is too large to encode.',
    );
  }
  return TagVersion(name, code);
}

/// CLI entry point.
///
/// Reads the tag from the first argument, falling back to `GITHUB_REF_NAME`,
/// and prints two `KEY=VALUE` lines on success so the workflow can append them
/// straight to `$GITHUB_ENV` / `$GITHUB_OUTPUT`:
///
/// ```
/// LINTHRA_VERSION_NAME=0.1.0-alpha.16
/// LINTHRA_VERSION_CODE=100016
/// ```
///
/// Exits non-zero (writing the reason to stderr, nothing to stdout) for a
/// missing or malformed tag, so a release build fails fast instead of shipping
/// stale version metadata.
void main(List<String> args) {
  final String? tag =
      args.isNotEmpty ? args.first : Platform.environment['GITHUB_REF_NAME'];
  if (tag == null || tag.trim().isEmpty) {
    stderr.writeln(
      'version_from_tag: no tag provided. Pass the tag as the first argument '
      'or set GITHUB_REF_NAME, e.g. `dart run tool/version_from_tag.dart '
      'v0.1.0-alpha.16`.',
    );
    exit(64); // EX_USAGE
  }

  final TagVersion version;
  try {
    version = versionFromTag(tag);
  } on FormatException catch (e) {
    stderr.writeln('version_from_tag: ${e.message}');
    exit(1);
  }

  stdout.writeln('LINTHRA_VERSION_NAME=${version.name}');
  stdout.writeln('LINTHRA_VERSION_CODE=${version.code}');
}
