import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException;

import '../diagnostics/linux_playback_diagnostics.dart';
import 'playable_uri_resolver.dart';

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
    'not found (required by',
    'wrong architecture',
    'unsupported version',
    'incompatible',
  ];

  /// Note what is deliberately *absent*: `file too short`. A truncated
  /// library is corrupt rather than mismatched, and
  /// [LinuxPlaybackRuntimeProblem.libraryUnloadable] (the fallback, which
  /// advises reinstalling) is where the enum itself puts it. Calling it
  /// incompatible would advise an update, and updating to the same version
  /// the machine already has is a no-op that leaves playback broken.

  /// Words that mean no usable libmpv answered.
  ///
  /// Deliberately *not* "cannot open shared object file": the loader says that
  /// for a library it refused as well as for one that is not there, and only
  /// the "no such file" half means absent. The backend's own wording
  /// ("cannot find libmpv") covers both, which is why
  /// [LinuxPlaybackRuntimeProblem.libraryMissing]'s message advises installing
  /// *or reinstalling* the package rather than assuming which it is.
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
  ///
  /// The URI is taken out **before** the markers are looked for, and that is
  /// load-bearing rather than tidiness. libmpv reports an unplayable track as
  /// `Failed to open <uri>` and the vendored backend passes that text straight
  /// through (`third_party/just_audio_media_kit/lib/mediakit_player.dart`), so
  /// a perfectly ordinary song at `…/libmpv-demo.flac` would otherwise match
  /// `libmpv` and be called a broken audio engine: the listener would lose
  /// Skip and "Try another source" and be told to reinstall a system package
  /// over one file. A loader's own complaint survives the redaction, because
  /// what identifies it (`cannot open shared object file`, `wrong ELF class`,
  /// `undefined symbol: mpv_create`, the soname in quotes) is not inside a
  /// path.
  static LinuxPlaybackRuntimeProblem? recogniseText(String message) {
    final String text = redactLocations(message).toLowerCase();
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

  /// What to do about [problem], as the listener is told it.
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
    bool alreadyLoaded = false,
  }) =>
      '${_diagnosisFor(problem, bundledRuntime: bundledRuntime)}'
      '${alreadyLoaded ? restartTail : retryTail}';

  /// How a listener gets playback back when libmpv was never loaded.
  ///
  /// Registration is re-attempted on every playback attempt until one works,
  /// so this really is the whole recovery.
  static const String retryTail = ' Then choose Retry.';

  /// How a listener gets playback back when libmpv *was* loaded and then
  /// turned out to be the wrong one.
  ///
  /// A shared library is mapped into the process on first use and media_kit
  /// resolves it exactly once per process, so replacing the file on disk
  /// changes nothing until Linthra starts again. Promising Retry here would
  /// be promising something the process cannot do.
  static const String restartTail =
      ' Then restart Linthra: it has already loaded a copy of libmpv and '
      'will not pick up a new one until it starts again.';

  static String _diagnosisFor(
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
              'Reinstalling Linthra from Flathub usually fixes this.',
      };
    }
    return switch (problem) {
      LinuxPlaybackRuntimeProblem.libraryMissing =>
        'Linthra plays audio through libmpv, and this system does not have a '
            "copy it can use. Install or reinstall your distribution's libmpv "
            'package (libmpv2 on Debian and Ubuntu, mpv-libs on Fedora, mpv '
            'on Arch).',
      LinuxPlaybackRuntimeProblem.libraryUnloadable =>
        'Linthra found libmpv on this system but could not load it, so '
            "nothing can play. Reinstalling your distribution's libmpv "
            'package usually fixes this.',
      LinuxPlaybackRuntimeProblem.libraryIncompatible =>
        "This system's libmpv is not compatible with Linthra, so nothing can "
            'play. Updating it through your package manager should fix it.',
      LinuxPlaybackRuntimeProblem.backendInitializationFailed =>
        "Linthra's audio engine did not start, so nothing can play. Check "
            'that libmpv is installed and working.',
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
    final String collapsed = redactLocations(error.toString())
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return collapsed.length <= maxDiagnosticLength
        ? collapsed
        : '${collapsed.substring(0, maxDiagnosticLength)}…';
  }

  /// Replaces every URL and filesystem path in [text] with a fixed token.
  ///
  /// Used for two different reasons that happen to want the same thing: a
  /// retained diagnostic must not carry somebody's home directory or a
  /// tokenized stream URL, and [recogniseText] must not read a track's own
  /// location as evidence about the audio runtime. URLs go first, so a
  /// scheme's `//` cannot survive into the path pass.
  static String redactLocations(String text) =>
      text.replaceAll(_url, '<url>').replaceAll(_path, '<path>');

  /// Everything from here to whatever genuinely ends a location inside an
  /// error message: a quote, a bracket, a comma or semicolon, a newline, or
  /// the `: ` that separates a location from the reason it was rejected.
  ///
  /// Spaces are deliberately *inside* a location rather than ending one. A
  /// Linux path may contain them, and a `file://` URI echoed back by libmpv
  /// may carry them undecoded, so stopping at the first space is what leaves
  /// `Lovelace` behind in `/home/Ada Lovelace/…`.
  static const String _untilDelimiter =
      r'''(?:(?!:\s)[^'"`,;()\[\]{}<>\n\r\t])*''';

  /// A URL, run to its delimiter rather than to its first space.
  static final RegExp _url =
      RegExp(r'[a-zA-Z][a-zA-Z0-9+.-]*://' + _untilDelimiter);

  /// A filesystem path, run to its delimiter rather than to the first
  /// character that does not look path-ish.
  ///
  /// An allowlist of path characters is the wrong shape for this: Linux paths
  /// legitimately contain spaces and whatever non-ASCII the user's locale
  /// allows, so `/home/Ada Lovelace/lib/libmpv.so` would be redacted as far as
  /// `/home/Ada` and leave the surname behind in a line that claims to carry
  /// no paths.
  ///
  /// Both of these over-match prose containing a slash, and that is the right
  /// way to be wrong here. Over-redaction costs a word of context in a debug
  /// line and, in [recogniseText], can only lose a marker, so a runtime
  /// failure reads as an ordinary one: the safe direction. Under-redaction
  /// leaks somebody's name.
  static final RegExp _path =
      RegExp(r'''/(?:(?!:\s)[^'"`,;()\[\]{}<>\s])''' + _untilDelimiter);

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
