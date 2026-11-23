# Repository hardening

Linthra uses two independent pull-request security gates:

- **Security surface guard** classifies sensitive code and requires an explicit
  owner review for risky trust-boundary changes.
- **Repository integrity guard** fails closed on repository-control changes and
  disguised executable assets.

The repository-integrity layer was added after a real PR-history incident in
which an unrelated commit carried IDE auto-run configuration and executable
JavaScript disguised as a `.woff2` asset. The goal is prevention, not
attribution: Git history can establish provenance and branch movement, but not
a person's intent.

## What the repository integrity guard blocks

For external contributor PRs:

- `.vscode/**`, `.idea/**`, and `*.code-workspace`, matched case-insensitively
  so case variants cannot collide on contributor filesystems
- `.github/workflows/**` and composite actions under `.github/actions/**`, which
  privileged workflows run from the PR head
- repository automation under `scripts/`, `tool/`, and `tools/`
- `CODEOWNERS`, `.gitattributes`, `.gitmodules`, and Dependabot policy
- Git symlinks

For every PR, including maintainer PRs:

- removal of `.idea/` or `.vscode/` from the root `.gitignore`, including a
  later `!` rule that re-enables one of them (Git applies the last matching
  rule, so presence of the entry alone proves nothing)
- files whose extension claims WOFF/WOFF2/TTF/OTF/PNG/JPEG/GIF/WEBP but whose
  contents are not structurally that format. A magic prefix is not enough:
  `wOF2` followed by JavaScript is four valid bytes, so each format is checked
  against a self-describing field — a declared length that must equal the real
  file size, or a redundant field derived from another
- active/executable SVG content such as `<script>`, any `on*=` event handler,
  `javascript:` URLs, `foreignObject`, or external executable references. The
  scan runs over the raw source, the entity-decoded text, and a URL-normalised
  form, since an XML parser resolves `java&#x73;cript:` and a URL parser then
  discards embedded tabs and newlines
- asset files committed with the executable bit set. The text scan only sees an
  invocation someone wrote down; a payload committed already-executable needs
  none
- text that invokes an asset such as `.woff2`, `.png`, or `.pdf` through
  Node/Python/shell interpreters (including `source` and dot commands), or
  marks one executable with `chmod +x` or an executable numeric mode. Shell
  backslash-newline continuations are resolved before this scan

Repository-control changes must be made from a trusted maintainer-controlled
branch.

## Self-test fixtures

The guard's own test module has to contain literal attack strings so it can
assert that they are caught, which would otherwise make the repository-wide
text scan flag the test file itself.

The carve-out for this is deliberately small. A line inside
`test/tooling/check_repository_integrity_test.py` is skipped by the
asset-execution text scan — and by that check only — when it carries the
marker `integrity-guard-fixture`. Every other line of that file, and every
other check, still applies, and the same path is maintainer-controlled for
external PRs so a fork cannot introduce a marked line. Fixture content written
into a test repository carries no marker, so the attack strings the tests
assert against remain detectable.

Prefer this marker over path-wide exclusions: `test/` and `test/tooling/` stay
fully scanned, because executable test infrastructure is itself a security
surface.

## Where the asset checks stop

Container validation raises the cost of disguising an executable as an asset;
it does not close the class. The honest boundary:

- **Binary formats** (WOFF/WOFF2, TrueType/OpenType, PNG, JPEG, GIF, WEBP, ICO)
  are validated structurally end to end — declared lengths must match, chunk and
  block chains must land exactly on the end of the file, and an image must carry
  a real bitstream signature. Polyglots against these are hard.
- **PDF is different.** A shell reads a file line by line and continues past
  errors, so only the opening lines decide what runs. No amount of trailing
  xref, trailer or object structure prevents a payload on line two, and a
  genuine PDF is itself "runnable" that way as a series of failing commands.
  Parsing the object graph would buy nothing here, so the PDF check is a
  deliberate sanity layer only.

For WEBP the arithmetic happens to close the polyglot class outright. A file
that is also JavaScript needs bytes 4-7 to open a comment (`/*` or `//`), and
both begin `0x2F`, which little-endian makes the declared RIFF length odd. The
chunk chain after the 12-byte header always consumes an even number of bytes,
since every chunk is 8 + payload + pad-to-even. So the file size is even while
`declared + 8` is odd, and no such file can pass. This is why later requests to
validate the frame bitstream more deeply were declined: a minimal frame may be a
corrupt image, but it cannot be an executable one.

What actually defends a disguised asset is denying it an execution path:

- assets may not carry the executable bit
- no file in the repository may invoke one through an interpreter
- IDE and container auto-run surfaces are maintainer-controlled

Treat those three as the real control, and the format validators as depth.

## Required GitHub ruleset for `main`

Create or update a branch ruleset targeting `main` and configure all of the
following:

1. **Require a pull request before merging**
   - required approvals: **1**
   - **Dismiss stale pull request approvals when new commits are pushed**
   - **Require review from Code Owners**
   - **Require approval of the most recent reviewable push**
   - **Require conversation resolution before merging**
2. **Block force pushes**
3. **Restrict deletions**
4. **Require status checks to pass before merging**
   - `Flutter checks`
   - `Secret & privacy scan`
   - `Build Linux desktop`
   - `Security surface guard`
   - `Repository integrity guard`
5. Do not give ordinary contributors a ruleset bypass.
6. Prefer an empty bypass list; if an emergency bypass is retained, keep it to
   the repository owner only.

### Required-workflow pinning

A status check matched only by name is not enough for a security workflow:
a contributor can edit a workflow file in the same PR and attempt to preserve
the job name while replacing its steps.

Use a GitHub **required workflow / ruleset workflow requirement pinned to the
trusted repository and default branch** for:

- `.github/workflows/pr-security-review.yml`
- `.github/workflows/repository-integrity.yml`

This ensures the trusted workflow definition is what evaluates the PR.

## Actions settings

Under **Settings → Actions → General**:

- keep the default `GITHUB_TOKEN` permission **read-only** unless an individual
  workflow explicitly needs more
- leave **Allow GitHub Actions to create and approve pull requests** disabled
  unless a documented maintainer workflow needs it
- require approval before workflows from untrusted fork contributors run, using
  the strictest option that still fits the project workflow
- never attach repository secrets to untrusted `pull_request` jobs

## Reporting findings on fork pull requests

The scanner (`.github/workflows/repository-integrity.yml`) runs on
`pull_request` with `contents: read` and no secrets. It writes nothing. A
separate trusted workflow, `repository-integrity-reporter.yml`, runs on
`workflow_run` from the default branch, never checks out the PR head, and holds
the only `pull-requests: write` grant.

For a pull request opened from a fork, GitHub delivers
`workflow_run.pull_requests` as an empty array. The reporter used to require
that array to be populated, so on external pull requests the check went red
with no comment explaining why — observed on #513, #514 and #515.

The pull request is now recovered from the scanner artifact and then bound to
evidence a contributor cannot forge. The scanner workflow file is
contributor-controlled at the merge ref, so `pr_number` in the artifact is a
claim, not an authority. `scripts/resolve_repository_integrity_pr.py` accepts it
only when all of the following hold:

1. The triggering run is the scanner's own: expected event, expected display
   name, expected immutable file path, expected repository.
2. The artifact was downloaded with `run-id` pinned to that exact run.
3. The artifact's `head_sha` and `head_repository` equal
   `workflow_run.head_sha` and `workflow_run.head_repository.full_name`, both
   set by GitHub from the pull request that started the run.
4. Exactly one pull request has that head commit *and* that head repository.
   More than one, or none, is refused rather than guessed. The association
   response is read whole: the endpoint pages at 30 by default and advertises
   the rest through a `Link: rel="next"` header, so an unpaginated read could
   both miss the pull request being resolved and hide a second match from this
   very check, deciding "exactly one" against a set that was silently cut
   short. Accumulation is bounded, and exceeding the bound fails closed. This association
   query must be asked of the **head** repository: a fork's head commit is not
   in the base repository's commit list, so
   `/repos/{base}/commits/{fork_sha}/pulls` answers `[]` for exactly the fork
   pull requests this path exists to resolve — confirmed against the live API
   with #513's head. Asking a contributor-controlled repository grants nothing,
   because the repository name is `workflow_run.head_repository.full_name`,
   which GitHub sets, and step 5 still constrains every candidate it returns.
5. The live pull request, fetched by number **from this repository**, agrees:
   same number, based on this repository, same head repository, same head
   branch where the run carries one, and its head is still the scanned SHA.
   The branch name is compared as opaque data: git accepts more than an obvious
   character allowlist admits (`feature+test`, `feature@2`, non-ASCII names all
   pass `git check-ref-format`), and rejecting a legitimate branch would strand
   that pull request with a red reporter and no comment. Since the value is only
   ever compared against the pull request's own `head.ref`, and never forms a
   URL, a command, or a log line, no character in it can mean anything.

Republishing another contributor's head commit into your own fork makes step 3
match on the SHA, but the head repository is still your fork, so steps 4 and 5
resolve to your own pull request. There is no input that makes the reporter
comment on somebody else's.

### The verdict is re-derived, never taken from the artifact

Identity binding proves *which* pull request a report describes. It cannot prove
the report is honest. A `pull_request` workflow definition comes from the merge
ref, so a fork contributor can keep the scanner's name and path, drop the step
that loads the trusted checker, and upload a findings artifact whose identity
fields are the genuine GitHub-provided ones and whose `findings` list is empty.
Every field identity binding checks would be honest; only the verdict is forged.
Published, that would put a CLEAN comment under `github-actions[bot]`, lending
contributor-authored content the authority of the maintainer-controlled
reporter.

So the artifact's `findings` are never the source of a published verdict. The
reporter re-derives them with `scripts/recompute_repository_integrity_report.py`,
running the checker from this trusted default-branch checkout over the same
commit range, from a base SHA, head SHA and PR author read from the live pull
request rather than from the artifact. A divergence between the uploaded and
re-derived results is reported and the re-derived one wins — refusing to comment
on a mismatch would let a forged artifact suppress the finding it was forged to
hide.

The checker itself is read out of the pull request's **base commit**, the same
revision the scanner loads with `git show "$BASE_SHA:…"`. Running the reporter's
own default-branch copy instead would apply a different revision whenever the
base is not the default branch, or whenever the checker changed on the default
branch between the scan and the report — and the two can enforce different
rules, so the comment could report CLEAN while the guard is red. Both revisions
are maintainer-controlled, so this is a consistency requirement rather than a
trust one: the check and the comment explaining it must never disagree.

One window is left open deliberately. `base.sha` on a pull request tracks the
base branch's current tip, not the tip the scanner saw, so if the base branch
advances between the scan and the report the reporter re-derives against a
slightly newer base. The commit set is unaffected — commits pushed to the base
after the scan are not reachable from a head that predates them, so
`rev-list head --not base` yields the same commits either way — and only the
checker revision can differ, and only when the push that moved the base also
changed the checker, inside the seconds between the two runs. Closing it would
mean taking the scan-time base SHA from the contributor-controlled artifact,
making an artifact field decide something again; the narrower risk is the better
trade.

No pull-request code is executed and no pull-request tree is checked out. The
checker reads git objects only, so the objects are fetched into the trusted
checkout through this repository's own `refs/pull/N/head` and analysed as data;
the working tree stays on the default branch. A checker that cannot evaluate the
range — or a base commit that carries none — is an error, never an empty finding
list.

Every failure is silent-and-red rather than best-effort: a malformed artifact,
a missing binding, a mismatch, an ambiguous pull request, an unexpected workflow
path, or an unexpected repository all end the job without a comment. A head that
has moved on since the scan is treated as superseded, so an out-of-order run
never overwrites a newer verdict.

One case is deliberately not a failure: the guard job does not run on draft pull
requests, so those runs upload no artifact and there is genuinely nothing to
report. That is told apart from every other reason the report can be missing —
a transport error, an expired artifact, a permissions failure, a scan that died
before uploading — by reading the run's artifact list and then the guard job's
conclusion from the Actions API, before downloading anything. A skipped guard
job is not by itself proof of a draft: the scanner workflow file comes from the
merge ref, which is why the scanner loads its checker from the trusted base
rather than from the pull request, and that same contributor can keep the guard
job's name while setting its condition to false. Suppression therefore also
requires the pull request's own `draft` flag, read from the pull request the
run's head actually belongs to, resolved under the same head-repository
association rule and the same one-candidate constraint the binder uses. Tolerating a failed
download instead would read all of those as "nothing to report" and finish
green, leaving an earlier sticky verdict standing over a scan whose result was
never rendered.

## Contributor model

External contributors should work from their own forks. Avoid granting `Write`
access to the upstream repository merely to make contribution easier.

For fork PRs:

- keep branch ownership isolated in the contributor's fork
- only use **Allow edits from maintainers** when a maintainer actually needs to
  repair that contributor's branch
- after any force-push, re-review the current HEAD; previous approval must not
  carry forward

## Incident response

If a PR contains unexpected executable content:

1. do not run the branch locally
2. close or quarantine the PR
3. record commit SHA, author/committer metadata, branch force-push events, and
   the exact suspicious files
4. compare the suspect commit with its parent to identify provenance
5. rebuild useful feature work from a known-clean base instead of "cleaning"
   the contaminated branch
6. rotate secrets only if evidence shows they may have been exposed
7. avoid attributing intent unless there is evidence beyond Git metadata
