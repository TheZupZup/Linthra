import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'source_status.dart';
import 'source_status_providers.dart';

/// The desktop sidebar's source-status strip: one compact indicator per
/// configured self-hosted source, under the navigation destinations.
///
/// It answers the question the rail could not before — *is my music actually
/// going to play?* — without the user opening Settings to find out. A healthy
/// sidebar stays quiet: the glyphs sit in the same muted tone as the rest of
/// the rail's chrome and say nothing louder than "still fine". A source that
/// needs the user turns its own row, and only its own row, to the error colour.
///
/// Renders nothing at all when no self-hosted source is configured, so a
/// local-files-only install never grows a section about servers it doesn't
/// have.
///
/// Costs nothing to draw: every value comes from
/// [configuredSourceStatusesProvider], which is derived from state the app
/// already maintains. No row polls, holds a timer, or issues a request.
class SidebarSourceStatusStrip extends ConsumerWidget {
  const SidebarSourceStatusStrip({
    required this.onOpenConnections,
    super.key,
  });

  /// Opens the existing connection-management surface. Injected rather than
  /// navigated to from here so the strip stays pure presentation — and so a
  /// widget test can assert the routing without standing up a router.
  final VoidCallback onOpenConnections;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<ConfiguredSourceStatus> sources =
        ref.watch(configuredSourceStatusesProvider);
    if (sources.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Divider(indent: 16, endIndent: 16, height: 1),
          const SizedBox(height: 8),
          for (final ConfiguredSourceStatus source in sources)
            SidebarSourceStatusTile(
              key: ValueKey<String>('source-status-${source.sourceId}'),
              source: source,
              onOpenConnections: onOpenConnections,
            ),
        ],
      ),
    );
  }
}

/// One source's indicator: a status glyph over the source's safe name.
///
/// The whole tile is a single button and a single semantics node. Both matter:
/// a screen reader should hear "Jellyfin unavailable" once, as one control, not
/// the name and the state as two separate stops with the glyph announced in
/// between.
///
/// **Security.** Everything drawn or announced comes from
/// [SourceStatusPresentation], whose only variable input is the fixed safe name
/// ("Jellyfin", "Navidrome", "Plex"). A server URL, hostname, username, token
/// or raw exception string has no path to this widget.
class SidebarSourceStatusTile extends StatelessWidget {
  const SidebarSourceStatusTile({
    required this.source,
    required this.onOpenConnections,
    super.key,
  });

  final ConfiguredSourceStatus source;
  final VoidCallback onOpenConnections;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SourceStatusPresentation presentation = source.presentation;
    final Color color = _toneColor(theme, presentation.tone);

    return Semantics(
      container: true,
      button: true,
      // The name and the state are already in `description`; excluding the
      // subtree stops the visible name and the tooltip from saying it twice
      // more.
      excludeSemantics: true,
      label: presentation.description,
      hint: 'Opens connection settings',
      // Excluding the subtree also drops the InkWell's tap *action*, which
      // would leave a screen reader announcing a button it cannot press. The
      // action is re-declared here so the one semantics node carries both the
      // name and the thing it does.
      onTap: onOpenConnections,
      child: Tooltip(
        message: presentation.description,
        child: InkWell(
          onTap: onOpenConnections,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(presentation.icon, size: 18, color: color),
                const SizedBox(height: 2),
                Text(
                  source.name,
                  style: theme.textTheme.labelSmall?.copyWith(color: color),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Tone to theme colour. Healthy and neutral both stay in the rail's muted
  /// chrome tone — a working server is not news — and only [
  /// SourceStatusTone.attention] takes the error colour, so the one row that
  /// needs the user is the only one that draws the eye.
  Color _toneColor(ThemeData theme, SourceStatusTone tone) {
    switch (tone) {
      case SourceStatusTone.healthy:
        return theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.55);
      case SourceStatusTone.neutral:
        return theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75);
      case SourceStatusTone.attention:
        return theme.colorScheme.error;
    }
  }
}
