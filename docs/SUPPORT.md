# Supporting Linthra

Linthra is **free and open source, and stays that way.** Support is optional and
helps fund development, testing devices, distribution costs, and long-term
maintenance.

> **Packager summary:** the shared/default build contains no billing SDK, ads,
> tracking, or proprietary payment dependency. F-Droid includes the custom
> palette. Google Play Billing belongs in a separate Play-only integration.

## Principles

- **Core features stay free.** Playback, offline listening, Jellyfin, Navidrome,
  Plex, local files, Cast, Android Auto, downloads, backup/restore, and storage
  behaviour never depend on supporter status.
- **Built-in appearance stays free.** Classic, Neon, Gold, and Black & White are
  available to everyone, including their in-app and Android launcher icons.
- **Support is optional.** The app does not become slower, less reliable, or
  less capable when someone does not contribute.
- **The reward is cosmetic only.** A future Play supporter purchase may enable
  a custom two-color palette. It does not change music data or playback.
- **No ads or tracking.** Support does not introduce either.
- **F-Droid remains complete.** The custom palette is included in F-Droid and
  no proprietary billing dependency enters that build.

## In-app support screen

The screen is available at **Settings → About → Support Linthra** and the route
`/settings/support` (`AppRoutes.settingsSupport`). It explains the model and
renders actions supplied by `supportActionsProvider`. The screen does not own
payment logic.

The default F-Droid/dev/GitHub-Release action set contains external links:

| Action | Purpose |
| --- | --- |
| GitHub Sponsors | Optional one-off or monthly support |
| Funding & supporter model | Opens this document |
| View source code | Opens the public repository |

Links are opened only after an explicit tap through the shared
`externalLinkLauncherProvider`. Only HTTP or HTTPS URLs are handed to the
operating system.

## Distribution seam

`SupportDistribution.current` reads:

```text
--dart-define=LINTHRA_DISTRIBUTION=fdroid
--dart-define=LINTHRA_DISTRIBUTION=play
```

The default is `fdroid`. The support-link kill switch remains available:

```text
--dart-define=LINTHRA_SUPPORT_LINKS=off
```

When disabled, the About entry is hidden and the support screen becomes an
informational page with no external actions.

## Cosmetic entitlement

`supporterEntitlementProvider` is the shared, billing-agnostic access seam:

- `included` — the custom palette is available. F-Droid always uses this state.
- `locked` — a Play build previews the custom palette but cannot edit it.
- `unlocked` — verified Play supporter access enables the custom palette.

For internal Play UI testing only:

```text
--dart-define=LINTHRA_DISTRIBUTION=play \
--dart-define=LINTHRA_SUPPORTER_COSMETICS=locked
```

or:

```text
--dart-define=LINTHRA_DISTRIBUTION=play \
--dart-define=LINTHRA_SUPPORTER_COSMETICS=unlocked
```

An empty or unknown value defaults to `included`, preserving current behaviour
until the real billing integration lands.

## Custom palette architecture

The Appearance screen keeps the free icon-theme picker and adds a separate
**Custom color palette** card.

The palette stores three non-secret preferences:

- whether the custom palette is enabled;
- the identity color;
- the playback-accent color.

`CustomThemeController` owns loading, editing, resetting, and persistence.
`customBrandPalette` derives accessible foreground, bright, deep, and container
tones from the two selected colors. `LinthraApp` applies the custom palette only
when it is enabled and the entitlement allows cosmetics.

The editor offers a curated set of colors so every selection remains predictable
and testable. Resetting restores Linthra violet and orange and disables the
custom override.

## Future Play Billing integration

The Play purchase is not implemented in the shared build. A later integration
must:

1. live only in the Play distribution path;
2. keep proprietary billing dependencies out of F-Droid builds;
3. replace the disabled `play-supporter` action with a real one-time purchase;
4. verify and restore the non-consumable purchase;
5. override `supporterEntitlementProvider` with verified state;
6. affect the custom palette only.

Google Play policy can change. Confirm the current rules before shipping,
especially around external donation links and digital purchases. The existing
`LINTHRA_SUPPORT_LINKS` switch allows a Play build to remove external links if
required.

## Tests

Relevant coverage lives in:

- `test/features/support/supporter_entitlement_test.dart`
- `test/features/support/support_actions_provider_test.dart`
- `test/features/support/support_screen_test.dart`
- `test/features/appearance/app_icon_variant_test.dart`
- `test/features/appearance/app_icon_controller_test.dart`
- `test/features/appearance/appearance_settings_screen_test.dart`
- `test/features/appearance/custom_theme_controller_test.dart`

The central contract is enforced throughout: supporter state may change one
optional color palette, but never restricts Linthra's music features or its
built-in icon themes.
