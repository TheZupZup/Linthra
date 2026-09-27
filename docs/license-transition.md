# License transition: MPL-2.0 to AGPL-3.0-or-later

## Status

**Completed.** Linthra's current license is **AGPL-3.0-or-later**.

| | |
| --- | --- |
| Previous license | MPL-2.0 (through release **v0.2.4**) |
| Current license | **AGPL-3.0-or-later** |
| Active license text | [`LICENSE`](../LICENSE) — unmodified GNU AGPLv3 |
| Preserved historical text | [`licenses/MPL-2.0.txt`](./licenses/MPL-2.0.txt) |
| Public consent record | [issue #503](https://github.com/TheZupZup/Linthra/issues/503) |

### The three things this transition does and does not do

1. **Old releases keep their old terms.** Every Linthra release and source tag
   published before the relicensing commit — up to and including **v0.2.4** —
   was published under MPL-2.0 and **remains under MPL-2.0**. Relicensing going
   forward cannot retroactively change the terms a user already received. The
   MPL-2.0 text is preserved verbatim at
   [`licenses/MPL-2.0.txt`](./licenses/MPL-2.0.txt) so those rights stay
   exercisable.
2. **The current and future project is AGPL-3.0-or-later.** The top-level
   `LICENSE` is the unmodified GNU AGPLv3, and new contributions are accepted
   under AGPL-3.0-or-later (see [`../CONTRIBUTING.md`](../CONTRIBUTING.md)).
3. **Contributor consent was additive, not a revocation.** Each contributor
   granted permission for their work to **also** be distributed under
   AGPL-3.0-or-later, *in addition to, and without withdrawing*, the MPL-2.0
   terms under which it was originally contributed. Nobody transferred
   copyright, and the original MPL-2.0 grant on their past contributions still
   stands.

**Third-party code is not covered.** Vendored code under `third_party/` keeps
its own upstream license, and third-party license and notice files are preserved
unchanged. See
[`dependency-license-audit.md` §5.3](./dependency-license-audit.md).

## Relicensing record

- **Decision and rationale:** [#501](https://github.com/TheZupZup/Linthra/issues/501)
  (documentation of the proposal) and
  [#503](https://github.com/TheZupZup/Linthra/issues/503) (the transition issue).
- **Public contributor-consent record:**
  [#503](https://github.com/TheZupZup/Linthra/issues/503). Consent statements
  were posted by each contributor from their own GitHub account.
- **Maintainer approval:** TheZupZup (project owner), recorded in #503.
- **Contributor consents received** (all covering past *and* future
  contributions, additive to MPL-2.0):
  [@jpdexter101-lang](https://github.com/TheZupZup/Linthra/issues/503#issuecomment-5391082191),
  [@Borhan2004](https://github.com/TheZupZup/Linthra/issues/503#issuecomment-5391430734),
  [@Jeevika1917](https://github.com/TheZupZup/Linthra/issues/503#issuecomment-5452329340).
- **Copyright-holder audit:** recorded in
  [#503](https://github.com/TheZupZup/Linthra/issues/503#issuecomment-5452617401).
  No additional non-owner human copyright holder with code still shipping was
  identified; automation-only commits (CI, Dependabot) add no human copyright
  holder to solicit.
- **Dependency/build compatibility audit:** refreshed in
  [`dependency-license-audit.md`](./dependency-license-audit.md) against the
  committed `pubspec.lock` and the committed Flatpak source pins. No
  `GPL-2.0-only`, non-free, or unknown-license component was found in the
  declared build path.
- **Per-file headers:** none. No source file carried an MPL-2.0 header, so the
  transition required no per-file header rewrite.

## Why move to AGPL-3.0-or-later

Linthra is meant to stay open source when other projects build directly on it.
MPL-2.0 uses file-level copyleft, which intentionally allows MPL files to be combined
with separately licensed proprietary files. That flexibility is useful for many
projects, but it was weaker than the policy Linthra wants for downstream derivatives.

AGPL-3.0-or-later was chosen because it provides strong copyleft for covered
derivative works and also contains the network-interaction source offer that
distinguishes AGPL from GPL.

The goal is not to prevent forks. Forking, modifying, studying, and redistributing the
software should remain possible. The goal is that a project which actually builds on
Linthra should not be able to take the shared work, turn the resulting covered work into
a closed product, and keep the corresponding source unavailable to its users.

## What this does not solve by itself

A stronger software license does **not** make third-party binaries trustworthy.
Someone can still publish a modified build, and an open-source license cannot guarantee
that the modification is safe or malware-free.

That is why the license transition is paired with [`TRADEMARKS.md`](../TRADEMARKS.md):
modified builds must not be presented as official Linthra releases. Signed official
builds and clear distribution channels remain the practical way for users to distinguish
what the Linthra project actually shipped from third-party modifications.

Likewise, neither AGPL nor the branding policy is a promise that legal claims can never
be made against a maintainer. They are intended to make ownership, source obligations,
origin, warranty boundaries, and responsibility for third-party modifications clearer.

## Why consent was required before relabelling

Linthra has accepted contributions from copyright holders other than the repository
owner, and the contribution terms at the time said contributions were licensed under
MPL-2.0.

MPL 2.0 has compatibility rules for combining MPL-covered code with GPL-family code,
but Mozilla's own guidance explicitly distinguishes that mechanism from simply deciding
to relicense an existing MPL project as GPL/AGPL-only. A clean project-wide transition
therefore needed the relevant copyright permissions rather than silently replacing the
license on somebody else's contribution.

That is why the switch was gated on the explicit, additive consent recorded in
[#503](https://github.com/TheZupZup/Linthra/issues/503) and on a repository-history
audit for any other human copyright holder whose work still ships. Both completed
before this change; silence was never treated as consent.

References:

- MPL 2.0 FAQ: https://www.mozilla.org/en-US/MPL/2.0/FAQ/
- Mozilla's MPL/(L)GPL combination guidance:
  https://www.mozilla.org/en-US/MPL/2.0/combining-mpl-and-gpl/
- GNU AGPL v3: https://www.gnu.org/licenses/agpl-3.0.html

## What the switch actually changed

The transition was made in one reviewable change. The surfaces updated:

**License texts**

- `LICENSE` — replaced with the unmodified GNU AGPLv3 text.
- `docs/licenses/MPL-2.0.txt` — the previous `LICENSE`, preserved byte-for-byte
  (SHA-256 `3f3d9e0024b1921b067d6f7f88deb4a60cbe7a78e76c64e3f1d7fc3b779b9d04`).
- `docs/licenses/README.md` — explains the historical/current split.

**Project metadata and code**

- `README.md` — badge and License section.
- `CONTRIBUTING.md` — new contributions accepted under AGPL-3.0-or-later.
- `native/linthra_core/Cargo.toml` — `license = "AGPL-3.0-or-later"`.
- `lib/features/settings/hub/about_screen.dart` and
  `test/features/settings/hub/about_screen_test.dart` — the in-app License row.
- `fastlane/metadata/android/en-US/full_description.txt` — the user-facing store text.
- `metadata/io.github.thezupzup.linthra.yml` — `License: AGPL-3.0-or-later`
  since the v0.2.5 release update, which advanced `CurrentVersion` to the first
  release cut from a post-transition source commit. Its `Builds` entries still
  name the pre-transition versions F-Droid actually built and are not
  relabelled.

**Documentation**

- `docs/fdroid-build-recipe.md`, `docs/fdroid-readiness.md`, `docs/fdroid-submission.md`
- `docs/play-store-listing.md`, `docs/play-store-readiness.md`
- `docs/privacy-policy.md`, `docs/index.html`, `docs/privacy.html`
- `docs/dependency-license-audit.md` — refreshed against the current inventory
- `docs/license-transition.md` (this file), `docs/relicensing-consent.md`

**Deliberately left stating MPL-2.0**

- `docs/release-notes/*` — these correctly describe releases actually published
  under MPL-2.0. Only their *links* were repointed from the top-level `LICENSE`
  (now AGPL) to the preserved `docs/licenses/MPL-2.0.txt`, so the stated fact and
  the text it links to agree.
- `third_party/**` — third-party licenses and notices, untouched.
- Historical and compatibility discussion of MPL-2.0 in this file and in
  `docs/dependency-license-audit.md`.

A repository-wide search for `MPL-2.0`, `MPL 2.0` and `Mozilla Public License`
was re-run after the change, and every remaining occurrence was classified as
one of the intentional categories above.

## Dependency license compatibility

AGPL-3.0-or-later is a stronger copyleft than MPL-2.0, and compatibility with it is
one-way for several common licenses. The audit was re-run against the current
inventory before the switch and is recorded in
[`dependency-license-audit.md`](./dependency-license-audit.md).

Outcome, in brief:

- The Dart/Flutter set (160 committed lockfile entries) is permissive throughout
  except one MPL-2.0 package, `dbus`, which is **not** marked "Incompatible With
  Secondary Licenses" and is therefore combinable under MPL-2.0 §3.3 — the clause
  that names the AGPLv3 as a Secondary License.
- The Linux/Flatpak media chain is **LGPL-2.1-or-later** at its most restrictive:
  FFmpeg `n9.0.1` built with neither `--enable-gpl` nor `--enable-nonfree`, and
  mpv `v0.41.0` built with `-Dgpl=false` **and** every GPL-only component
  (`cdda`, `dvdnav`, `dvbin`, `rubberband`, …) explicitly disabled, which is what
  makes that switch mean what it says. libplacebo is LGPL-2.1-or-later; libass is
  ISC.
- **No `GPL-2.0-only`, non-free, or unknown-license component** was found in the
  declared build path.

The rules that governed the check, and still govern future dependency bumps:

- `GPL-2.0-only` dependencies are **not** compatible with AGPL-3.0-or-later;
- `LGPL-2.1-only` needs care, whereas `LGPL-2.1-or-later` can be used via its upgrade
  path to LGPLv3;
- the libmpv/FFmpeg chain's licensing depends on how it is *configured*, so it must be
  re-confirmed whenever those pins move — not assumed from the previous build.

## F-Droid

AGPL-3.0-or-later is a free-software license suitable for F-Droid metadata. The license
change does not require changing Linthra's application ID or signing model.

The important migration detail is version history: old Linthra source tags and old
F-Droid builds remain MPL-2.0. While every `Builds` entry and the `CurrentVersion`
still pointed at pre-transition source commits, the checked-in F-Droid metadata stayed
at `License: MPL-2.0`, because changing only the global `License:` field would have
misdescribed those historical builds.

The first release cut from a post-transition source commit is the cutover point, and
that release update must change the F-Droid `License:` field to `AGPL-3.0-or-later`
**in the same change that adds/advances the first AGPL build/current version**.

**That cutover happened in the v0.2.5 release update**, which advanced `CurrentVersion`
to `0.2.5` and set `License: AGPL-3.0-or-later` in the same change. The `Builds` entries
were left alone: they record the versions F-Droid actually built, all of them
pre-transition, and no old build commit, tag, release note, or artifact is relabelled.

Do not retroactively edit old release notes to say AGPL when those releases shipped
under MPL.

### The external `fdroiddata` entry

The canonical F-Droid recipe lives in the external
[`fdroiddata`](https://gitlab.com/fdroid/fdroiddata/-/blob/master/metadata/io.github.thezupzup.linthra.yml)
repository, not here. F-Droid's checkupdates bot has already added the v0.2.5,
v0.2.6 and v0.2.7 builds there and advanced `CurrentVersion`, but the bot never
touches `License:`, so that entry still says `License: MPL-2.0`. That is wrong
for every current F-Droid build and needs a one-line manual merge request:

```diff
-License: MPL-2.0
+License: AGPL-3.0-or-later
```

Nothing else in the recipe changes: no `Builds` entry, commit or tag is
edited. The ready-to-file merge request is in
[fdroid-submission.md](./fdroid-submission.md) §11, and the sync is tracked in
[#659](https://github.com/TheZupZup/Linthra/issues/659).

F-Droid's `License:` is a single app-level field with no per-build value (see
F-Droid's Build Metadata Reference), so once it is corrected the F-Droid client
will show AGPL-3.0-or-later next to any archived v0.2.4-or-older APK as well.
That is a limit of the metadata format, not a relicensing of those builds: they
remain MPL-2.0, and this file and [`licenses/`](./licenses/README.md) are the
authoritative record.

Third-party listings that copied an older release (for example a page still
describing v0.2.4 as MPL-2.0) are stale, not wrong. The fix there is to refresh
them to a current release, never to relabel the old version as AGPL.

## Branding and unofficial builds

The software license and project identity are deliberately separate.

AGPL controls the terms under which covered source and derivative works are distributed.
[`TRADEMARKS.md`](../TRADEMARKS.md) controls whether a third-party build may present
itself using Linthra's official identity.

For a downstream build that materially changes Linthra's behaviour or user-facing
identity, the expected rule is simple: keep the source open as required by the applicable
software license, and use a distinct name/branding so users do not mistake that build for
one reviewed and published by the Linthra project.

Independent distributions that build Linthra from source without materially changing it —
F-Droid, Flathub, and Linux distribution packaging — are explicitly not asked to rebrand.
See [`TRADEMARKS.md`](../TRADEMARKS.md) for the packaging carve-out.
