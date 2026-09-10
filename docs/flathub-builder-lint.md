# Flathub builder lint

Issue: [#449](https://github.com/TheZupZup/Linthra/issues/449)
Parent: #376

CI has validated Linthra's desktop entry and metainfo for a while, with
`desktop-file-validate` and `appstreamcli validate`. Those answer a different
question: whether two files are well-formed.

Flathub's own linter answers the one that matters for a submission — whether it
would be *accepted*. It checks whether the sources are reproducible, whether the
permissions are ones Flathub grants, whether the metainfo carries what a
software centre needs to show the app at all, and a long list of listing-quality
rules that no XML validator knows about.

## The exact commands

The linter ships inside the `org.flatpak.Builder` Flatpak, which is how
Flathub's own documentation runs it — the same tool a reviewer uses.

```sh
flatpak install -y flathub org.flatpak.Builder

# The manifest, before anything is built.
flatpak run --command=flatpak-builder-lint org.flatpak.Builder \
  manifest flatpak/io.github.thezupzup.linthra.yml

# The exported repository — what Flathub would publish.
flatpak run --command=flatpak-builder-lint org.flatpak.Builder \
  repo flatpak/repo-ci

# The AppStream catalogue appstreamcli compose produced during the build. This
# is what a software centre actually reads, and is not the file
# `appstreamcli validate` checked.
flatpak run --command=flatpak-builder-lint org.flatpak.Builder \
  appstream flatpak/flatpak-builder-ci/files/share/app-info/xmls/io.github.thezupzup.linthra.xml.gz
```

Two of the three need a completed build, so the practical way to run all of
them is the sequence in [flatpak-ci.md](./flatpak-ci.md) followed by:

```sh
python3 scripts/flathub_builder_lint.py \
  --manifest flatpak/io.github.thezupzup.linthra.yml
python3 scripts/flathub_builder_lint.py \
  --repo flatpak/repo-ci \
  --builddir flatpak/flatpak-builder-ci
```

`scripts/flathub_builder_lint.py` runs exactly the commands above. It exists for
what it refuses to call a pass, not to wrap them.

## What the runner refuses

**A missing linter is not a pass.** If `flatpak` or `org.flatpak.Builder` is
absent, the script exits 2 and says nothing was linted. A check that silently
succeeds when its tool is missing is worse than no check, because it is
reported as evidence.

Silence is read carefully, in both directions. flatpak-builder-lint 3.x prints
*nothing at all* when a mode finds nothing, and exits 0 — that is a clean
report, and it cannot be confused with a missing tool because the linter's
presence is established before any mode runs. Silence with a **non-zero** exit
explains nothing and is still refused.

**A finding needs a written reason.** Any error or warning that is not listed
in `flatpak/flathub-lint-exceptions.json` fails the run. Warnings count:
reviewers read them, and #449 is about reaching a submission-quality result
rather than an exit code.

**A reason cannot outlive its problem.** An exception the linter no longer
reports also fails the run, so the file cannot quietly accumulate justifications
for things that were fixed years ago.

**An exception with no reason is rejected outright** — an empty string there is
a suppression wearing a different hat.

## Tool and version assumptions

- The linter's rules change with the tool, so "clean" is only meaningful next to
  the version that said so. The runner prints `flatpak --version`, the
  `org.flatpak.Builder` ref and commit, and the linter's own version before any
  result.
- `org.flatpak.Builder` is deliberately **not pinned**. Flathub reviews
  submissions with whatever is current, so pinning would make this check green
  against a linter nobody uses. The cost is that a new linter release can turn
  the build red for a reason the PR did not cause; the version line in the log
  is what makes that obvious, and the fix is to fix the finding.
- The `repo` and `appstream` modes need a completed `flatpak-builder` run. Only
  `manifest` is cheap.

## Exceptions

`flatpak/flathub-lint-exceptions.json` is **empty**, and that is the state
[#456](https://github.com/TheZupZup/Linthra/issues/456) requires before
submission.

An entry there is not a way to make the check green. It is a claim that a person
looked at a finding and decided the linter is wrong or the problem is
unavoidable for Linthra, and the reason has to say which. A finding that is
simply *not fixed yet* belongs in its issue, not here.

## Known blockers this cannot resolve on its own

Two findings are expected and are somebody else's issue to close:

- **The manifest CI lints is the development manifest.** It builds the working
  checkout (`type: dir`, `path: ..`), which is right for a build that has to
  test the code in the PR and wrong for a submission, which must build a tagged
  release from immutable sources. The submission manifest is
  [#451](https://github.com/TheZupZup/Linthra/issues/451); until it exists, the
  manifest mode is linting the closest thing available.
- **The metainfo carries no screenshots.** Flathub requires at least one, and
  inventing them from the Android set would misrepresent the desktop window.
  Real Linux captures are
  [#437](https://github.com/TheZupZup/Linthra/issues/437), and the metadata pass
  that lands them is
  [#450](https://github.com/TheZupZup/Linthra/issues/450).

Neither is excepted, because neither is a case of the linter being wrong.

## Cheap checks that do not need a build

`test/tooling/flathub_metadata_guardrails_test.dart` holds the handful of
Flathub quality rules that are stable, textual and free to check: the 35-
character summary cap, no trailing period, no leading article, no repeated app
name, the 20-character name cap, the required metainfo elements, and the desktop
entry's visibility and icon name.

It is not a reimplementation of the linter — everything else is the linter's
job. It exists so a regression is caught on the PR that causes it rather than in
a submission review. The 35-character cap is the one that already bit: the
summary was 36.

## Where this runs

The `Build and launch Flatpak` job in `.github/workflows/flatpak-build.yml`
lints the manifest before the build and the repository plus AppStream catalogue
after the export. `.github/workflows/ci.yml` runs the runner's own unit tests on
every PR, because the linter needs a Flatpak and a long build but the judgement
around it does not.

## Related

- [flatpak-ci.md](./flatpak-ci.md) — the build this lints the output of
- [flathub-update-process.md](./flathub-update-process.md) — where a lint result
  sits in a release
- [flatpak-filesystem-audit.md](./flatpak-filesystem-audit.md) — the permission
  policy the manifest mode also checks
