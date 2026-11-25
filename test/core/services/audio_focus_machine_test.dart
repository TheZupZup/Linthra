// The audio focus machine, in Dart and in the Rust core
// (native/linthra_core/src/audio_focus.rs).
//
// Its inputs are small: 16 states, 15 events and 8 contexts. So the two are
// compared on every one of them, and a few scenarios spell out what the
// machine is for.
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/native/linthra_core.dart';
import 'package:linthra/core/services/audio_focus_machine.dart';

List<String> _names(List<int> steps) => <String>[
      for (final int step in steps)
        step >= diagnosticBase
            ? FocusDiagnostic.values[step - diagnosticBase].label
            : FocusCommand.values[step].name,
    ];

void main() {
  test('the Rust core and Dart agree on every state, event and context',
      skip: LinthraCore.isAvailable ? false : 'Rust core not built', () {
    int compared = 0;
    for (int state = 0; state < 16; state++) {
      for (final FocusEvent event in FocusEvent.values) {
        for (int bits = 0; bits < 8; bits++) {
          final FocusContext context = FocusContext(
            playing: bits & 1 != 0,
            loadingToPlay: bits & 2 != 0,
            recoveryUnderway: bits & 4 != 0,
          );
          final AudioFocusMachine rust = AudioFocusMachine()..bits = state;
          final AudioFocusMachine dart = AudioFocusMachine(useNative: false)
            ..bits = state;
          final List<int> rustSteps = rust.handle(event, context: context);
          final List<int> dartSteps = dart.handle(event, context: context);
          final String where = 'state=$state $event context=$bits';
          expect(_names(rustSteps), _names(dartSteps), reason: where);
          expect(rust.bits, dart.bits, reason: where);
          compared++;
        }
      }
    }
    expect(compared, 16 * 15 * 8);
  });

  for (final bool useNative in <bool>[false, true]) {
    final String path = useNative ? 'Rust' : 'Dart';
    final Object skip =
        !useNative || LinthraCore.isAvailable ? false : 'Rust core not built';

    group('scenarios ($path)', skip: skip, () {
      const FocusContext playing = FocusContext(playing: true);

      test('a call pauses after the debounce, and its end resumes', () {
        final AudioFocusMachine m = AudioFocusMachine(useNative: useNative);
        expect(
            _names(m.handle(FocusEvent.pauseTransient, context: playing)),
            <String>[
              'startHoldTimer',
              'emitState',
              'startPauseTimer',
              'loss-transient:scheduled armed=true',
            ]);
        expect(_names(m.handle(FocusEvent.pauseDebounceFired)),
            <String>['loss-transient:paused', 'enqueuePause']);
        expect(m.heldForTransientFocus, isTrue);
        expect(_names(m.handle(FocusEvent.resume)),
            <String>['regain:resumed', 'enqueueResume']);
        // The hold bridges the resume until the engine sounds again.
        expect(m.held, isTrue);
        expect(_names(m.handle(FocusEvent.enginePlaying)),
            <String>['cancelHoldTimer']);
        expect(m.bits, 0);
      });

      test('a second loss in one voice session keeps the resume armed', () {
        // The first loss paused; the second arrives while paused, which on
        // its own would read as "nothing was playing".
        final AudioFocusMachine m = AudioFocusMachine(useNative: useNative);
        m.handle(FocusEvent.pauseTransient, context: playing);
        m.handle(FocusEvent.pauseDebounceFired);
        m.handle(FocusEvent.pauseTransient);
        m.handle(FocusEvent.pauseDebounceFired);
        expect(_names(m.handle(FocusEvent.resume)),
            <String>['regain:resumed', 'enqueueResume']);
      });

      test('a blip inside the debounce never pauses', () {
        final AudioFocusMachine m = AudioFocusMachine(useNative: useNative);
        m.handle(FocusEvent.pauseTransient, context: playing);
        final List<String> regain = _names(m.handle(FocusEvent.resume));
        expect(regain, isNot(contains('enqueuePause')));
        expect(regain, contains('regain:churn-absorbed'));
        expect(m.bits, 0);
      });

      test('a regain after the listener paused never resumes', () {
        final AudioFocusMachine m = AudioFocusMachine(useNative: useNative);
        m.handle(FocusEvent.pauseTransient, context: playing);
        m.handle(FocusEvent.pauseDebounceFired);
        m.handle(FocusEvent.pause);
        expect(_names(m.handle(FocusEvent.resume)), <String>['regain:ignored']);
      });

      test('a duck lowers the volume and its end restores it', () {
        final AudioFocusMachine m = AudioFocusMachine(useNative: useNative);
        expect(_names(m.handle(FocusEvent.duck)),
            <String>['loss-duck:ducked', 'applyVolume']);
        expect(m.ducked, isTrue);
        expect(_names(m.handle(FocusEvent.unduck)),
            <String>['unduck:restored', 'applyVolume']);
        expect(m.ducked, isFalse);
      });

      test('unplugged headphones pause for good', () {
        final AudioFocusMachine m = AudioFocusMachine(useNative: useNative);
        m.handle(FocusEvent.pauseTransient, context: playing);
        expect(_names(m.handle(FocusEvent.becomingNoisy)), <String>[
          'cancelHoldTimer',
          'emitState',
          'clearPlayWhenLoaded',
          'cancelPauseTimer',
          'haltRecovery',
          'noisy:paused',
          'enqueuePause',
        ]);
        expect(m.bits, 0);
      });

      test('a hold that runs out takes the resume with it', () {
        final AudioFocusMachine m = AudioFocusMachine(useNative: useNative);
        m.handle(FocusEvent.pauseTransient, context: playing);
        m.handle(FocusEvent.pauseDebounceFired);
        expect(_names(m.handle(FocusEvent.holdExpired)), <String>[
          'hold:expired',
          'cancelHoldTimer',
          'emitState',
          'clearPlayWhenLoaded',
          'haltRecovery',
        ]);
        expect(_names(m.handle(FocusEvent.resume)), <String>['regain:ignored']);
      });
    });
  }
}
