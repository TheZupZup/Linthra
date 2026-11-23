# Reddit release announcements

Linthra can turn a published stable GitHub Release into one short post in
`r/Linthra`.

The GitHub Release stays the source of truth. Reddit is only an announcement:
if Reddit is unavailable, the release remains published and nothing is rolled
back.

## What triggers it

`.github/workflows/reddit-release-announcement.yml` listens for GitHub's
`release: published` event.

It skips draft and prerelease releases. A tag, a merge, or editing an existing
release does not publish anything to Reddit.

Manual runs are preview-only. From **Actions → Reddit release announcement →
Run workflow**, enter a stable release tag and the workflow puts the exact title
and body in the job summary. A manual run has no path to the publish job.

## What the post sounds like

`scripts/reddit_release_announcement.py` reads the GitHub Release body and keeps
the post deliberately small:

- a short maintainer-style intro;
- at most five bullets, preferring `What's new` or `Highlights`;
- a thank-you;
- the GitHub Release URL;
- a short F-Droid follow-up.

The wording lives in `scripts/reddit_release_voice.json`, so changing the voice
later does not require editing the workflow.

There is no AI/LLM call in CI. The release notes are already human-written; the
script only trims and formats them.

## Reddit access in 2026

Reddit's current help documentation says the Data API is for **approved
developers** and requires OAuth. Reddit also directs developers to its Developer
Platform first and provides a Data Access Request path for bots/apps that are
not supported there.

This workflow uses the OAuth Data API because GitHub Actions is an external
service and the job needs to submit a normal text post. Reddit's Developer
Platform external endpoints are a limited-access feature too, so moving this
automation to Devvit would not remove the approval/setup step.

Before enabling live posting:

1. Request/confirm non-commercial Reddit Data API access for this use case.
   Describe it plainly: one maintainer-owned bot that posts Linthra release
   announcements to the Linthra community.
2. Register the OAuth client Reddit gives/approves for the app.
3. Authorize the Reddit account that will make the posts with **permanent**
   access and the minimum scopes used here: `read` and `submit`.
4. Keep the resulting refresh token. The workflow exchanges it for a short-lived
   access token on each release; it never stores a Reddit password.

Reddit's live API documents `/api/submit` for creating self-posts. OAuth API
requests are made through `oauth.reddit.com`, with a descriptive User-Agent.

Useful official references:

- https://support.reddithelp.com/hc/en-us/articles/14945211791892-Developer-Platform-Accessing-Reddit-Data
- https://support.reddithelp.com/hc/en-us/articles/16160319875092-Reddit-Data-API-Wiki
- https://www.reddit.com/dev/api/
- https://redditinc.com/policies/developer-terms
- https://redditinc.com/policies/data-api-terms

## GitHub setup

Create these repository **Actions secrets**:

- `REDDIT_CLIENT_ID`
- `REDDIT_CLIENT_SECRET`
- `REDDIT_REFRESH_TOKEN`

Then create this repository **Actions variable**:

- `REDDIT_RELEASE_ANNOUNCEMENTS_ENABLED` = `true`

The variable is the kill switch. Until it is exactly `true`, stable releases
still build a preview but the Reddit publish job is skipped.

Do not put a Reddit password in GitHub.

The refresh token must have the `read` and `submit` scopes:

- `submit` creates the text post;
- `read` lets the workflow check recent `r/Linthra` posts before publishing, so
  rerunning a workflow does not create a duplicate.

## Duplicate protection

Every generated post includes the GitHub Release URL.

Before submitting, `scripts/post_reddit_release.py` reads the newest posts in
`r/Linthra` and looks for that exact release URL in the self-post body. If it is
already there, the script exits successfully without creating another post.

The workflow also uses a per-release GitHub Actions concurrency group, so two
runs for the same release do not publish at the same time.

This makes the normal recovery path simple: if a Reddit job fails, fix the
credential/API problem and rerun that failed workflow. If Reddit actually
created the post before the failure, the duplicate check finds it.

## Failure behavior

A Reddit failure can make the announcement workflow red, but it cannot:

- unpublish or delete the GitHub Release;
- delete a tag;
- change app/F-Droid metadata;
- merge anything;
- create a retry loop.

The posting script does not print OAuth tokens, client secrets, or refresh
tokens. HTTP error bodies from the OAuth exchange are deliberately not echoed to
Actions logs.

## Disable it

Set `REDDIT_RELEASE_ANNOUNCEMENTS_ENABLED` to anything other than `true`, or
disable the workflow in GitHub Actions.

Preview mode continues to work even while live posting is disabled.

## Local preview

Save a GitHub Release JSON payload and run:

```bash
python3 scripts/reddit_release_announcement.py \
  --release-json release.json \
  --voice-config scripts/reddit_release_voice.json \
  --output-dir /tmp/linthra-reddit
```

Then inspect:

```text
/tmp/linthra-reddit/title.txt
/tmp/linthra-reddit/body.md
```

The generator uses only Python's standard library and makes no network request.

## Tests

Run:

```bash
python3 test/tooling/reddit_release_announcement_test.py
```

The tests cover stable/prerelease filtering, empty and very long release notes,
the bullet limit, Markdown cleanup, conservative Reddit length limits, secret
isolation, duplicate detection, missing credentials, and the fact that manual
workflow runs cannot reach the publisher.
