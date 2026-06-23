# App icon & branding

Linthra lets you choose how its brand mark looks across the app. The picker
lives under **Settings → Appearance → App icon & branding**.

This is purely cosmetic. Every variant is free and available to everyone in
every build, the choice gates nothing, and it changes nothing about how Linthra
plays, syncs, caches, or stores your music.

## What a "variant" is

Linthra's in-app mark — the rounded equalizer bars under a single vertical
gradient — is drawn in Dart by
[`LinthraLogoMark`](../lib/shared/widgets/linthra_logo_mark.dart), the twin of
the launcher/store icon in [`tool/branding/`](../tool/branding). A *variant* is
just a different **gradient** (top colour first) over a different **bar
pattern**. Because variants are plain data — no images, no extra assets — the
whole catalog is `const`, ships in every build, adds no dependencies, and is
trivially unit-testable.

Every variant keeps the equalizer-bar identity, so Linthra stays recognisable.
The built-in set (see
[`app_icon_variant.dart`](../lib/features/appearance/app_icon_variant.dart)):

| id         | Label             | Look                                   |
| ---------- | ----------------- | -------------------------------------- |
| `classic`  | Classic (default) | Signature violet→orange equalizer      |
| `dark`     | Dark              | Stealthy single-violet                 |
| `neon`     | Neon              | Violet → electric cyan                  |
| `server`   | Self-hosted       | Rising teal→violet signal bars         |
| `waveform` | Waveform          | Symmetric sound wave                   |
| `lonely`   | Lonely maintainer | One bar standing on its own            |
| `gold`     | Gold              | Warm gold (cosmetic supporter preview) |

## Architecture

A small, data-driven feature that mirrors the Support module's per-build seam:

- **Catalog** — `AppIconVariant` / `AppIconVariants` define the variants and a
  pure `byId(String?)` resolver that returns **Classic** for a null, empty, or
  unknown id. This is the single place the "unknown → Classic" rule lives.
- **Storage** — `AppIconVariantStore` persists one non-secret variant id.
  `InMemoryAppIconVariantStore` is the test/default binding;
  `SharedPreferencesAppIconVariantStore` (key `selected_app_icon_variant_v1`)
  is wired in `main`.
- **Controller** — `AppIconController` (a Riverpod `Notifier`) loads the stored
  choice on startup, serves Classic until then, and persists every change.
- **In-app use** — `SelectedLinthraLogoMark` watches the controller and feeds
  the chosen variant into the pure `LinthraLogoMark`, so the About page and the
  Settings header reflect the choice immediately. `LinthraLogoMark` itself stays
  presentational and state-free; its default constructor renders the classic
  mark byte-for-byte as before.

## F-Droid safety

- **No new dependencies, no proprietary SDKs, no billing, no tracking.** The
  feature is pure Dart + the existing `shared_preferences`.
- **Every variant is available in the default/F-Droid build**, including the
  `gold` style. There is no gating field anywhere in the model, so nothing can
  be locked.
- The `AppIconTier.supporter` field is a *data* seam only (see below). It is not
  a gate, and the F-Droid build always offers every tier.

## Cosmetic "supporter" preview (and the future Play-only plan)

`gold` carries `AppIconTier.supporter` and shows a neutral **"Preview"** badge.
In this build — and always in F-Droid — it is fully selectable like any other
variant. The tier exists purely to *prepare* for a future, **Play-only** PR that
may present supporter-tier styles as cosmetic supporter rewards behind the Play
flavor, in the same spirit as the Play supporter purchase reserved in
[`docs/SUPPORT.md`](SUPPORT.md).

If/when that lands, it must:

- live **behind the Play flavor only**, never entering the F-Droid build or the
  default `pubspec.yaml`;
- gate **cosmetics only** — it can never affect playback, offline cache,
  providers, Android Auto, or any core feature; and
- keep the F-Droid build fully functional with every variant available.

The seam for it is already here: filter or mark variants in
`appIconVariantsFor(SupportDistribution)` (the choke point the
`availableAppIconVariantsProvider` reads), exactly as `supportActionsFor()`
adds its Play-only row. The picker screen renders whatever list it is given, so
that change needs no screen edits and no change to the F-Droid build.

## Launcher icon switching — deferred, documented here

This PR customises **in-app** branding only. Switching the actual Android
**launcher** icon is deliberately out of scope because it is invasive and risks
F-Droid reproducibility. Documented here so a future PR has a starting point:

### The `activity-alias` approach

Android can expose several launcher icons for one app by declaring multiple
`<activity-alias>` entries in `AndroidManifest.xml`, each pointing at the main
activity but with its own `android:icon`/`android:roundIcon` and an
`android.intent.category.LAUNCHER` intent filter. Exactly one alias is enabled
at a time; switching is done at runtime with:

```kotlin
packageManager.setComponentEnabledSetting(
    ComponentName(context, "<package>.<AliasName>"),
    PackageManager.COMPONENT_ENABLED_STATE_ENABLED, // or DISABLED for the others
    PackageManager.DONT_KILL_APP,
)
```

driven from Dart over a small platform `MethodChannel`.

### Why it is deferred

- **Multiple pre-rendered icon sets.** Each alias needs its own mipmap set in
  every density, regenerated via `tool/branding/generate_icons.py`. That
  multiplies committed PNGs and the icon-generation surface.
- **Manifest churn + launcher behaviour.** Each variant adds an alias; toggling
  one typically makes the launcher drop and re-add the icon (it can briefly
  disappear or move), which is a jarring UX that needs care.
- **F-Droid reproducibility.** More generated binary assets and manifest entries
  enlarge the reproducible-build surface that
  [`docs/fdroid-reproducibility-arm64.md`](fdroid-reproducibility-arm64.md)
  guards.

Given that, real launcher-icon switching is left to a later, focused PR. The
in-app branding here is intentionally self-contained and does not depend on it.
