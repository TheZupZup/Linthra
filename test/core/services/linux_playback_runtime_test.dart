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

/// What the dynamic loader says for each of the three cases the app has to
/// tell apart, in the shape Dart's `DynamicLibrary.open` reports them.
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

LinuxNativeLibraryProbe probeSaying(Map<String, String?> answers) =>
    (String soname) => answers[soname];

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

  group('sharpening a missing-library verdict with the loader', () {
    test('every name absent stays missing', () {
      expect(
        LinuxPlaybackRuntime.refine(
          LinuxPlaybackRuntimeProblem.libraryMissing,
          probeSaying(<String, String?>{
            for (final String soname in libmpvSonames) soname: loaderNotThere,
          }),
        ),
        LinuxPlaybackRuntimeProblem.libraryMissing,
      );
    });

    test('one name refused for permissions becomes unloadable', () {
      expect(
        LinuxPlaybackRuntime.refine(
          LinuxPlaybackRuntimeProblem.libraryMissing,
          probeSaying(<String, String?>{
            'libmpv.so': loaderRefused,
            'libmpv.so.2': loaderNotThere,
            'libmpv.so.1': loaderNotThere,
          }),
        ),
        LinuxPlaybackRuntimeProblem.libraryUnloadable,
      );
    });

    test('one name of the wrong architecture becomes incompatible', () {
      // Most specific wins: a 32-bit libmpv.so sitting next to two names that
      // simply are not there is the fact worth reporting, because "install the
      // package you already have" is not advice.
      expect(
        LinuxPlaybackRuntime.refine(
          LinuxPlaybackRuntimeProblem.libraryMissing,
          probeSaying(<String, String?>{
            'libmpv.so': loaderNotThere,
            'libmpv.so.2': loaderWrongClass,
            'libmpv.so.1': loaderRefused,
          }),
        ),
        LinuxPlaybackRuntimeProblem.libraryIncompatible,
      );
    });

    test(
        'a library that loads fine means the backend failed for some other '
        'reason', () {
      expect(
        LinuxPlaybackRuntime.refine(
          LinuxPlaybackRuntimeProblem.libraryMissing,
          probeSaying(const <String, String?>{}),
        ),
        LinuxPlaybackRuntimeProblem.backendInitializationFailed,
      );
    });

    test('a verdict that is already specific is never second-guessed', () {
      var probes = 0;
      expect(
        LinuxPlaybackRuntime.refine(
          LinuxPlaybackRuntimeProblem.libraryIncompatible,
          (String _) {
            probes++;
            return loaderNotThere;
          },
        ),
        LinuxPlaybackRuntimeProblem.libraryIncompatible,
      );
      expect(probes, 0);
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
