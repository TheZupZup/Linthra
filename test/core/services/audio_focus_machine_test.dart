// The audio focus machine, which runs in the Rust core
// (native/linthra_core/src/audio_focus.rs): a few scenarios that spell out
// what it is for, through the same calls the player makes.
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/audio_focus_machine.dart';

List<String> _names(List<int> steps) => <String>[
      for (final int step in steps)
        step >= diagnosticBase
            ? FocusDiagnostic.values[step - diagnosticBase].label
            : FocusCommand.values[step].name,
    ];

void main() {
  {
    group('scenarios', () {
      const FocusContext playing = FocusContext(playing: true);

      test('a call pauses after the debounce, and its end resumes', () {
        final AudioFocusMachine m = AudioFocusMachine();
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
        final AudioFocusMachine m = AudioFocusMachine();
        m.handle(FocusEvent.pauseTransient, context: playing);
        m.handle(FocusEvent.pauseDebounceFired);
        m.handle(FocusEvent.pauseTransient);
        m.handle(FocusEvent.pauseDebounceFired);
        expect(_names(m.handle(FocusEvent.resume)),
            <String>['regain:resumed', 'enqueueResume']);
      });

      test('a blip inside the debounce never pauses', () {
        final AudioFocusMachine m = AudioFocusMachine();
        m.handle(FocusEvent.pauseTransient, context: playing);
        final List<String> regain = _names(m.handle(FocusEvent.resume));
        expect(regain, isNot(contains('enqueuePause')));
        expect(regain, contains('regain:churn-absorbed'));
        expect(m.bits, 0);
      });

      test('a regain after the listener paused never resumes', () {
        final AudioFocusMachine m = AudioFocusMachine();
        m.handle(FocusEvent.pauseTransient, context: playing);
        m.handle(FocusEvent.pauseDebounceFired);
        m.handle(FocusEvent.pause);
        expect(_names(m.handle(FocusEvent.resume)), <String>['regain:ignored']);
      });

      test('a duck lowers the volume and its end restores it', () {
        final AudioFocusMachine m = AudioFocusMachine();
        expect(_names(m.handle(FocusEvent.duck)),
            <String>['loss-duck:ducked', 'applyVolume']);
        expect(m.ducked, isTrue);
        expect(_names(m.handle(FocusEvent.unduck)),
            <String>['unduck:restored', 'applyVolume']);
        expect(m.ducked, isFalse);
      });

      test('unplugged headphones pause for good', () {
        final AudioFocusMachine m = AudioFocusMachine();
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
        final AudioFocusMachine m = AudioFocusMachine();
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
