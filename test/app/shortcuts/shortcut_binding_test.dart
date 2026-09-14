import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/shortcuts/shortcut_binding.dart';

/// What a key combination is allowed to be (#391).
///
/// Two jobs, and both are about not breaking the keyboard. A binding must never
/// be able to eat a keystroke somebody meant as typing, and it must never take
/// over a key the app itself needs to move around or close things. Everything
/// refused here is refused with a reason a person can act on.

void main() {
  group('validity', () {
    test('a bare letter is refused: it would eat typing app-wide', () {
      const ShortcutBinding bare = ShortcutBinding(LogicalKeyboardKey.keyK);
      expect(bare.problem, ShortcutBindingProblem.needsModifier);
      expect(bare.isValid, isFalse);
    });

    test('the same letter with a modifier is fine', () {
      const ShortcutBinding chord =
          ShortcutBinding(LogicalKeyboardKey.keyK, control: true);
      expect(chord.problem, isNull);
      expect(chord.isValid, isTrue);
    });

    test('Shift alone is not enough of a modifier', () {
      // Shift+K is just a capital K. It would still eat typing.
      const ShortcutBinding shifted =
          ShortcutBinding(LogicalKeyboardKey.keyK, shift: true);
      expect(shifted.problem, ShortcutBindingProblem.needsModifier);
    });

    test('a function key is fine bare: no text field produces one', () {
      for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.f1,
        LogicalKeyboardKey.f5,
        LogicalKeyboardKey.f12,
      ]) {
        expect(ShortcutBinding(key).problem, isNull, reason: '$key');
      }
    });

    test('a modifier on its own is not a shortcut', () {
      expect(
        const ShortcutBinding(LogicalKeyboardKey.controlLeft, control: true)
            .problem,
        ShortcutBindingProblem.modifierOnly,
      );
    });

    test('Escape and Tab are refused, modifier or not', () {
      for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.tab,
      ]) {
        expect(
            ShortcutBinding(key).problem, ShortcutBindingProblem.reservedKey);
        expect(
          ShortcutBinding(key, control: true, shift: true).problem,
          ShortcutBindingProblem.reservedKey,
          reason: 'a modifier does not make $key available',
        );
      }
    });

    test('bare navigation keys are refused, but a chord over them is not', () {
      expect(
        const ShortcutBinding(LogicalKeyboardKey.arrowRight).problem,
        ShortcutBindingProblem.reservedKey,
      );
      expect(
        const ShortcutBinding(LogicalKeyboardKey.arrowRight, control: true)
            .problem,
        isNull,
      );
    });

    test('a media key is refused: that is MPRIS territory, not ours', () {
      for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.mediaPlayPause,
        LogicalKeyboardKey.mediaTrackNext,
        LogicalKeyboardKey.mediaTrackPrevious,
        LogicalKeyboardKey.audioVolumeUp,
      ]) {
        expect(
          ShortcutBinding(key).problem,
          ShortcutBindingProblem.mediaKey,
          reason: '$key must stay with the desktop',
        );
        expect(
          ShortcutBinding(key, control: true).problem,
          ShortcutBindingProblem.mediaKey,
          reason: 'a modifier does not make $key ours either',
        );
      }
    });

    test('every problem has something a person can do about it', () {
      for (final ShortcutBindingProblem problem
          in ShortcutBindingProblem.values) {
        final String message = describeShortcutProblem(problem);
        expect(message, isNotEmpty);
        expect(message.endsWith('.'), isTrue, reason: message);
      }
    });
  });

  group('text editing', () {
    test('the caret, clipboard and IME keys belong to a focused field', () {
      for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.home,
        LogicalKeyboardKey.end,
        LogicalKeyboardKey.backspace,
        LogicalKeyboardKey.delete,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.keyA,
        LogicalKeyboardKey.keyC,
        LogicalKeyboardKey.keyV,
        LogicalKeyboardKey.keyZ,
      ]) {
        expect(
          conflictsWithTextEditing(ShortcutBinding(key, control: true)),
          isTrue,
          reason: '$key is a text-editing key',
        );
      }
    });

    test('an ordinary chord is not a text-editing key', () {
      // The rule is not "no shortcuts while typing" — Ctrl+K opens search from
      // inside a search field, which is where people press it.
      for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.keyK,
        LogicalKeyboardKey.keyF,
        LogicalKeyboardKey.keyL,
        LogicalKeyboardKey.keyU,
        LogicalKeyboardKey.keyP,
      ]) {
        expect(
          conflictsWithTextEditing(ShortcutBinding(key, control: true)),
          isFalse,
          reason: '$key is not something a field would have used',
        );
      }
    });
  });

  group('storage', () {
    test('a binding survives a round trip through storage', () {
      const List<ShortcutBinding> bindings = <ShortcutBinding>[
        ShortcutBinding(LogicalKeyboardKey.keyK, control: true),
        ShortcutBinding(LogicalKeyboardKey.arrowRight, control: true),
        ShortcutBinding(LogicalKeyboardKey.space, control: true, shift: true),
        ShortcutBinding(LogicalKeyboardKey.f5),
        ShortcutBinding(
          LogicalKeyboardKey.keyM,
          control: true,
          alt: true,
          shift: true,
          meta: true,
        ),
      ];
      for (final ShortcutBinding binding in bindings) {
        expect(
          ShortcutBinding.parse(binding.storageValue),
          binding,
          reason: binding.storageValue,
        );
      }
    });

    test('the stored form is canonical, so equal bindings store the same', () {
      const ShortcutBinding a =
          ShortcutBinding(LogicalKeyboardKey.keyK, control: true, shift: true);
      const ShortcutBinding b =
          ShortcutBinding(LogicalKeyboardKey.keyK, shift: true, control: true);
      expect(a, b);
      expect(a.storageValue, b.storageValue);
    });

    test('junk in storage reads as nothing, never as a wrong binding', () {
      for (final String? junk in <String?>[
        null,
        '',
        'ctrl',
        'ctrl+',
        'hyper+107',
        'ctrl+not-a-number',
        'ctrl+999999999999',
        '{"key":"k"}',
      ]) {
        expect(ShortcutBinding.parse(junk), isNull, reason: '$junk');
      }
    });

    test('a stored binding that today would be refused is dropped', () {
      // Written by a build with looser rules, or edited by hand. The action
      // must fall back to its default rather than ship a shortcut the app
      // would now refuse to set.
      const ShortcutBinding bare = ShortcutBinding(LogicalKeyboardKey.keyK);
      expect(ShortcutBinding.parse(bare.storageValue), isNull);
    });
  });

  group('label', () {
    test('modifiers read in a fixed order', () {
      expect(
        const ShortcutBinding(
          LogicalKeyboardKey.keyK,
          shift: true,
          control: true,
          alt: true,
        ).label,
        'Ctrl + Alt + Shift + K',
      );
    });

    test('keys with no printable character are still named', () {
      // debugName is not available in a release build, so these come from the
      // app's own table rather than printing as "Key 32".
      expect(
        const ShortcutBinding(LogicalKeyboardKey.space, control: true).label,
        'Ctrl + Space',
      );
      expect(
        const ShortcutBinding(LogicalKeyboardKey.arrowLeft, control: true)
            .label,
        'Ctrl + Left',
      );
      expect(const ShortcutBinding(LogicalKeyboardKey.f5).label, 'F5');
    });
  });

  test('a held key fires once, not once per repeat', () {
    const ShortcutBinding binding =
        ShortcutBinding(LogicalKeyboardKey.arrowRight, control: true);
    expect(binding.activator.includeRepeats, isFalse);
  });
}
