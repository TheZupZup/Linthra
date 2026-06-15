import 'package:flutter/material.dart';

import '../../../app/dimens.dart';

/// The shared frame for a Settings category page (the screen a hub row opens).
///
/// It is a thin host — an [AppBar] with the category [title] and a scrolling
/// body — so every category page looks and scrolls the same and the page files
/// stay a plain list of the *existing* setting cards. The cards themselves are
/// unchanged; only where they are shown moves here.
class SettingsDetailScaffold extends StatelessWidget {
  const SettingsDetailScaffold({
    super.key,
    required this.title,
    required this.children,
  });

  /// The category name shown in the app bar.
  final String title;

  /// The setting cards/sections to stack on the page, top to bottom.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: children,
      ),
    );
  }
}
