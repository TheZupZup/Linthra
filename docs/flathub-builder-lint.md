# Flathub builder lint

Issue: [#449](https://github.com/TheZupZup/Linthra/issues/449)
Parent: #376

CI has validated Linthra's desktop entry and metainfo for a while, with
`desktop-file-validate` and `appstreamcli validate`. Those answer a different
question: whether two files are well-formed.

Flathub's own linter answers the one that matters for a submission: whether it
would be *accepted*. It checks whether the sources are reproducible, whether the
permissions are ones Flathub grants, whether the metainfo carries what a
software centre needs to show the app at all, and a long list of listing-quality
rules that no XML validator knows about.

## The exact commands

The linter ships inside the `org.flatpak.Builder` Flatpak, which is how
Flathub's own documentation runs it, the same tool a reviewer uses.

```sh
flatpak install -y flathub org.flatpak.Builder

# The manifest, before anything is built.
flatpak run --command=flatpak-builder-lint org.flatpak.Builder \
  manifest flatpak/io.github.thezupzup.linthra.yml

# The exported repository, what Flathub would publish.
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
# That sequence ends inside flatpak/, and the paths below are relative to the
# repository root.
cd ..

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
*nothing at all* when a mode finds nothing, and exits 0. That is a clean
report, and it cannot be confused with a missing tool because the linter's
presence is established before any mode runs. Silence with a **non-zero** exit
explains nothing and is still refused.

Nor does every mode speak JSON: `appstream` hands the catalogue to
appstreamcli and prints its verdict as text. There the exit code is the
verdict, and the text is printed either way.

**A finding needs a written reason.** Any error or warning that is not listed
in `flatpak/flathub-lint-exceptions.json` fails the run. Warnings count:
reviewers read them, and #449 is about reaching a submission-quality result
rather than an exit code.

**A reason cannot outlive its problem.** An exception the linter no longer
reports also fails the run, so the file cannot quietly accumulate justifications
for things that were fixed years ago.

**Exception keys carry their mode**, as `manifest/`, `repo/` or `appstream/`,
for example `repo/appstream-screenshots-not-mirrored-in-ostree`. CI does not
run every mode in one invocation: the manifest is linted before the build and
the repo and catalogue after it. Without the mode, the staleness check above
could not tell an exception whose problem was fixed from one whose mode simply
did not run in that invocation, and would fail the build on a live exception.
Qualifying the key also stops a reason written for one mode accepting a
same-named finding from another.

**An exception with no reason is rejected outright**: an empty string there is
a suppression wearing a different hat.

**A `<mode>-lint-failed` finding cannot be excepted at all.** That name means
the linter itself failed rather than reporting something about the submission,
and it is the same name whatever the failure was. A reason attached to it would
go on matching after the original problem was fixed and a different one
appeared, which is the one thing the staleness rule exists to prevent.

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

## What CI gates on today

| Mode | Gates CI | Result today |
| --- | --- | --- |
| `manifest` | yes, before the build | clean |
| `appstream` | yes, after the build | clean |
| `repo` | not yet, see below | two screenshot findings |

`manifest` runs before the build, so a manifest finding fails in about a second
rather than after ninety minutes. `appstream` needs the build, and runs *after*
the launch smoke: a failed step ends the job, so a lint ahead of the smoke would
stop the package being installed and launched at all, which trades real
coverage for a red badge.

`repo` is the one that waits. It reports `metainfo-missing-screenshots` and
`appstream-screenshots-not-mirrored-in-ostree`, both real submission blockers
whose fix is to take screenshots
([#437](https://github.com/TheZupZup/Linthra/issues/437),
[flathub-screenshots.md](./flathub-screenshots.md)) rather than to change
anything here. Wiring it in before then would mean one of two things, and both
are worse than waiting:

- a permanently red job, which trains everyone to ignore it and buries any
  *new* finding under the one everybody already knows about;
- an exception, which the rules above forbid for a finding that is simply not
  fixed yet.

It is turned on in
[#628](https://github.com/TheZupZup/Linthra/issues/628), together with the
screenshots that let it pass. A guardrail in
`test/tooling/flathub_metadata_guardrails_test.dart` fails if it is wired in
without that, so switching it on is a decision someone makes rather than
something that drifts in.

Note that `appstream` and `repo` are different checks despite both mentioning
screenshots: `appstream` reads the catalogue `appstreamcli compose` generated,
and `repo` reads the exported OSTree that Flathub would publish. Only the second
currently reports anything, which is why only the second waits.

## Exceptions

`flatpak/flathub-lint-exceptions.json` is **empty**, and that is the state
[#456](https://github.com/TheZupZup/Linthra/issues/456) requires before
submission.

An entry there is not a way to make the check green. It is a claim that a person
looked at a finding and decided the linter is wrong or the problem is
unavoidable for Linthra, and the reason has to say which. A finding that is
simply *not fixed yet* belongs in its issue, not here.

## Where it stands

First real run, against `flatpak-builder-lint 3.0.0.post798.dev0+5181352`:

| Mode | Result |
| --- | --- |
| `manifest` | **clean** |
| `appstream` | **clean**, "Validation was successful." |
| `repo` | two errors, both the same missing screenshots |

The `repo` findings:

```text
appstream-screenshots-not-mirrored-in-ostree (error)
metainfo-missing-screenshots (error)
info: metainfo-missing-screenshots: The metainfo file is missing screenshots
      or it is not present under the screenshots/screenshot/image tag
```

Notably *not* reported: the manifest's `type: dir` source. The development
manifest builds the working checkout, which is right for testing a PR and wrong
for a submission, but that is a Flathub *submission* requirement enforced
elsewhere, not something this linter flags, so the submission manifest
([#451](https://github.com/TheZupZup/Linthra/issues/451)) is still needed and
this check will not tell you so.

### Why the screenshots are not excepted

Flathub requires at least one screenshot, and it is right to. Inventing them
from the Android set would misrepresent the desktop window, so the fix is real
Linux captures ([#437](https://github.com/TheZupZup/Linthra/issues/437)) landed
through the metadata pass
([#450](https://github.com/TheZupZup/Linthra/issues/450)).

Until then the `repo` mode is red, and that is the honest state: the linter has
found something real that Linthra has not fixed yet. An entry in the exceptions
file would only record that we would rather not see it.

## Cheap checks that do not need a build

`test/tooling/flathub_metadata_guardrails_test.dart` holds the handful of
Flathub quality rules that are stable, textual and free to check: the 35-
character summary cap, no trailing period, no leading article, no repeated app
name, the 20-character name cap, the required metainfo elements, and the desktop
entry's visibility and icon name.

It is not a reimplementation of the linter: everything else is the linter's
job. It exists so a regression is caught on the PR that causes it rather than in
a submission review. The 35-character cap is the one that already bit: the
summary was 36.

## Where this runs

The `Build and launch Flatpak` job in `.github/workflows/flatpak-build.yml`
lints the manifest before the build and the AppStream catalogue after the
export. It does **not** currently lint the exported repository: that mode is
deferred, per the table above, so CI passing is not evidence that the
publishable OSTree was checked. Run it locally, or wait for
[#628](https://github.com/TheZupZup/Linthra/issues/628).

`.github/workflows/ci.yml` runs the runner's own unit tests on every PR,
because the linter needs a Flatpak and a long build but the judgement around it
does not.

## Related

- [flatpak-ci.md](./flatpak-ci.md), the build this lints the output of
- [flathub-update-process.md](./flathub-update-process.md), where a lint result
  sits in a release
- [flatpak-filesystem-audit.md](./flatpak-filesystem-audit.md), the permission
  policy the manifest mode also checks
