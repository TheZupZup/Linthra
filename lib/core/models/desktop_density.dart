/// How much vertical room desktop rows, grids and controls are given.
///
/// Desktop content density has existed since #384, but as a *fixed* value:
/// `AppTheme` hands Material `VisualDensity.adaptivePlatformDensity`, which
/// resolves to [VisualDensity.compact] on Linux/macOS/Windows and
/// [VisualDensity.standard] on anything touch-first. That is the right default —
/// a mouse hits a smaller row happily and a thumb does not — but it is not a
/// choice, and "fit more of my library on screen" and "stop making me aim" are
/// both reasonable things to want from the same app.
///
/// This enum is that choice, and only that: it selects between two of Material's
/// own [VisualDensity] values rather than introducing a second spacing scale.
/// Every widget that already reads `Theme.of(context).visualDensity` — list
/// rows, the artist grid's tile extent, the alphabet list's row extent, buttons,
/// popup menus — follows it with no change of its own, which is the whole reason
/// the preference is expressed this way.
///
/// Deliberately Flutter-free (like `ThemeModePreference`) so a lightweight
/// key/value store can persist it as one short string. The mapping onto
/// [VisualDensity] lives with the appearance feature that renders it.
///
/// The stored value is a non-secret display preference: no account, server,
/// library, or playback data is involved.
enum DesktopDensity {
  /// The tighter of the two, and what a desktop build has always looked like:
  /// Material's [VisualDensity.compact]. Fits materially more of a library per
  /// screen.
  compact('compact'),

  /// Roomier rows for people who would rather read than scroll: Material's
  /// [VisualDensity.comfortable]. Still denser than the touch layout, so a
  /// desktop window never turns into a stretched phone.
  comfortable('comfortable');

  const DesktopDensity(this.storageId);

  /// The stable string written to storage. Never shown to users, and never
  /// renamed — a stored value must keep resolving across app updates.
  final String storageId;

  /// What an absent, empty, or unrecognised stored value resolves to.
  ///
  /// [compact] on purpose: it is exactly what `adaptivePlatformDensity` already
  /// gave every desktop build, so adding this preference moves nothing for
  /// anyone who never opens it.
  static const DesktopDensity fallback = DesktopDensity.compact;

  /// Resolves a stored [storageId] back to its density, falling back to
  /// [fallback] for anything unrecognised — the same "unknown → default" rule
  /// the theme mode and branding variants use, so a corrupted or downgraded
  /// preference can never leave the app without a density.
  static DesktopDensity fromStorageId(String? storageId) {
    if (storageId == null || storageId.isEmpty) return fallback;
    for (final DesktopDensity density in values) {
      if (density.storageId == storageId) return density;
    }
    return fallback;
  }
}
