import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show SingleActivator;

/// Why a key combination cannot be used as a Linthra shortcut.
///
/// Every rejection has a reason a person can act on, because "invalid
/// shortcut" with no explanation is the same as no explanation at all. The
/// message the settings screen shows comes from [describeShortcutProblem], so
/// the rule and its wording live together and cannot drift.
enum ShortcutBindingProblem {
  /// Nothing but modifiers were pressed. Usually means the user is mid-chord.
  modifierOnly,

  /// A bare printable key. Binding one app-wide would take that letter away
  /// from every text field in Linthra the moment the field lost focus by a
  /// pixel — the exact hijacking this feature is supposed to avoid.
  needsModifier,

  /// A key the app itself depends on. Escape closes dialogs, leaves a
  /// selection and dismisses quick search; Tab and the arrows are how the
  /// keyboard moves. A shortcut that swallowed one would break navigation
  /// while appearing to work.
  reservedKey,

  /// A media key. These reach Linthra through MPRIS and the desktop's own
  /// media handling, which already works across every app and while Linthra is
  /// not focused. Re-binding one here would create a second, worse path that
  /// only fires when the window happens to have focus.
  mediaKey,

  /// A chord a control inside Linthra already answers. It would look bound and
  /// then quietly do nothing whenever that control had the keyboard.
  claimedByControl,
}

/// A short, plain sentence for [problem], for the settings screen to show
/// beside the field the user just typed into.
String describeShortcutProblem(ShortcutBindingProblem problem) {
  switch (problem) {
    case ShortcutBindingProblem.modifierOnly:
      return 'Add a key to the modifier, such as Ctrl and K.';
    case ShortcutBindingProblem.needsModifier:
      return 'Add Ctrl, Alt or Super, so the key still works when you type.';
    case ShortcutBindingProblem.reservedKey:
      return 'Linthra uses this key to move around and close things.';
    case ShortcutBindingProblem.mediaKey:
      return 'Media keys already reach Linthra through your desktop.';
    case ShortcutBindingProblem.claimedByControl:
      return 'A focused row already uses this to reorder or to open its menu.';
  }
}

/// Keys the app's own navigation and dismissal depend on, which a shortcut may
/// never take over. Arrow keys are only reserved *bare*; with a modifier they
/// are ordinary and make good transport bindings, which is what the defaults
/// use.
final Set<LogicalKeyboardKey> _reservedAlways = <LogicalKeyboardKey>{
  LogicalKeyboardKey.escape,
  LogicalKeyboardKey.tab,
};

final Set<LogicalKeyboardKey> _reservedBare = <LogicalKeyboardKey>{
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
  LogicalKeyboardKey.space,
  LogicalKeyboardKey.home,
  LogicalKeyboardKey.end,
  LogicalKeyboardKey.pageUp,
  LogicalKeyboardKey.pageDown,
  LogicalKeyboardKey.backspace,
  LogicalKeyboardKey.delete,
};

/// Handled by MPRIS and the desktop, never here. See [
/// ShortcutBindingProblem.mediaKey].
final Set<LogicalKeyboardKey> _mediaKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.mediaPlay,
  LogicalKeyboardKey.mediaPause,
  LogicalKeyboardKey.mediaPlayPause,
  LogicalKeyboardKey.mediaStop,
  LogicalKeyboardKey.mediaTrackNext,
  LogicalKeyboardKey.mediaTrackPrevious,
  LogicalKeyboardKey.audioVolumeUp,
  LogicalKeyboardKey.audioVolumeDown,
  LogicalKeyboardKey.audioVolumeMute,
};

/// Chords a control inside Linthra already answers, which are therefore not
/// free to bind.
///
/// Unlike [_reservedBare] these are whole combinations, because the modifier is
/// the point: `Ctrl+↑` and `Super+↑` move a row in a reorderable list
/// (`ReorderHandle`) and `Shift+F10` opens a row's context menu
/// (`ContextMenuRegion`) for keyboards with no menu key. Both are deliberate
/// accessibility bindings from #390, installed in a `Shortcuts` nearer the
/// keyboard than this one, so a global action bound here would simply never
/// fire while such a row had focus.
///
/// Refusing is the right half of that trade to take. Making the row controls
/// stand aside instead would take keyboard reordering away from whoever bound
/// a shortcut next to it, and a shortcut that is refused with a reason is
/// better than one that looks bound and does nothing.
final Set<ShortcutBinding> _claimedByControls = <ShortcutBinding>{
  const ShortcutBinding(LogicalKeyboardKey.arrowUp, control: true),
  const ShortcutBinding(LogicalKeyboardKey.arrowDown, control: true),
  const ShortcutBinding(LogicalKeyboardKey.arrowUp, meta: true),
  const ShortcutBinding(LogicalKeyboardKey.arrowDown, meta: true),
  const ShortcutBinding(LogicalKeyboardKey.f10, shift: true),
};

final Set<LogicalKeyboardKey> _modifierKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.control,
  LogicalKeyboardKey.controlLeft,
  LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.shift,
  LogicalKeyboardKey.shiftLeft,
  LogicalKeyboardKey.shiftRight,
  LogicalKeyboardKey.alt,
  LogicalKeyboardKey.altLeft,
  LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.meta,
  LogicalKeyboardKey.metaLeft,
  LogicalKeyboardKey.metaRight,
};

/// Keys a focused text field owns, whatever modifiers are held.
///
/// These are the caret, the selection and the clipboard: Ctrl+Left is "back one
/// word", Ctrl+A is "select all", Ctrl+Space is the input method. A shortcut
/// bound to one of them is perfectly fine in the app at large and must stand
/// down the moment the keyboard is inside a field, or Linthra skips a track
/// while somebody is trying to correct a typo.
///
/// This is a list of *trigger* keys rather than of whole chords on purpose. The
/// exact chord a toolkit or input method binds varies (GTK, Qt, ibus and fcitx
/// do not agree), so matching the key is the conservative reading: it can cost
/// a shortcut inside a field, which is recoverable by clicking away, where the
/// other direction costs the user their text.
final Set<LogicalKeyboardKey> _textEditingKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.home,
  LogicalKeyboardKey.end,
  LogicalKeyboardKey.pageUp,
  LogicalKeyboardKey.pageDown,
  LogicalKeyboardKey.backspace,
  LogicalKeyboardKey.delete,
  LogicalKeyboardKey.insert,
  // Input methods and completion widely use Ctrl+Space.
  LogicalKeyboardKey.space,
  // The clipboard and undo letters, which every toolkit binds with the primary
  // modifier and no text field would want intercepted.
  LogicalKeyboardKey.keyA,
  LogicalKeyboardKey.keyC,
  LogicalKeyboardKey.keyV,
  LogicalKeyboardKey.keyX,
  LogicalKeyboardKey.keyZ,
  LogicalKeyboardKey.keyY,
};

/// Whether [binding] must stand down while a text field holds the keyboard.
///
/// The rule the whole "don't hijack typing" requirement reduces to. Note what
/// it does *not* say: it is not "no shortcuts while typing". Ctrl+K opens quick
/// search from inside a search field, which is exactly where people press it,
/// and Linthra has always answered it there. Only the combinations a field
/// itself would have used are given back.
bool conflictsWithTextEditing(ShortcutBinding binding) =>
    _textEditingKeys.contains(binding.trigger);

/// The chord the keyboard is holding right now, or `null` when it is not a
/// chord this app could bind (nothing but modifiers, or several non-modifier
/// keys at once).
///
/// Read during key handling, so the guard can ask about the combination that
/// actually fired rather than about the action's stored binding. Those differ
/// whenever one action answers to more than one chord: search is bound to
/// Ctrl+K *and* the fixed Ctrl+F alias, and judging the alias by the primary's
/// text-editing risk would switch off a chord no text field ever wanted.
ShortcutBinding? pressedShortcutChord() {
  final Set<LogicalKeyboardKey> held =
      HardwareKeyboard.instance.logicalKeysPressed;
  bool anyOf(List<LogicalKeyboardKey> keys) => keys.any(held.contains);

  final List<LogicalKeyboardKey> triggers = held
      .where((LogicalKeyboardKey key) => !_modifierKeys.contains(key))
      .toList();
  if (triggers.length != 1) return null;

  return ShortcutBinding(
    triggers.single,
    control: anyOf(<LogicalKeyboardKey>[
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.controlRight,
    ]),
    shift: anyOf(<LogicalKeyboardKey>[
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.shiftRight,
    ]),
    alt: anyOf(<LogicalKeyboardKey>[
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.altRight,
    ]),
    meta: anyOf(<LogicalKeyboardKey>[
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.metaRight,
    ]),
  );
}

/// One key combination, as a value.
///
/// A value type rather than a [SingleActivator] because the app needs to do
/// three things an activator cannot: compare two bindings for a conflict, write
/// one to storage and read it back, and print it for a person. [activator] is
/// the one-way trip into Flutter's shortcut machinery.
@immutable
class ShortcutBinding {
  const ShortcutBinding(
    this.trigger, {
    this.control = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
  });

  /// The non-modifier key that fires it.
  final LogicalKeyboardKey trigger;

  final bool control;
  final bool shift;
  final bool alt;

  /// The Super/Command key. Linthra's desktop target is Linux, so nothing
  /// defaults to it — but the model carries it so a user can bind Super+key,
  /// and so a future macOS build has somewhere to put Command without the
  /// storage format changing under existing installs.
  final bool meta;

  /// Whether a modifier is held that makes this something other than a
  /// character.
  ///
  /// Shift deliberately does not count. Shift+K is a capital K: binding it
  /// app-wide would eat typing exactly the way a bare K would, which is the
  /// one thing these rules exist to prevent. Shift is only ever a *second*
  /// modifier here, widening Ctrl+K into Ctrl+Shift+K.
  bool get hasPrimaryModifier => control || alt || meta;

  /// Whether any modifier at all is held, Shift included.
  bool get hasModifier => control || shift || alt || meta;

  /// The activator Flutter matches key events against.
  ///
  /// `includeRepeats: false` is the whole answer to "holding the key fired the
  /// action forty times": a held key repeats as further key-down events, and
  /// without this every repeat would skip another track.
  SingleActivator get activator => SingleActivator(
        trigger,
        control: control,
        shift: shift,
        alt: alt,
        meta: meta,
        includeRepeats: false,
      );

  /// Why this cannot be used, or `null` when it can.
  ShortcutBindingProblem? get problem {
    if (_modifierKeys.contains(trigger)) {
      return ShortcutBindingProblem.modifierOnly;
    }
    if (_mediaKeys.contains(trigger)) return ShortcutBindingProblem.mediaKey;
    if (_reservedAlways.contains(trigger)) {
      return ShortcutBindingProblem.reservedKey;
    }
    if (_claimedByControls.contains(this)) {
      return ShortcutBindingProblem.claimedByControl;
    }
    if (!hasPrimaryModifier) {
      if (_reservedBare.contains(trigger)) {
        return ShortcutBindingProblem.reservedKey;
      }
      // A function key is safe bare: no text field produces one, so binding F5
      // cannot eat a keystroke someone meant as typing.
      if (!_isFunctionKey(trigger)) return ShortcutBindingProblem.needsModifier;
    }
    return null;
  }

  bool get isValid => problem == null;

  static bool _isFunctionKey(LogicalKeyboardKey key) {
    return key.keyId >= LogicalKeyboardKey.f1.keyId &&
        key.keyId <= LogicalKeyboardKey.f12.keyId;
  }

  /// How this reads in the settings screen and in a tooltip: "Ctrl + Shift + K".
  ///
  /// Modifiers always in the same order, so two bindings that differ only in
  /// the order they were typed still look identical — which is what makes a
  /// conflict obvious on screen as well as in code.
  String get label {
    final List<String> parts = <String>[
      if (control) 'Ctrl',
      if (alt) 'Alt',
      if (shift) 'Shift',
      if (meta) 'Super',
      _triggerLabel(trigger),
    ];
    return parts.join(' + ');
  }

  /// A readable name for [key].
  ///
  /// `LogicalKeyboardKey.debugName` is not available in a release build, so the
  /// keys a user is likely to bind are named here instead of the app shipping
  /// shortcuts that print as "Key 32" to everyone but developers.
  static String _triggerLabel(LogicalKeyboardKey key) {
    final String? special = _specialNames[key.keyId];
    if (special != null) return special;
    final String printable = key.keyLabel;
    if (printable.isNotEmpty) return printable.toUpperCase();
    return 'Key ${key.keyId}';
  }

  static final Map<int, String> _specialNames = <int, String>{
    LogicalKeyboardKey.space.keyId: 'Space',
    LogicalKeyboardKey.arrowLeft.keyId: 'Left',
    LogicalKeyboardKey.arrowRight.keyId: 'Right',
    LogicalKeyboardKey.arrowUp.keyId: 'Up',
    LogicalKeyboardKey.arrowDown.keyId: 'Down',
    LogicalKeyboardKey.enter.keyId: 'Enter',
    LogicalKeyboardKey.numpadEnter.keyId: 'Enter',
    LogicalKeyboardKey.escape.keyId: 'Esc',
    LogicalKeyboardKey.tab.keyId: 'Tab',
    LogicalKeyboardKey.home.keyId: 'Home',
    LogicalKeyboardKey.end.keyId: 'End',
    LogicalKeyboardKey.pageUp.keyId: 'Page Up',
    LogicalKeyboardKey.pageDown.keyId: 'Page Down',
    LogicalKeyboardKey.backspace.keyId: 'Backspace',
    LogicalKeyboardKey.delete.keyId: 'Delete',
    LogicalKeyboardKey.comma.keyId: 'Comma',
    LogicalKeyboardKey.period.keyId: 'Period',
    LogicalKeyboardKey.slash.keyId: 'Slash',
  };

  /// The stored form: modifier flags and the key's stable
  /// [LogicalKeyboardKey.keyId], e.g. `ctrl+shift+107`.
  ///
  /// Key ids come from the USB HID / Unicode tables Flutter derives them from,
  /// so they are stable across Flutter upgrades in a way that a key's *name*
  /// is not. Modifiers are always written in the same order, so the string is
  /// canonical and two equal bindings store identically.
  String get storageValue {
    final List<String> parts = <String>[
      if (control) 'ctrl',
      if (alt) 'alt',
      if (shift) 'shift',
      if (meta) 'meta',
      '${trigger.keyId}',
    ];
    return parts.join('+');
  }

  /// Reads back a [storageValue], or `null` when it cannot be trusted.
  ///
  /// Every failure path returns null rather than throwing or guessing: a
  /// preferences file written by a newer build, hand-edited, or truncated must
  /// leave the user with the *default* for that action, never with a crash on
  /// launch and never with a half-parsed binding that fires something else.
  static ShortcutBinding? parse(String? stored) {
    if (stored == null || stored.isEmpty) return null;
    final List<String> parts = stored.split('+');
    if (parts.isEmpty) return null;
    bool control = false;
    bool shift = false;
    bool alt = false;
    bool meta = false;
    for (final String part in parts.sublist(0, parts.length - 1)) {
      switch (part) {
        case 'ctrl':
          control = true;
        case 'shift':
          shift = true;
        case 'alt':
          alt = true;
        case 'meta':
          meta = true;
        default:
          return null;
      }
    }
    final int? keyId = int.tryParse(parts.last);
    if (keyId == null) return null;
    final LogicalKeyboardKey? key = LogicalKeyboardKey.findKeyByKeyId(keyId);
    if (key == null) return null;
    final ShortcutBinding binding = ShortcutBinding(
      key,
      control: control,
      shift: shift,
      alt: alt,
      meta: meta,
    );
    // A stored binding that today's rules reject (the rules tightened, or the
    // file was edited by hand) is dropped, so the action falls back to its
    // default instead of shipping a shortcut the app would refuse to set.
    return binding.isValid ? binding : null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ShortcutBinding &&
          other.trigger == trigger &&
          other.control == control &&
          other.shift == shift &&
          other.alt == alt &&
          other.meta == meta);

  @override
  int get hashCode => Object.hash(trigger, control, shift, alt, meta);

  @override
  String toString() => 'ShortcutBinding($label)';
}
