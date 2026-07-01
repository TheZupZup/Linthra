import 'package:flutter/material.dart';

import '../../../core/models/playlist.dart';

/// The result of the create/rename playlist dialog.
typedef PlaylistEdit = ({
  String name,
  String? description,
  PlaylistSource source,
});

/// A server the new playlist can be synced to (a connected remote provider).
typedef PlaylistSyncTarget = ({PlaylistSource source, String label});

/// Shows the create-playlist dialog and resolves to the entered name (+ optional
/// description and chosen [PlaylistSource]), or `null` if cancelled or the name
/// was blank.
///
/// [syncTargets] are the servers the new playlist can mirror to (one per
/// connected remote provider). With none it is local-only; with any, the dialog
/// offers a "sync to" choice defaulting to on-device.
Future<PlaylistEdit?> showCreatePlaylistDialog(
  BuildContext context, {
  List<PlaylistSyncTarget> syncTargets = const <PlaylistSyncTarget>[],
}) {
  return showDialog<PlaylistEdit>(
    context: context,
    builder: (BuildContext context) => _PlaylistEditDialog(
      title: 'New playlist',
      confirmLabel: 'Create',
      syncTargets: syncTargets,
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
    this.syncTargets = const <PlaylistSyncTarget>[],
  });

  final String title;
  final String confirmLabel;
  final String? initialName;
  final String? initialDescription;
  final List<PlaylistSyncTarget> syncTargets;

  @override
  State<_PlaylistEditDialog> createState() => _PlaylistEditDialogState();
}

class _PlaylistEditDialogState extends State<_PlaylistEditDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initialName ?? '');
  late final TextEditingController _description =
      TextEditingController(text: widget.initialDescription ?? '');

  /// The chosen destination: [PlaylistSource.local] (default) or a connected
  /// remote provider's source.
  PlaylistSource _target = PlaylistSource.local;
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
        source: _target,
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
          ..._syncTargetControls(),
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

  /// The "sync to server" controls: nothing for a local-only setup, a single
  /// switch when one server is connected, or an on-device + per-server radio
  /// group when more than one is.
  List<Widget> _syncTargetControls() {
    final List<PlaylistSyncTarget> targets = widget.syncTargets;
    if (targets.isEmpty) return const <Widget>[];

    if (targets.length == 1) {
      final PlaylistSyncTarget target = targets.first;
      return <Widget>[
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _target == target.source,
          onChanged: (bool value) => setState(
            () => _target = value ? target.source : PlaylistSource.local,
          ),
          title: Text('Sync with ${target.label}'),
          subtitle: const Text('Create this playlist on your server too.'),
        ),
      ];
    }

    return <Widget>[
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'Sync to',
          style: Theme.of(context).textTheme.labelLarge,
        ),
      ),
      RadioListTile<PlaylistSource>(
        contentPadding: EdgeInsets.zero,
        value: PlaylistSource.local,
        groupValue: _target,
        onChanged: (PlaylistSource? value) =>
            setState(() => _target = value ?? PlaylistSource.local),
        title: const Text('On this device only'),
      ),
      for (final PlaylistSyncTarget target in targets)
        RadioListTile<PlaylistSource>(
          contentPadding: EdgeInsets.zero,
          value: target.source,
          groupValue: _target,
          onChanged: (PlaylistSource? value) =>
              setState(() => _target = value ?? PlaylistSource.local),
          title: Text(target.label),
        ),
    ];
  }
}
