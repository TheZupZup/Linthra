# Supporting Linthra

Linthra is **free and open source, and stays that way.** Support is optional and
helps fund development, testing devices, distribution costs, and long-term
maintenance.

Core music features are never sold. A future Google Play edition may thank
supporters with optional **cosmetic** rewards such as alternate themes and
launcher icons.

> **Packager summary:** the shared/default build contains no billing SDK, ads,
> tracking, or proprietary payment dependency. F-Droid includes every cosmetic
> style. Google Play Billing belongs in a separate Play-only integration.

## Principles

- **Core features stay free.** Playback, offline listening, Jellyfin, Navidrome,
  Plex, local files, Cast, Android Auto, downloads, backup/restore, and storage
  behaviour never depend on supporter status.
- **Support is optional.** The app does not become slower, less reliable, or
  less capable when someone does not contribute.
- **Cosmetics only.** A Play supporter purchase may unlock alternate branding,
  themes, palettes, or launcher icons. These rewards do not change music data or
  playback behaviour.
- **No ads or tracking.** Support does not introduce either.
- **F-Droid remains complete.** Every cosmetic style is included in F-Droid and
  ordinary development builds.

## In-app support screen

The screen is available at **Settings → About → Support Linthra** and the route
`/settings/support` (`AppRoutes.settingsSupport`).

It explains the model and renders actions supplied by
`supportActionsProvider`. The screen does not own payment logic.

The default F-Droid/dev/GitHub-Release action set contains external links:

| Action | Purpose |
| --- | --- |
| GitHub Sponsors | Optional one-off or monthly support |
| Funding & supporter model | Opens this document |
| View source code | Opens the public repository |

Links are opened only after an explicit tap through the shared
`externalLinkLauncherProvider`. Only well-formed HTTP or HTTPS URLs are handed
to the operating system.

## Distribution seam

`SupportDistribution.current` reads:

```text
--dart-define=LINTHRA_DISTRIBUTION=fdroid
--dart-define=LINTHRA_DISTRIBUTION=play
```

The default is `fdroid`. `supportDistributionProvider` exposes the result to
feature modules and tests through one overridable Riverpod seam.

The support-link kill switch remains available:

```text
--dart-define=LINTHRA_SUPPORT_LINKS=off
```

When disabled, the About entry is hidden and the support screen becomes an
informational page with no external actions.

## Cosmetic supporter entitlement

`supporterEntitlementProvider` is the shared, billing-agnostic access seam. It
has three states:

- `included` — every cosmetic style is available; this is always used by
  F-Droid and is the default while Play Billing is not wired.
- `locked` — free styles remain selectable while supporter styles are previews.
- `unlocked` — verified supporter access allows every style.

For internal Play UI testing only, the temporary build define is:

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

The future Play-only billing implementation should override
`supporterEntitlementProvider` with verified purchase state. The Appearance
feature must never import a billing SDK directly.

## Appearance rewards

The branding catalog currently has two always-free styles and two supporter
styles:

| Style | Tier |
| --- | --- |
| Classic | Free |
| Neon | Free |
| Gold | Supporter cosmetic |
| Black & White | Supporter cosmetic |

Every distribution displays the complete catalog so the visual options are
discoverable. `appIconAccessProvider` decides whether a style can be selected.

When access is locked:

- Classic and Neon remain selectable.
- Gold and Black & White remain visible as previews.
- tapping a supporter style opens a short explanation and a link to the Support
  Linthra screen.
- a previously stored supporter style safely falls back to Classic.

F-Droid always resolves supporter access to `included`, so no F-Droid user sees
a locked cosmetic.

## Future Play Billing integration

The Play purchase is not implemented in the shared build. The later integration
must:

1. live only in the Play distribution path;
2. keep proprietary billing dependencies out of F-Droid builds;
3. replace the disabled `play-supporter` action with a real purchase action;
4. verify and restore the non-consumable purchase;
5. override `supporterEntitlementProvider` with verified state;
6. affect cosmetics only.

Google Play policy can change. Confirm the current rules before shipping,
especially around external donation links and digital purchases. The existing
`LINTHRA_SUPPORT_LINKS` switch allows a Play build to remove external links if
required.

## Tests

The relevant coverage lives in:

- `test/features/support/supporter_entitlement_test.dart`
- `test/features/support/support_actions_provider_test.dart`
- `test/features/support/support_screen_test.dart`
- `test/features/appearance/app_icon_variant_test.dart`
- `test/features/appearance/app_icon_controller_test.dart`
- `test/features/appearance/appearance_settings_screen_test.dart`

The tests enforce the central contract: supporter state may change appearance,
but never restricts Linthra's music features.
