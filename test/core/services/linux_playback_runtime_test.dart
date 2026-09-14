import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/diagnostics/linux_playback_diagnostics.dart';
import 'package:linthra/core/services/linux_playback_runtime.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';

/// The exact text media_kit 1.2.6 throws on Linux when no libmpv answers to any
/// of the names it tries. Copied verbatim, because the whole classification
/// hangs off recognising it.
const String mediaKitMissingLibmpv =
    'Exception: Cannot find libmpv at the usual places. Depending upon your '
    'distribution, you can install the libmpv package to make shared library '
    'available globally. On Debian or Ubuntu based systems, you can install '
    'it with: apt install libmpv-dev.';

/// What the dynamic loader says for each of the cases the app has to tell
/// apart, in the shape Dart reports a failed library load.
const String loaderNotThere =
    "Invalid argument(s): Failed to load dynamic library 'libmpv.so.2': "
    'libmpv.so.2: cannot open shared object file: No such file or directory';
const String loaderRefused =
    "Invalid argument(s): Failed to load dynamic library 'libmpv.so': "
    '/usr/lib/x86_64-linux-gnu/libmpv.so: cannot open shared object file: '
    'Permission denied';
const String loaderWrongClass =
    "Invalid argument(s): Failed to load dynamic library 'libmpv.so.2': "
    '/home/ada/.local/lib/libmpv.so.2: wrong ELF class: ELFCLASS32';
const String loaderMissingSymbol =
    "Invalid argument(s): Failed to lookup symbol 'mpv_create': "
    'undefined symbol: mpv_create';

void main() {
  group('recognising a native-runtime failure', () {
    test("media_kit's own \"cannot find libmpv\" reads as a missing library",
        () {
      expect(
        LinuxPlaybackRuntime.recognise(Exception(mediaKitMissingLibmpv)),
        LinuxPlaybackRuntimeProblem.libraryMissing,
      );
    });

    test('a loader that cannot find the file reads as a missing library', () {
      expect(
        LinuxPlaybackRuntime.recogniseText(loaderNotThere),
        LinuxPlaybackRuntimeProblem.libraryMissing,
      );
    });

    test('a loader that refuses a library that is there reads as unloadable',
        () {
      expect(
        LinuxPlaybackRuntime.recogniseText(loaderRefused),
        LinuxPlaybackRuntimeProblem.libraryUnloadable,
      );
    });

    test('a wrong-architecture library reads as incompatible', () {
      expect(
        LinuxPlaybackRuntime.recogniseText(loaderWrongClass),
        LinuxPlaybackRuntimeProblem.libraryIncompatible,
      );
    });

    test('a library missing an mpv symbol reads as incompatible', () {
      // The case a plain "is it installed?" check cannot see: the library
      // loads, so registration succeeds, and the first symbol it needs is not
      // in there.
      expect(
        LinuxPlaybackRuntime.recogniseText(loaderMissingSymbol),
        LinuxPlaybackRuntimeProblem.libraryIncompatible,
      );
    });

    test('a truncated library reads as unloadable, not incompatible', () {
      // Reinstall is the fix for a corrupt file. "Update the package" would be
      // a no-op for anyone already on the current version.
      expect(
        LinuxPlaybackRuntime.recogniseText(
          "Invalid argument(s): Failed to load dynamic library 'libmpv.so.2': "
          '/lib/libmpv.so.2: file too short',
        ),
        LinuxPlaybackRuntimeProblem.libraryUnloadable,
      );
    });

    test('a dependency at the wrong version reads as incompatible', () {
      expect(
        LinuxPlaybackRuntime.recogniseText(
          "Invalid argument(s): Failed to load dynamic library 'libmpv.so.2': "
          "/lib/libmpv.so.2: version `GLIBC_2.38' not found "
          '(required by /lib/libmpv.so.2)',
        ),
        LinuxPlaybackRuntimeProblem.libraryIncompatible,
      );
    });

    test('a missing Linux plugin reads as a backend that did not start', () {
      expect(
        LinuxPlaybackRuntime.recognise(
          MissingPluginException('No implementation found'),
        ),
        LinuxPlaybackRuntimeProblem.backendInitializationFailed,
      );
    });
  });

  group('what is deliberately NOT a runtime problem', () {
    // The half of this that matters most: a machine with a perfectly good
    // libmpv still produces all of these, and calling any of them "install
    // libmpv" would send the listener to fix the wrong thing.
    final Map<String, Object> notRuntimeFailures = <String, Object>{
      'an unsupported codec': Exception(
        'Unsupported format: no decoder for this stream',
      ),
      'a server that will not answer': Exception(
        'Connection refused: the host is unreachable',
      ),
      'a dropped connection mid-stream': Exception(
        'SocketException: connection reset by peer',
      ),
      'a provider rejecting the session': Exception(
        'HTTP 401 Unauthorized',
      ),
      'a stream that came back as a web page': Exception(
        'Expected audio, got text/html',
      ),
      'a corrupt file': Exception('Failed to parse the container header'),
      'a programming mistake': StateError('queue index out of range'),
      'a missing argument': ArgumentError.notNull('track'),
    };

    for (final MapEntry<String, Object> entry in notRuntimeFailures.entries) {
      test('${entry.key} is not classified as a runtime problem', () {
        expect(LinuxPlaybackRuntime.recognise(entry.value), isNull);
      });
    }

    test('a track whose own URI contains "libmpv" is still a track failure',
        () {
      // libmpv reports an unplayable track as `Failed to open <uri>` and the
      // vendored backend passes that text through verbatim, so without
      // redacting the URI first this song would cost the listener Skip, "Try
      // another source", and a pointless trip to their package manager.
      expect(
        LinuxPlaybackRuntime.recognise(
          Exception('Failed to open file:///music/libmpv-demo.flac.'),
        ),
        isNull,
      );
    });

    test('a stream URL mentioning the runtime is left alone too', () {
      expect(
        LinuxPlaybackRuntime.recognise(
          Exception(
            'Failed to open https://music.example/stream/mpv_session?x=1.',
          ),
        ),
        isNull,
      );
    });

    test('a bare path to a track named after the runtime is left alone', () {
      expect(
        LinuxPlaybackRuntime.recognise(
          Exception('Failed to open /music/libmpv.so.flac.'),
        ),
        isNull,
      );
    });

    test('redaction does not blind the classifier to a real loader error', () {
      // The half that must keep working: what identifies a loader complaint
      // (the quoted soname, "cannot open shared object file", the ELF class)
      // does not live inside the path that gets taken out.
      expect(
        LinuxPlaybackRuntime.recogniseText(loaderWrongClass),
        LinuxPlaybackRuntimeProblem.libraryIncompatible,
      );
      expect(
        LinuxPlaybackRuntime.recogniseText(loaderRefused),
        LinuxPlaybackRuntimeProblem.libraryUnloadable,
      );
      expect(
        LinuxPlaybackRuntime.recogniseText(loaderNotThere),
        LinuxPlaybackRuntimeProblem.libraryMissing,
      );
    });

    test('an error that merely says "unsupported" is left alone', () {
      // "unsupported version" is one of the incompatible markers; on its own,
      // with nothing about the native runtime, the gate has to reject it
      // first, or every unsupported codec would read as a broken libmpv.
      expect(
        LinuxPlaybackRuntime.recognise(
          Exception('Unsupported version of this audio format'),
        ),
        isNull,
      );
    });
  });

  group('what the listener is told', () {
    for (final LinuxPlaybackRuntimeProblem problem
        in LinuxPlaybackRuntimeProblem.values) {
      for (final bool bundled in <bool>[false, true]) {
        test('${problem.name} (bundled: $bundled) is actionable and safe', () {
          final String message = LinuxPlaybackRuntime.messageFor(
            problem,
            bundledRuntime: bundled,
          );

          expect(message, isNotEmpty);
          expect(message, endsWith('.'));
          // Nothing about the machine, and nothing about what was playing.
          expect(message, isNot(contains('/')));
          expect(message, isNot(contains('\\')));
          expect(message, isNot(contains('://')));
          expect(message.toLowerCase(), isNot(contains('exception')));
          expect(message.toLowerCase(), isNot(contains('elf')));
        });
      }
    }

    test('a distribution build points at the package manager', () {
      final String message = LinuxPlaybackRuntime.messageFor(
        LinuxPlaybackRuntimeProblem.libraryMissing,
        bundledRuntime: false,
      );

      expect(message, contains('libmpv'));
      expect(message, contains('Retry'));
      expect(message, isNot(contains('Flathub')));
    });

    test('a Flatpak is never told to install a host package', () {
      // The Flatpak bundles its own libmpv and never loads the host's, so the
      // host package is not the fix and naming it would waste the user's time.
      final String message = LinuxPlaybackRuntime.messageFor(
        LinuxPlaybackRuntimeProblem.libraryMissing,
        bundledRuntime: true,
      );

      expect(message, contains('Flathub'));
      expect(message, isNot(contains('apt')));
      expect(message, isNot(contains('Fedora')));
    });
  });

  group('the diagnostic kept for developers', () {
    test('drops absolute paths', () {
      final String diagnostic =
          LinuxPlaybackRuntime.sanitizeRuntimeDiagnostic(loaderWrongClass);

      expect(diagnostic, isNot(contains('/home/ada')));
      expect(diagnostic, isNot(contains('ada')));
      expect(diagnostic, contains('<path>'));
      // The reason itself survives, which is the whole point of keeping it.
      expect(diagnostic, contains('wrong ELF class'));
    });

    test('drops a whole path, not just the part that looks path-shaped', () {
      // A Linux path may contain spaces, so an allowlist of "path characters"
      // stops at the first one and leaves the rest of somebody's name in a
      // line that claims to carry no paths.
      final String diagnostic = LinuxPlaybackRuntime.sanitizeRuntimeDiagnostic(
        Exception(
          "Failed to load dynamic library 'libmpv.so.2': "
          '/home/Ada Lovelace/lib/libmpv.so.2: wrong ELF class',
        ),
      );

      expect(diagnostic, isNot(contains('Ada')));
      expect(diagnostic, isNot(contains('Lovelace')));
      expect(diagnostic, contains('<path>'));
      expect(diagnostic, contains('wrong ELF class'));
    });

    test('drops a whole URI, not just the part before a space', () {
      final String diagnostic = LinuxPlaybackRuntime.sanitizeRuntimeDiagnostic(
        Exception('Failed to open file:///music/Ada Lovelace/track.flac.'),
      );

      expect(diagnostic, isNot(contains('Lovelace')));
      expect(diagnostic, contains('<url>'));
    });

    test('drops URLs', () {
      expect(
        LinuxPlaybackRuntime.sanitizeRuntimeDiagnostic(
          Exception('libmpv failed on https://music.example/stream?token=abc'),
        ),
        allOf(
          isNot(contains('music.example')),
          isNot(contains('token')),
          contains('<url>'),
        ),
      );
    });

    test('collapses a multi-line error onto one line', () {
      expect(
        LinuxPlaybackRuntime.sanitizeRuntimeDiagnostic(
          Exception('libmpv failed\n    and this is the second line'),
        ),
        allOf(isNot(contains('\n')), contains('and this is the second line')),
      );
    });

    test('is bounded', () {
      final String diagnostic = LinuxPlaybackRuntime.sanitizeRuntimeDiagnostic(
        Exception('libmpv ${'x' * 5000}'),
      );

      expect(
        diagnostic.length,
        lessThanOrEqualTo(LinuxPlaybackRuntime.maxDiagnosticLength + 1),
      );
    });
  });

  test('a runtime failure travels as an engine-unavailable resolution error',
      () {
    const LinuxPlaybackRuntimeFailure failure = LinuxPlaybackRuntimeFailure(
      problem: LinuxPlaybackRuntimeProblem.libraryMissing,
      message: 'Install libmpv, then choose Retry.',
      diagnostic: 'cannot find libmpv',
    );

    final PlaybackResolutionException error = failure.asResolutionException();

    expect(error.kind, PlaybackResolutionErrorKind.playbackEngineUnavailable);
    expect(error.message, failure.message);
    // The retained diagnostic stays retained: it is not what the player shows.
    expect(error.message, isNot(contains(failure.diagnostic)));
  });
}
