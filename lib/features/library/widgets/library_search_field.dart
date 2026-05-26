import 'package:flutter/material.dart';

import '../../../app/dimens.dart';

/// The Library search box. A thin, themed wrapper over [TextField] that filters
/// the active tab as the user types and offers a clear button once there's text.
///
/// It owns no state — the host screen holds the query and the controller — so a
/// tab switch can clear it from the outside. It only ever reports plain typed
/// text upward; it never reads or renders a URL or token.
class LibrarySearchField extends StatelessWidget {
  const LibrarySearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
    super.key,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final bool hasText = controller.text.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      child: TextField(
        key: const Key('library_search_field'),
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search songs, albums, artists',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: hasText
              ? IconButton(
                  key: const Key('library_search_clear'),
                  icon: const Icon(Icons.close),
                  tooltip: 'Clear search',
                  onPressed: onClear,
                )
              : null,
        ),
      ),
    );
  }
}
