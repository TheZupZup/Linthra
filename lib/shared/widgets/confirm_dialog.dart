import 'package:flutter/material.dart';

/// Shows a confirmation dialog and resolves to `true` only when the user taps
/// the confirm action (a dismiss/back/Cancel resolves to `false`).
///
/// Every destructive action in Linthra routes through this so the wording is
/// consistent: an explicit `Cancel` and a clearly-labelled action button (e.g.
/// "Remove", "Delete", "Delete from server") — never a vague "OK". When
/// [destructive] is true (the default) the action button is tinted with the
/// error colour so it reads as a deliberate, irreversible-feeling choice.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool destructive = true,
}) async {
  final bool? result = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) {
      final ThemeData theme = Theme.of(dialogContext);
      return AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(cancelLabel),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                    foregroundColor: theme.colorScheme.onError,
                  )
                : null,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return result ?? false;
}
