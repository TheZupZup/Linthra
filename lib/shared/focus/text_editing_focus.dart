import 'package:flutter/widgets.dart';

/// Whether the keyboard is currently inside a text field.
///
/// One question, asked in two places that must never disagree: the list
/// navigation helper (#390), where Home and End are the ends of a *line* while
/// you are typing, and the app-wide shortcut dispatcher (#391), where a chord
/// the field itself owns must reach the field rather than skip a track.
///
/// Checked through the ancestors as well as the focused widget itself: a
/// field's focus node is attached to the [Focus] inside its [EditableText], so
/// the widget directly under the node is one step below the thing the question
/// is actually about.
bool isEditingText(BuildContext context) =>
    context.widget is EditableText ||
    context.findAncestorWidgetOfExactType<EditableText>() != null;

/// Whether whatever holds the keyboard right now is a text field.
///
/// The no-argument form, for a caller with no context of its own to ask from —
/// the shortcut dispatcher sits above the router and only ever gets to ask
/// about the *primary* focus.
bool primaryFocusIsEditingText() {
  final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
  return focused != null && isEditingText(focused);
}
