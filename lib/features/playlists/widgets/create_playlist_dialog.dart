import 'package:flutter/material.dart';

import '../../../core/models/playlist.dart';

/// The result of the create/rename playlist dialog.
typedef PlaylistEdit = ({
  String name,
  String? description,
  PlaylistSource source,
});

/// Shows the create-playlist dialog and resolves to the entered name (+ optional
/// description and chosen [PlaylistSource]), or `null` if cancelled or the name
/// was blank.
///
/// When [canSyncToJellyfin] is true a "Sync with Jellyfin" switch is offered so
/// the new playlist mirrors to the signed-in server; otherwise the playlist is
/// local-only.
Future<PlaylistEdit?> showCreatePlaylistDialog(
  BuildContext context, {
  bool canSyncToJellyfin = false,
}) {
  return showDialog<PlaylistEdit>(
    context: context,
    builder: (BuildContext context) => _PlaylistEditDialog(
      title: 'New playlist',
      confirmLabel: 'Create',
      canSyncToJellyfin: canSyncToJellyfin,
    ),
  );
}

/// Shows the rename dialog seeded with [initialName]/[initialDescription], and
/// resolves to the edited values (source is never changed by a rename).
Future<PlaylistEdit?> showRenamePlaylistDialog(
  BuildContext context, {
  required String initialName,
  String? initialDescription,
}) {
  return showDialog<PlaylistEdit>(
    context: context,
    builder: (BuildContext context) => _PlaylistEditDialog(
      title: 'Rename playlist',
      confirmLabel: 'Save',
      initialName: initialName,
      initialDescription: initialDescription,
    ),
  );
}

class _PlaylistEditDialog extends StatefulWidget {
  const _PlaylistEditDialog({
    required this.title,
    required this.confirmLabel,
    this.initialName,
    this.initialDescription,
    this.canSyncToJellyfin = false,
  });

  final String title;
  final String confirmLabel;
  final String? initialName;
  final String? initialDescription;
  final bool canSyncToJellyfin;

  @override
  State<_PlaylistEditDialog> createState() => _PlaylistEditDialogState();
}

class _PlaylistEditDialogState extends State<_PlaylistEditDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initialName ?? '');
  late final TextEditingController _description =
      TextEditingController(text: widget.initialDescription ?? '');
  bool _syncToJellyfin = false;
  bool _canSubmit = false;

  @override
  void initState() {
    super.initState();
    _canSubmit = _name.text.trim().isNotEmpty;
    _name.addListener(_onNameChanged);
  }

  void _onNameChanged() {
    final bool canSubmit = _name.text.trim().isNotEmpty;
    if (canSubmit != _canSubmit) {
      setState(() => _canSubmit = canSubmit);
    }
  }

  @override
  void dispose() {
    _name.removeListener(_onNameChanged);
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  void _submit() {
    final String name = _name.text.trim();
    if (name.isEmpty) return;
    final String description = _description.text.trim();
    Navigator.of(context).pop(
      (
        name: name,
        description: description.isEmpty ? null : description,
        source:
            _syncToJellyfin ? PlaylistSource.jellyfin : PlaylistSource.local,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'My playlist',
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Description (optional)',
            ),
          ),
          if (widget.canSyncToJellyfin) ...<Widget>[
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _syncToJellyfin,
              onChanged: (bool value) =>
                  setState(() => _syncToJellyfin = value),
              title: const Text('Sync with Jellyfin'),
              subtitle: const Text('Create this playlist on your server too.'),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
