import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dimens.dart';
import '../../app/shortcuts/keyboard_shortcuts_controller.dart';
import '../../app/shortcuts/shortcut_action.dart';
import '../../app/shortcuts/shortcut_binding.dart';
import '../../data/repositories/host_platform_provider.dart';
import '../../shared/widgets/settings_section_header.dart';

/// Shows the keyboard shortcuts help window (#392) and returns when it closes.
///
/// [returnFocusTo] is the control that opened it, and is where the keyboard
/// goes again afterwards. Worth passing whenever there is one: Flutter does not
/// focus a button that was *clicked*, so without it a user who reached the
/// window with the mouse comes back to a page with no focus at all and their
/// next Tab restarts from the top. A caller with nothing to name (the shortcut
/// itself, which can fire from anywhere) leaves it out, and whatever held the
/// keyboard gets it back.
///
/// Both go through the same helper so the two entry points cannot disagree
/// about what closing the window does.
Future<void> showKeyboardShortcutsHelp(
  BuildContext context, {
  FocusNode? returnFocusTo,
}) async {
  final FocusNode? opener = returnFocusTo ?? FocusManager.instance.primaryFocus;

  await showDialog<void>(
    context: context,
    // The default, spelled out because the window depends on it: it is what
    // makes Escape close the dialog, through the `DismissIntent` every modal
    // route already answers. Handling Escape here as well would be a second
    // path to the same pop.
    barrierDismissible: true,
    builder: (_) => const KeyboardShortcutsHelpDialog(),
  );

  if (opener == null) return;
  // After the frame that removes the route: the pop unwinds focus as part of
  // it, and a request made now would be undone by that unwind.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // Gone while the window was open: the page behind it was popped, or the
    // window got narrow enough to drop the control. Leaving focus where
    // Flutter put it is the honest answer then. Asked as `mounted` rather than
    // as a null context, because a [FocusNode] keeps the last context it was
    // attached to even after that element is gone, and a null check alone
    // would read as "still there" for a control that is not.
    final BuildContext? still = opener.context;
    if (still == null || !still.mounted) return;
    opener.requestFocus();
  });
}

/// The help window itself: every shortcut Linthra answers, under its heading,
/// showing what it is bound to *now*.
///
/// It owns no list of its own. The rows come from [ShortcutActions.grouped] and
/// the combinations from [activeShortcutBindingsProvider], which are the same
/// registry the dispatcher installs and the same map the settings card edits.
/// A remap shows up here without anything being kept in step by hand, and a
/// shortcut cannot be documented as one thing and bound as another.
class KeyboardShortcutsHelpDialog extends StatelessWidget {
  const KeyboardShortcutsHelpDialog({super.key});

  /// Wide enough for an action, its description and a chord side by side, and
  /// no wider: this is a reference list, not a page.
  static const double _preferredWidth = 520;

  /// What [AlertDialog] spends on its own margins and padding, which the
  /// content does not get. Subtracted rather than assumed away so a narrow
  /// window shrinks the list instead of overflowing it.
  static const double _dialogChrome = 128;

  @override
  Widget build(BuildContext context) {
    final double available = MediaQuery.sizeOf(context).width - _dialogChrome;
    return AlertDialog(
      title: const Text('Keyboard shortcuts'),
      content: SizedBox(
        width: math.max(0, math.min(_preferredWidth, available)),
        child: const KeyboardShortcutsHelpList(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// The grouped list of shortcuts, without the window around it.
///
/// Separate from the dialog so it can be shown somewhere else later (a
/// settings page, a help sheet), and so a test can pump the list on its own.
class KeyboardShortcutsHelpList extends ConsumerStatefulWidget {
  const KeyboardShortcutsHelpList({super.key});

  @override
  ConsumerState<KeyboardShortcutsHelpList> createState() =>
      _KeyboardShortcutsHelpListState();
}

class _KeyboardShortcutsHelpListState
    extends ConsumerState<KeyboardShortcutsHelpList> {
  /// Its own controller rather than the primary one: [PrimaryScrollController]
  /// is not inherited on a desktop platform, and [Scrollbar] throws without a
  /// controller to attach to.
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final Map<ShortcutAction, ShortcutBinding> bindings =
        ref.watch(activeShortcutBindingsProvider);
    // The remapping card is desktop-only, so the pointer to it is too. The
    // window itself is not: a tablet with a keyboard case sends the chord like
    // any other keyboard, and sending that user to a settings page they do not
    // have would be worse than saying nothing.
    final bool canRemap = ref.watch(hostPlatformProvider).isDesktop;

    return Scrollbar(
      controller: _scroll,
      child: SingleChildScrollView(
        controller: _scroll,
        // Inside the scroll view, not around it: Flutter's [ScrollAction] looks
        // for a [Scrollable] above whatever holds the keyboard, so a focus stop
        // outside this one would leave Page Up/Down and Ctrl+arrow doing
        // nothing. Autofocused because that is the whole point: the window
        // opens ready to be read with the keyboard, and Tab moves on to Close.
        child: Focus(
          autofocus: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final ShortcutGroupListing listing
                  in ShortcutActions.grouped) ...<Widget>[
                SettingsSectionHeader(listing.group.label),
                for (final ShortcutActionDefinition definition
                    in listing.actions)
                  _ShortcutHelpRow(
                    definition: definition,
                    // The registry's own default while storage is still being
                    // read, which is what the app is answering at that moment
                    // too.
                    binding: bindings[definition.action] ??
                        definition.defaultBinding,
                  ),
              ],
              const SizedBox(height: AppSpacing.md),
              Text(
                <String>[
                  'Media keys are handled by your desktop, so they are not '
                      'listed here.',
                  if (canRemap)
                    'Shortcuts can be changed in Settings → Music & playback.',
                ].join(' '),
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One shortcut: what it does on the left, what it answers to on the right.
class _ShortcutHelpRow extends StatelessWidget {
  const _ShortcutHelpRow({required this.definition, required this.binding});

  final ShortcutActionDefinition definition;

  /// The combination in effect right now, not the shipped default.
  final ShortcutBinding binding;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final String aliases = definition.aliases
        .map((ShortcutBinding alias) => alias.label)
        .join(', ');

    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        // Both halves are [Expanded] and both wrap. A translated action name,
        // a long description and every modifier at once on a long key name all
        // grow the row taller instead of pushing anything off the window,
        // which a fixed-width chord, or an unwrapped label, would do at the
        // first language that is wordier than English.
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(definition.label, style: theme.textTheme.bodyMedium),
                  Text(
                    definition.description,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(
                    binding.label,
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                  // A fixed alias is a second combination the action always
                  // answers and that remapping never moves, so it belongs
                  // beside the binding rather than on a row of its own. On
                  // a row of its own it would read as a second shortcut to
                  // learn, which it is not.
                  if (aliases.isNotEmpty)
                    Text(
                      'or $aliases',
                      textAlign: TextAlign.end,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
