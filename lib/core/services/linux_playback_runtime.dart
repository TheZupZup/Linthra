import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException;

import '../diagnostics/linux_playback_diagnostics.dart';
import 'playable_uri_resolver.dart';

/// Reads a libmpv soname the way the backend does and reports what the dynamic
/// loader said when it would not open.
///
/// Returns null when the library loaded, and the loader's own message when it
/// did not. A seam, so the classification below can be exercised without a
/// libmpv (or a `dart:ffi` call) on the machine running the tests.
typedef LinuxNativeLibraryProbe = String? Function(String soname);

/// The libmpv library names the backend tries, in the order it tries them.
///
/// Kept in step with media_kit 1.2.6 (`lib/src/player/native/core/
/// native_library.dart`) and with the same list `scripts/verify_linux.sh`
/// probes, so the app's own answer and the verification script's cannot drift
/// apart.
const List<String> libmpvSonames = <String>[
  'libmpv.so',
  'libmpv.so.2',
  'libmpv.so.1',
];

/// A classified Linux playback-runtime failure: what is wrong with the native
/// audio runtime, what to tell the listener about it, and the loader's own
/// account of it reduced to something safe to keep.
///
/// Security invariant, the same one the player's own failure model carries:
/// [message] is fixed text chosen from [problem], never assembled from an
/// error. The one value derived from the original error is [diagnostic],
/// which has been through [LinuxPlaybackRuntime.sanitizeRuntimeDiagnostic] and
/// is deliberately *not* published anywhere the listener or a copied report
/// can reach.
@immutable
class LinuxPlaybackRuntimeFailure {
  const LinuxPlaybackRuntimeFailure({
    required this.problem,
    required this.message,
    required this.diagnostic,
  });

  /// What is wrong, as a closed enum.
  final LinuxPlaybackRuntimeProblem problem;

  /// The friendly, secret-free, actionable text the player shows.
  final String message;

  /// What the loader actually said, with paths and URLs removed and the whole
  /// thing bounded.
  ///
  /// Kept because "libmpv would not load" without the reason is a bug report
  /// nobody can act on, and dropped from every published surface because the
  /// reason is usually a sentence with somebody's library path in it. It goes
  /// to the debug log and lives in memory on the failure; the copyable Linux
  /// playback report carries [problem] instead.
  final String diagnostic;

  /// The failure as the playback controller's own resolution error, so an
  /// unavailable engine travels the same path a track that will not play does
  /// and the player's error panel renders it with no Linux-specific branch.
  PlaybackResolutionException asResolutionException() =>
      PlaybackResolutionException(
        message,
        kind: PlaybackResolutionErrorKind.playbackEngineUnavailable,
      );

  @override
  String toString() => 'LinuxPlaybackRuntimeFailure(${problem.name})';
}

/// Turns a backend initialization or load error into a classified runtime
/// failure, or answers that it is not one.
///
/// This is the piece the whole issue turns on, and the *null* answer is the
/// important half of it. A codec the runtime cannot decode, a server that
/// stopped answering, a session a provider rejected and a plain programming
/// mistake all reach the audio engine as exceptions too, and none of them is a
/// broken libmpv. Only an error that actually names the native runtime
/// (`libmpv`, an mpv symbol, the dynamic loader, an ELF header) is classified;
/// everything else returns null and keeps the classification it already had.
abstract final class LinuxPlaybackRuntime {
  /// The developer-log channel the retained diagnostic goes to, in debug
  /// builds only. Filter with `grep linthra.linux.playback`.
  static const String logName = 'linthra.linux.playback';

  /// Longest a retained diagnostic may be.
  static const int maxDiagnosticLength = 240;

  /// Words that mean the error is about the native audio runtime at all.
  ///
  /// The gate, not the classification: an error that matches none of these is
  /// somebody else's problem and is handed back unclassified.
  static const List<String> runtimeMarkers = <String>[
    'libmpv',
    'mpv_',
    'mpv-',
    'dynamic library',
    'shared object',
    'shared library',
    'dlopen',
    'elf header',
    'elf class',
    'undefined symbol',
    'lookup symbol',
  ];

  /// Words that mean a libmpv is present and does not match this build.
  static const List<String> incompatibleMarkers = <String>[
    'elf header',
    'elf class',
    'undefined symbol',
    'lookup symbol',
    'symbol not found',
    'file too short',
    'not found (required by',
    'wrong architecture',
    'unsupported version',
    'incompatible',
  ];

  /// Words that mean nothing answered to the name at all.
  ///
  /// Deliberately *not* "cannot open shared object file": the loader says that
  /// for a library it refused as well as for one that is not there, and only
  /// the "no such file" half means absent.
  static const List<String> missingMarkers = <String>[
    'cannot find libmpv',
    'no such file or directory',
  ];

  /// Classifies [error], or returns null when it is not about the native
  /// runtime.
  ///
  /// A [MissingPluginException] is included on purpose: on Linux it means the
  /// federated audio implementation is not in the process, which is a broken
  /// install rather than a track that will not play. Everything else has to
  /// mention the runtime in so many words.
  static LinuxPlaybackRuntimeProblem? recognise(Object error) {
    if (error is MissingPluginException) {
      return LinuxPlaybackRuntimeProblem.backendInitializationFailed;
    }
    return recogniseText(error.toString());
  }

  /// [recognise] for something that is already just text: one line the dynamic
  /// loader refused a name with.
  static LinuxPlaybackRuntimeProblem? recogniseText(String message) {
    final String text = message.toLowerCase();
    if (!_mentions(text, runtimeMarkers)) return null;
    // A version or ABI mismatch reads as "found it, cannot use it", so it is
    // decided before "cannot find it": a wrong-architecture libmpv.so sitting
    // next to an absent libmpv.so.2 would otherwise be reported as missing,
    // and reinstalling the package the user already has would be the advice.
    if (_mentions(text, incompatibleMarkers)) {
      return LinuxPlaybackRuntimeProblem.libraryIncompatible;
    }
    if (_mentions(text, missingMarkers)) {
      return LinuxPlaybackRuntimeProblem.libraryMissing;
    }
    return LinuxPlaybackRuntimeProblem.libraryUnloadable;
  }

  /// Sharpens [initial] by asking the dynamic loader directly.
  ///
  /// media_kit swallows each individual `DynamicLibrary.open` failure and
  /// reports one fixed "cannot find libmpv" for all of them, so its message
  /// cannot tell "not installed" from "installed and refused". Asking the
  /// loader for the same names it tried, and reading *its* answers, can. Only
  /// [LinuxPlaybackRuntimeProblem.libraryMissing] is refined, because that is
  /// the only verdict media_kit's wording forces.
  ///
  /// [probe] is called once per name in [libmpvSonames]. A name that loads
  /// contributes nothing; if every name loads, the library is fine and the
  /// backend failed for another reason.
  static LinuxPlaybackRuntimeProblem refine(
    LinuxPlaybackRuntimeProblem initial,
    LinuxNativeLibraryProbe probe,
  ) {
    if (initial != LinuxPlaybackRuntimeProblem.libraryMissing) return initial;
    final List<String> refusals = <String>[
      for (final String soname in libmpvSonames)
        if (probe(soname) case final String error) error,
    ];
    if (refusals.isEmpty) {
      return LinuxPlaybackRuntimeProblem.backendInitializationFailed;
    }
    final List<LinuxPlaybackRuntimeProblem> verdicts =
        <LinuxPlaybackRuntimeProblem>[
      for (final String refusal in refusals)
        recogniseText(refusal) ?? LinuxPlaybackRuntimeProblem.libraryUnloadable,
    ];
    // Most specific wins: one name refused for a version or ABI reason says
    // more about this machine than two others that simply are not there.
    if (verdicts.contains(LinuxPlaybackRuntimeProblem.libraryIncompatible)) {
      return LinuxPlaybackRuntimeProblem.libraryIncompatible;
    }
    if (verdicts.contains(LinuxPlaybackRuntimeProblem.libraryUnloadable)) {
      return LinuxPlaybackRuntimeProblem.libraryUnloadable;
    }
    return LinuxPlaybackRuntimeProblem.libraryMissing;
  }

  /// The text the listener sees for [problem].
  ///
  /// Two wordings per problem, because the fix is genuinely different: a
  /// distribution build plays through the libmpv the machine has, while a
  /// Flatpak ships its own and never looks at the host's
  /// (`docs/flatpak-development.md`). Telling a Flatpak user to
  /// `apt install libmpv-dev` would send them to fix something the app does
  /// not use.
  ///
  /// Fixed strings, all of them. Nothing here is built from an error, a path
  /// or an environment value.
  static String messageFor(
    LinuxPlaybackRuntimeProblem problem, {
    required bool bundledRuntime,
  }) {
    if (bundledRuntime) {
      return switch (problem) {
        LinuxPlaybackRuntimeProblem.libraryMissing =>
          'The audio engine is missing from this install of Linthra, so '
              'nothing can play. Reinstalling Linthra from Flathub restores '
              'it.',
        LinuxPlaybackRuntimeProblem.libraryUnloadable ||
        LinuxPlaybackRuntimeProblem.libraryIncompatible =>
          "Linthra's bundled audio engine would not load, so nothing can "
              'play. Reinstalling Linthra from Flathub usually fixes this.',
        LinuxPlaybackRuntimeProblem.backendInitializationFailed =>
          "Linthra's audio engine did not start, so nothing can play. "
              'Restarting Linthra, or reinstalling it from Flathub, usually '
              'fixes this.',
      };
    }
    return switch (problem) {
      LinuxPlaybackRuntimeProblem.libraryMissing =>
        'Linthra plays audio through libmpv, and this system does not have '
            "it. Install your distribution's libmpv package (libmpv2 on "
            'Debian and Ubuntu, mpv-libs on Fedora, mpv on Arch), then choose '
            'Retry.',
      LinuxPlaybackRuntimeProblem.libraryUnloadable =>
        'Linthra found libmpv on this system but could not load it, so '
            "nothing can play. Reinstalling your distribution's libmpv "
            'package usually fixes this. Choose Retry once it is done.',
      LinuxPlaybackRuntimeProblem.libraryIncompatible =>
        "This system's libmpv is not compatible with Linthra, so nothing can "
            'play. Updating it through your package manager should fix it, '
            'then choose Retry.',
      LinuxPlaybackRuntimeProblem.backendInitializationFailed =>
        "Linthra's audio engine did not start, so nothing can play. Check "
            'that libmpv is installed and working, then choose Retry.',
    };
  }

  /// What the loader said, kept only in the form that is safe to keep.
  ///
  /// Loader messages are the one place in this path that carries a filesystem
  /// path, and on Linux a path is usually a home directory with a login name
  /// in it. URLs go first (a scheme's `//` would otherwise survive the path
  /// pass), then absolute paths, then whitespace is collapsed so a multi-line
  /// error cannot smuggle a second line past a reader, then the whole thing is
  /// bounded.
  static String sanitizeRuntimeDiagnostic(Object error) {
    final String collapsed = error
        .toString()
        .replaceAll(RegExp(r'[a-zA-Z][a-zA-Z0-9+.-]*://\S+'), '<url>')
        .replaceAll(RegExp(r'(/[\w.+@-]+){2,}/?'), '<path>')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return collapsed.length <= maxDiagnosticLength
        ? collapsed
        : '${collapsed.substring(0, maxDiagnosticLength)}…';
  }

  /// Records [failure] where a developer can see it, and nowhere else.
  ///
  /// Debug builds only, like every other breadcrumb in this app: the retained
  /// diagnostic is sanitized rather than structurally safe, and "sanitized" is
  /// not a strong enough promise to put it in a release build's log.
  static void logFailure(LinuxPlaybackRuntimeFailure failure) {
    if (!kDebugMode) return;
    developer.log(
      'linux playback runtime: ${failure.problem.name}: '
      '${failure.diagnostic}',
      name: logName,
    );
  }

  static bool _mentions(String text, List<String> needles) =>
      needles.any(text.contains);
}
