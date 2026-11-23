# PR security surface guard

## Repository-integrity history

The separate `.github/workflows/repository-integrity.yml` gate also inspects
the commits a pull request would add to the target branch. A clean final diff
is not sufficient: adding a prohibited asset or repository trust-surface
change and deleting it in a later commit remains blocked because the offending
commit would still enter history.

The history boundary is deliberately narrow. The checker enumerates commits
reachable from the PR head but not from the trusted base SHA, so commits already
reachable from `main` are never reclassified. Each ordinary commit is checked
against its parent. For a merge commit, only a path whose result differs from
every parent is considered merge-introduced; this catches a novel conflict
resolution without treating an ordinary GitHub **Update branch** merge as if
it authored all the legitimate changes imported from `main`.

Reports name the full offending commit SHA, path, and reason. The workflow uses
a full-history checkout and loads the checker itself from the trusted base, so
missing ancestry or an unreadable commit fails closed rather than silently
falling back to the final tree.

`.github/workflows/pr-security-review.yml` decides whether a pull request
crosses a trust boundary that deserves an explicit maintainer security review,
and hard-rejects a small set of unusually powerful additions. The classifier
lives in `scripts/check_pr_security_surface.py`; its tests are
`test/tooling/check_pr_security_surface_test.py`.

## What it does

- **Ordinary PRs pass untouched.** UI, tests and docs changes produce
  `sensitive=false` and the gate is a no-op.
- **Sensitive surfaces need a review.** Changes to anything under `.github/`
  except issue templates and funding metadata (workflows, composite actions,
  Dependabot config, and the agent prompts CI feeds to `openai/codex-action`),
  automation trees
  (`scripts/`, `tool/`, `tools/`), dependency manifests, build toolchain pins
  (`.flutter-version`, `.java-version`, the Gradle wrapper and its
  `distributionUrl`), Cargo manifests and lockfiles, Android permissions, the
  `res/xml/` security and privacy policy and the Kotlin shipped in the APK,
  the analyzer configuration, licence text, release signing material and the
  F-Droid build recipe under `metadata/`,
  native code under `linux/` and `native/` with its CMake build files, the Dart
  build hooks under `hook/`, or to
  auth/network/persistence code — and added behaviour such as new network
  clients, filesystem writes or database migrations — require **TheZupZup to
  have approved the exact current HEAD**. Pushing a new commit changes the
  HEAD, so the previous approval no longer applies.
- **Naming a blocked capability in prose is not using it.** In a documentation
  or plain-text file, a blocked pattern is downgraded to a review rather than a
  rejection — a page listing forbidden APIs has to spell them out. It is
  downgraded, not ignored: a README telling a reader to pipe a download into a
  shell still gets an owner's attention. Inside source files the block stands,
  whatever the surrounding comment or string context, because deciding that
  needs a lexer and a wrong answer there is a bypass.
- **A few additions are rejected outright.** Runtime process execution, shell
  execution enabled by a flag (an explicit `false` is not a capability and is
  not blocked),
  FFI and dynamic library loading, the privileged pull-request trigger variant
  (`pull_request` + `_target`), Actions `write-all` permissions, and
  download-and-execute shell patterns are not bypassable by approval. If
  Linthra genuinely needs one of these, it should land as its own
  maintainer-controlled change, not inside an unrelated contributor PR.
- **Two reviewed exceptions, for the Rust core's bridge.** Process execution
  in `hook/build.dart` (the build hook runs cargo) and FFI in the direct
  children of `lib/core/native/` (the bindings themselves) are reported as
  sensitive instead of blocked, so an external PR there still needs the owner's
  approval of its HEAD. The same constructs anywhere else, including
  `hook/link.dart` or a subdirectory of `lib/core/native/`, stay blocked. The
  list is `BLOCKED_RULE_REVIEWED_PATHS` in the scanner; adding to it is itself
  a change to the guard.
- **The scanner comes from the trusted base.** The workflow reads
  `scripts/check_pr_security_surface.py` out of the PR's base commit, so a PR
  cannot weaken the classifier in the same change it is trying to pass.
- **It reads post-change source, not just `+` lines.** Rules run against each
  changed file's content at the PR head, and a match is reported only when it
  overlaps a line the PR added. A construct assembled partly from tokens that
  were already in the file is therefore caught, while code the PR never touched
  is left alone.
- **Touching a file that already holds a blocked construct needs review.** A
  change elsewhere in a file can make untouched code live without retyping it —
  deleting a comment opener does it, and so does flipping `if (false)` to
  `if (true)`, which loses no lines at all. Enumerating the ways would mean
  deciding reachability, which a regex cannot do, so any change to such a file
  is marked sensitive and a maintainer is asked to look. Eight files in the
  repository currently qualify, seven of them under `test/tooling/`.

  The sensitive patterns get a narrower version of the same treatment: they
  match in 356 files, so asking on every edit near one would make the ordinary
  PR a reviewed PR. There, the trigger is specific — the PR removed a line that
  had been *suppressing* code: a block or markup comment delimiter, a disabled
  preprocessor branch, an `if (false)` guard. That catches uncommenting however
  it is spelled, including replacing the delimiters with blank lines, while an
  ordinary edit or deletion beside such code stays ordinary.
- **It fails closed.** A missing base commit, an undecodable diff header, a
  scanner crash, or a scan that ends without a verdict all fail the job.

The workflow holds only `contents: read` and `pull-requests: read`, receives no
repository secrets, and never executes contributor code.

## Required repository configuration

> **The workflow cannot enforce this part itself.** Configure it once, in
> repository settings.

For `pull_request` events GitHub evaluates the workflow definition from the
PR's merge ref. A contributor can therefore edit
`.github/workflows/pr-security-review.yml` in their own PR — keeping the
workflow name and the `Security surface guard` job name while replacing the
steps with something that trivially succeeds. A required status check matched
**by name** would accept that green result even though the trusted scanner
never ran.

To close it, the guard has to run from a definition the PR cannot edit:

1. Open **Settings → Rules → Rulesets** and add a ruleset targeting the default
   branch.
2. Enable **Require workflows to pass before merging**.
3. Add `.github/workflows/pr-security-review.yml` from **this repository**,
   pinned to a trusted ref (`main`, or a tag/SHA you bump deliberately).
4. Keep **Require status checks to pass** enabled as well, so the check is
   both required and sourced from the trusted definition.

With the ruleset in place, editing the workflow inside a PR no longer changes
what runs for that PR. Without it, the classifier is still loaded from the
trusted base — but the surrounding gate is only as trustworthy as the PR's own
copy of the workflow.

Changes to the guard's own files are classified sensitive, so an external PR
touching them needs a maintainer security review regardless.

## What it does not do

The blocked list is a backstop against careless or opportunistic additions, not
a decision procedure against a determined attacker. It matches patterns; it does
not parse Dart or shell. A capability assembled through intermediate variables
across statements, or a download separated from its execution by more than the
rule's window, can still get past it.

What actually bounds the risk is structural, and is described above: the scanner
is loaded from the trusted base, sensitive surfaces need an owner approval tied
to the exact HEAD, and — once configured — the required-workflow ruleset means a
PR cannot replace the gate that judges it. Treat a gap in the pattern list as a
bug worth fixing, not as the thing standing between the repository and a
motivated contributor.

## Bootstrap

The first PR to introduce the scanner cannot load it from a base that does not
contain it yet. In that single case the workflow falls back to the PR head's
copy, and only when the PR author is the repository owner **and** the head
branch lives in this repository. An external PR whose base lacks the scanner
fails closed instead. Once the scanner is on `main`, this path is unreachable.

## Working on the guard

Run the tests directly:

```sh
python3 test/tooling/check_pr_security_surface_test.py
```

They build synthetic git repositories for every classification and blocked
pattern, cover the diff-rendering tricks that would otherwise hide an added
line (quoted pathnames, pathname bytes that are not valid UTF-8,
`.gitattributes` `-diff`, renames, comments wedged between tokens, and
constructs split across lines, across hunks, completed from untouched context,
or activated by an edit elsewhere in the file), and execute the workflow's
own trusted-scanner
loader and review-decision filter straight out of the YAML.

One constraint is easy to trip over: the guard scans the content of every
changed file, **including its own sources**. A blocked pattern written out in
full in the scanner, the workflow, or the tests would make the guard reject any
PR that touches the guard. `_split_literal()` in the scanner and `blocked()` in
the tests assemble those literals from fragments, and
`GuardSelfSafety` fails the build if a contiguous one ever creeps back in.
