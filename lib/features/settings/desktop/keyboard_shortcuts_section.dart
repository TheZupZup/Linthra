import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../app/shortcuts/keyboard_shortcuts_controller.dart';
import '../../../app/shortcuts/shortcut_action.dart';
import '../../../app/shortcuts/shortcut_binding.dart';

/// The "Keyboard shortcuts" card on the Music & playback settings page (#391).
///
/// Desktop-only (the screen decides that): the shortcuts themselves work
/// wherever a real keyboard sends the chord, including an Android tablet with a
/// keyboard case, but *remapping* is a desktop concern and the card would be
/// dead weight on a phone.
///
/// One row per action, each showing what it is bound to now. Changing one opens
/// a small dialog that listens for a chord — typing the combination is the only
/// honest way to pick one, since a dropdown of every key would be unusable and
/// would still not express a modifier.
///
/// Nothing here knows what a shortcut *does*. The registry owns the list, the
/// controller owns validation and conflicts, and this card only renders them —
/// which is why a refusal reads the same here as it would anywhere else that
/// ever offers rebinding.
class KeyboardShortcutsSettingsSection extends ConsumerWidget {
  const KeyboardShortcutsSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final AsyncValue<Map<ShortcutAction, ShortcutBinding>> bindings =
        ref.watch(keyboardShortcutsControllerProvider);
    final KeyboardShortcutsController controller =
        ref.read(keyboardShortcutsControllerProvider.notifier);
    final Map<ShortcutAction, ShortcutBinding> current =
        bindings.valueOrNull ?? ShortcutActions.defaults;
    final bool anyOverridden =
        ShortcutAction.values.any(controller.isOverridden);

    Future<void> resetEverything() async {
      try {
        await controller.resetAll();
      } catch (_) {
        if (!context.mounted) return;
        // The defaults are already showing and the button has gone quiet with
        // them, so without this the only clue would be the overrides coming
        // back on the next launch.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Reset for now, but it could not be written. Your old shortcuts '
              'will come back when you restart.',
            ),
          ),
        );
      }
    }

    Future<void> reset(ShortcutActionDefinition definition) async {
      final ShortcutUpdateResult result =
          await controller.resetToDefault(definition.action);
      if (result.isApplied || !context.mounted) return;
      // A default can be occupied by whatever the user put there in the
      // meantime, and a reset button that quietly did nothing would be the
      // worst of the three possible outcomes.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not reset ${definition.label}. ${result.message}',
          ),
        ),
      );
    }

    Future<void> rebind(ShortcutActionDefinition definition) async {
      // Taps are ignored until the stored map has loaded, so a fast one cannot
      // be overwritten by a value still on its way in from storage.
      if (bindings.isLoading) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _RecordShortcutDialog(definition: definition),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('Keyboard shortcuts', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Media keys are handled by your desktop, so they are not listed '
              'here.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.sm),
            for (final ShortcutActionDefinition definition
                in ShortcutActions.definitions)
              _ShortcutRow(
                definition: definition,
                binding:
                    current[definition.action] ?? definition.defaultBinding,
                isOverridden: controller.isOverridden(definition.action),
                onChange: () => rebind(definition),
                onReset: () => reset(definition),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: anyOverridden ? resetEverything : null,
                icon: const Icon(Icons.settings_backup_restore, size: 18),
                label: const Text('Reset all to defaults'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One action's row: what it is, what it is bound to, and the two things you
/// can do about it.
class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({
    required this.definition,
    required this.binding,
    required this.isOverridden,
    required this.onChange,
    required this.onReset,
  });

  final ShortcutActionDefinition definition;
  final ShortcutBinding binding;
  final bool isOverridden;
  final VoidCallback onChange;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: <Widget>[
          // Both texts give way, and the chord gets the larger share: it is
          // the longer of the two and the one that grows without bound. Every
          // modifier at once on a long key name is a combination the rules
          // accept, and at 420 px a fixed-width chord pushed the two controls
          // clean off the window — including the reset that would have undone
          // it.
          Expanded(flex: 3, child: Text(definition.label)),
          const SizedBox(width: AppSpacing.xs),
          // The combination reads as one thing, not as the row's label plus a
          // string of key names, so a screen reader says "Library, Ctrl + L,
          // change shortcut" rather than spelling out the chord twice.
          Expanded(
            flex: 4,
            child: Text(
              binding.label,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          IconButton(
            onPressed: onChange,
            icon: const Icon(Icons.edit_outlined, size: 18),
            tooltip: 'Change the ${definition.label} shortcut',
          ),
          IconButton(
            // Nothing to undo when it is already the default, and a live
            // button that did nothing would be worse than a quiet one.
            onPressed: isOverridden ? onReset : null,
            icon: const Icon(Icons.undo, size: 18),
            tooltip: 'Reset ${definition.label} to its default',
          ),
        ],
      ),
    );
  }
}

/// Listens for one chord and offers to bind it.
///
/// It records rather than applies: the chord is shown, checked, and only
/// committed when the user says so, because a dialog that bound the first thing
/// it heard would bind the Tab that got you into it.
class _RecordShortcutDialog extends ConsumerStatefulWidget {
  const _RecordShortcutDialog({required this.definition});

  final ShortcutActionDefinition definition;

  @override
  ConsumerState<_RecordShortcutDialog> createState() =>
      _RecordShortcutDialogState();
}

class _RecordShortcutDialogState extends ConsumerState<_RecordShortcutDialog> {
  final FocusNode _node = FocusNode(debugLabel: 'record shortcut');

  ShortcutBinding? _recorded;
  String? _message;

  /// Whether a save is already on its way to storage. Save is awaited, so
  /// without this a second click (or a second Enter on the focused button)
  /// started a second write before the first had popped the dialog.
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _node.requestFocus();
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  /// Reads the chord off a key-down event.
  ///
  /// Escape and Tab are let through untouched: neither can be bound anyway
  /// (both are reserved), and swallowing them would trap the user in a dialog
  /// whose whole purpose is pressing keys — no way out with Escape, and no way
  /// to reach Cancel or Save with the keyboard.
  KeyEventResult _record(FocusNode node, KeyEvent event) {
    if (_passThrough(event.logicalKey)) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.handled;

    final Set<LogicalKeyboardKey> held =
        HardwareKeyboard.instance.logicalKeysPressed;
    bool anyOf(List<LogicalKeyboardKey> keys) => keys.any(held.contains);

    final ShortcutBinding candidate = ShortcutBinding(
      event.logicalKey,
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

    final ShortcutBindingProblem? problem = candidate.problem;
    setState(() {
      if (problem == ShortcutBindingProblem.modifierOnly) {
        // Mid-chord: the user is holding Ctrl and has not chosen a key yet.
        // Not an error worth shouting about, so say nothing and wait.
        _recorded = null;
        _message = null;
        return;
      }
      _recorded = candidate;
      if (problem != null) {
        _message = describeShortcutProblem(problem);
        return;
      }
      final ShortcutAction? clash = ref
          .read(keyboardShortcutsControllerProvider.notifier)
          .conflictFor(widget.definition.action, candidate);
      _message = clash == null
          ? null
          : 'Already used by ${ShortcutActions.definitionFor(clash).label}.';
    });
    return KeyEventResult.handled;
  }

  /// Keys the recorder must never eat, on the way down *or* up: a swallowed
  /// key-up leaves the toolkit thinking the key is still held.
  static bool _passThrough(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.tab;

  Future<void> _apply() async {
    final ShortcutBinding? binding = _recorded;
    if (binding == null || _saving) return;
    setState(() => _saving = true);
    final ShortcutUpdateResult result;
    try {
      result = await ref
          .read(keyboardShortcutsControllerProvider.notifier)
          .setBinding(widget.definition.action, binding);
    } catch (_) {
      // A write that throws must not leave the dialog shut: Save and Cancel
      // are both off while `_saving`, and the door is held against Escape, so
      // an unhandled failure here would trap the user in the modal until they
      // restarted the app. The binding itself is live for this session — the
      // controller publishes before it writes — so the message says what did
      // and did not happen rather than pretending nothing changed.
      if (!mounted) return;
      setState(() {
        _saving = false;
        _message = 'Could not save this. It will work until you restart.';
      });
      return;
    }
    if (!mounted) return;
    if (result.isApplied) {
      Navigator.of(context).pop();
      return;
    }
    // Belt and braces: the recorder already checks, but the controller is the
    // authority and its wording is the one to show.
    setState(() {
      _saving = false;
      _message = result.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // While the write is on its way to storage the binding has already been
      // applied, so Escape and a tap on the scrim would close the dialog on a
      // change that is going through anyway — a cancel that cancels nothing.
      // `canPop` gates `maybePop`, which is what those two use; the successful
      // path below pops the route directly and is unaffected.
      canPop: !_saving,
      child: _dialog(context),
    );
  }

  Widget _dialog(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ShortcutBinding? recorded = _recorded;
    final bool canApply = recorded != null && _message == null && !_saving;

    return AlertDialog(
      title: Text(widget.definition.label),
      content: Focus(
        focusNode: _node,
        onKeyEvent: _record,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              widget.definition.description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Semantics(
              // Announced as one live value, so pressing a chord reads as the
              // chord rather than as a label and a mystery string.
              liveRegion: true,
              label: recorded == null
                  ? 'Press the keys you want to use'
                  : 'Recorded ${recorded.label}',
              excludeSemantics: true,
              child: Text(
                recorded?.label ?? 'Press the keys you want to use',
                style: theme.textTheme.titleMedium,
              ),
            ),
            if (_message != null) ...<Widget>[
              const SizedBox(height: AppSpacing.xs),
              Text(
                _message!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: canApply ? _apply : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
