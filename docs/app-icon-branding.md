# App icon & branding

Linthra lets you choose how its brand mark looks — across the app and, on
Android, as the real **launcher icon** on your home screen and app drawer.
Selecting a variant also retints the app's **accent colours** (and, for the
black-and-white variant, its brand colour), so the picker is a complete visual
theme selector rather than only a launcher-icon picker. The picker lives under
**Settings → Appearance → App icon & branding**.

This is purely cosmetic. Every variant is free and available to everyone in
every build, the choice gates nothing, and it changes nothing about how Linthra
plays, syncs, caches, or stores your music. (Some launchers take a few seconds —
or a manual refresh — to show a newly chosen icon; that's the launcher's caching,
not a failure.)

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

| id         | Label             | Look                              |
| ---------- | ----------------- | --------------------------------- |
| `classic`  | Classic (default) | Signature violet→orange equalizer |
| `dark`     | Dark              | Black + purple (no orange)        |
| `neon`     | Neon              | Purple + neon cyan/blue           |
| `gold`     | Gold              | Black & gold                      |
| `blackwhite` | TheZupZup Black & White | Strictly black and white (no gray) |

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
- **Accent themes** — `BrandPalettes` (`lib/app/brand_theme.dart`) maps each
  variant id to a `BrandPalette` (primary/accent tones) with the same
  "unknown → Classic" fallback. `AppTheme.dark`/`light` take a palette and thread
  it through the whole `ThemeData`; `LinthraApp` watches the controller and
  rebuilds the theme on every change, so the chosen accent restores on restart
  for free. The two accent tones Material's `ColorScheme` has no slot for (the
  play button's gradient ends) ride on a `LinthraAccents` `ThemeExtension`.
  The roles are **black-first**: dark surfaces carry the UI; the **identity**
  colour (`primary`/`primaryBright`) carries brand, text buttons, input focus,
  and selected/active states (selected navigation and rows); the **accent**
  carries energy — primary call-to-action buttons, progress, sliders, and the
  play button. For Classic that reads "black UI, purple identity, orange energy."
  Dark and Neon keep Linthra's violet identity and only swap the accent; Gold is
  black-and-gold and Black & White pure black/white, so both also retint the
  identity. Classic's palette *values* are still exactly today's `AppColors` —
  only the role mapping changed. Error / destructive colours are never themed.
- **Launcher icon (Android)** — the same selection also switches the real
  launcher icon via `LauncherIconService`. The controller calls it best-effort on
  every change *and* re-asserts it on startup, so the home-screen icon survives a
  restart. It is Android-only and degrades to a safe no-op everywhere else (see
  "Launcher icon switching" below).

## F-Droid safety

- **No new dependencies, no proprietary SDKs, no billing, no tracking.** The
  feature is pure Dart + the existing `shared_preferences`.
- **Every variant is available in the default/F-Droid build**, including the
  `gold` style. There is no gating field anywhere in the model, so nothing can
  be locked.
- The `AppIconTier.supporter` field is a *data* seam only (see below). It is not
  a gate, and the F-Droid build always offers every tier.

## Cosmetic "supporter" preview seam (and the future Play-only plan)

No built-in variant uses `AppIconTier.supporter` today — every variant is `free`
and shows no badge. The tier exists purely as a *data seam* to prepare for a
future, **Play-only** PR that may present supporter-tier styles as cosmetic
supporter rewards behind the Play flavor, in the same spirit as the Play
supporter purchase reserved in [`docs/SUPPORT.md`](SUPPORT.md). When a variant is
marked `supporter`, the picker shows it with a neutral **"Preview"** badge — never
a lock or a price.

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

## Launcher icon switching (Android)

Choosing a variant also switches the **real** Android launcher icon, using
`<activity-alias>` entries toggled at runtime. It is Android-only and
best-effort: off Android, or if the platform call fails, the in-app mark still
changes and nothing throws.

### How it works

- **One alias per variant.** `AndroidManifest.xml` declares an `<activity-alias>`
  for every variant (`.IconClassic`, `.IconDark`, `.IconNeon`, `.IconGold`,
  `.IconBlackWhite`), each with its own `android:icon`
  and a `MAIN`/`LAUNCHER` intent filter, all `targetActivity=".MainActivity"`.
  `.MainActivity` no longer carries the launcher intent filter itself — it is the
  shared target. `.IconClassic` ships `android:enabled="true"` and reuses the
  existing `@mipmap/ic_launcher`; the rest ship disabled. Exactly one alias is
  ever enabled.
- **Switching.** `LauncherIconChannel.kt` enables the chosen alias and disables
  the others with
  `PackageManager.setComponentEnabledSetting(..., DONT_KILL_APP)`, so the running
  process — playback, the audio foreground service and its notification, and the
  Android Auto session — is **never killed**. It enables the target *before*
  disabling the rest (so there is never a moment with zero enabled launchers) and
  only writes components whose effective state actually changes (so re-asserting
  the current icon is a no-op that triggers no launcher refresh).
- **Dart side.** `LauncherIconAliases` (pure data) maps each variant id to its
  alias name — the single contract shared with the manifest and the Kotlin
  `ALIASES` list. `LauncherIconService` has an Android method-channel
  implementation, a no-op for other platforms/tests, and a platform-selecting
  wrapper (`PlatformLauncherIconService`), mirroring `PlatformFolderPickerService`.
  `AppIconController` calls it on every selection *and* re-asserts it on startup
  from the persisted choice, so the icon survives a restart.

### Why every alias targets one activity

Because all aliases point at the same `.MainActivity`, the launched activity, the
`audio_service` media session, Android Auto (`MediaBrowserService`), the media
notification, the media-button receiver, the artwork `FileProvider`, and deep
links behave **identically** no matter which icon is active — only the
home-screen / app-drawer icon changes. There are no custom deep-link filters on
`MainActivity`, so moving `MAIN`/`LAUNCHER` onto the aliases affects nothing else.

### Icon assets

`tool/branding/generate_icons.py` is the single source of truth. Alongside the
classic assets (unchanged), it renders, for each variant `<id>`:

- `mipmap-<density>/ic_launcher_<id>.png` — legacy launcher tile,
- `mipmap-<density>/ic_launcher_<id>_foreground.png` — adaptive foreground,
- `mipmap-anydpi-v26/ic_launcher_<id>.xml` — adaptive icon reusing the shared
  `@drawable/ic_launcher_background` (except the neutral ZupZup variants below).

> **Black & White background.** Most variants render their bars on the shared
> violet squircle. The strictly black-and-white variant overrides it so the icon
> stays pure black & white: a flat pure-black background
> (`@drawable/ic_launcher_background_bw`) with pure-white, gradient-free bars.
> `VARIANT_BACKGROUNDS` in the generator plus that hand-authored drawable are the
> only place this is configured.

> **Every variant must match the default Classic launcher icon's visual size.**
> A launcher icon is judged next to the rest of the home screen, so a variant
> that is even slightly larger, lower, or visually heavier than the default looks
> wrong. The generator therefore draws every variant in the **same optical
> footprint as Classic** — the same padding/inset, the same baseline, and the
> same bounding box — and only the colours and the relative bar pattern change.

Concretely, the variant path (`_variant_bars`) reuses the **classic** bar
geometry rather than the in-app `LinthraLogoMark` geometry:

- The bar group spans `VARIANT_GROUP_FOOTPRINT` (= the classic four-bar group
  width, `4·0.13 + 3·0.10 = 0.82` of the layout region) at the classic
  gap-to-bar ratio (`0.10/0.13`). A 4-bar variant therefore reproduces Classic's
  bar width exactly; a variant with more bars fits the **same** footprint with
  proportionally thinner bars, so it never grows wider or heavier.
- Bars are bottom-aligned to the classic baseline (`0.80` of the region) and
  their heights are **normalised so each variant's tallest bar equals Classic's
  tallest** — giving every variant Classic's exact vertical extent while keeping
  its own relative bar pattern.
- The mark is laid out in the same regions Classic uses — the squircle tile for
  the legacy icon and the central `0.62` adaptive **safe zone** for the
  foreground — so the bars stay inside the adaptive mask and never touch its
  edges, exactly like the default.

The net effect: for the legacy tile and the adaptive foreground alike, every
variant's rendered bar bounding box is identical to Classic's (verified by
decoding the generated PNGs). Note this is a deliberate trade-off — the launcher
variants are sized to match the **Classic launcher icon**, not the in-app
`LinthraLogoMark` picker tile, because on the home screen they sit next to the
default, not next to the picker. The `VARIANTS` table in the script mirrors
`app_icon_variant.dart` (id, gradient, bar pattern); keep them in step.
Regenerate with:

```
python3 tool/branding/generate_icons.py
```

After regenerating, the classic `ic_launcher.*` and store assets stay
byte-for-byte identical (verify with `sha256sum`); only the
`ic_launcher_<id>.*` variant assets change.

### F-Droid reproducibility

The added assets are PNGs written deterministically by the stdlib-only generator
(no Pillow, no timestamps, no randomness) and compile into `resources.arsc`,
which F-Droid's reproducible build already produces byte-identically; the classic
`ic_launcher.*` outputs are unchanged. The new `<activity-alias>` entries add
manifest lines but no new class of nondeterminism — the per-ABI manifest
line-number divergence tracked in
[`docs/fdroid-reproducibility-arm64.md`](fdroid-reproducibility-arm64.md) is
structural and pre-existing. Always regenerate icons with the tool (never edit
the PNGs by hand) so determinism holds. No new dependencies, billing, tracking,
or feature gating are introduced.

## Manual QA checklist (Android)

Run on a real device/emulator after changing launcher icons:

- [ ] Fresh install shows the default **Classic** launcher icon.
- [ ] Selecting **each** variant updates the home-screen / app-drawer icon (allow
      a few seconds or a launcher refresh).
- [ ] **Size check:** each variant's icon matches **Classic's** visual size on
      the home screen — none looks oversized, cropped, stretched, lower, or
      visually heavier than the default. (The mark stays inside the adaptive mask
      and never touches its edges.)
- [ ] The app still **opens from the launcher** after each switch.
- [ ] The app still appears and browses correctly in **Android Auto**.
- [ ] **Notification / media controls** keep working *during and after* a switch —
      playback is not interrupted (`DONT_KILL_APP`).
- [ ] The app **survives a restart** with the selected icon (cold kill + relaunch).
- [ ] **Switching back to Classic** works.
- [ ] Non-Android (desktop) ignores the feature: the in-app mark still changes and
      there are no errors.

### Accent theme

- [ ] Selecting each variant retints the theme: CTA buttons, progress, sliders,
      and the play button take the accent; selected navigation/rows take the
      identity colour.
- [ ] **Classic** reads **black-first**: dark surfaces, purple identity (text
      buttons, selected nav/rows, input focus, borders), orange for CTAs /
      progress / the play button — *not* a purple app.
- [ ] **Dark** is black + purple; **Neon** is purple + neon cyan/blue; **Gold**
      reads black-and-gold; **Black & White** uses pure black/white (no gray).
- [ ] CTA buttons are orange (Classic) — there's no large purple button slab.
- [ ] Selected navigation labels/icons are a **readable** purple (not dim or
      invisible); no black text on dark surfaces.
- [ ] The selected theme **survives a restart** (restored from the persisted
      variant).
- [ ] Text/glyphs on accent fills stay readable in dark mode.
- [ ] No provider / sync / playback behaviour changes — branding is cosmetic only.
