---
name: release
description: Use when cutting a new version of claude-video-digest (asked to release, ship, tag or publish a version, put it on npm, or create a GitHub Release), or when a version tag's Publish run failed and needs recovery.
---

# Release

A release is one commit plus one annotated tag on `main`. Pushing the tag runs
[publish.yml](../../../.github/workflows/publish.yml), which publishes
`@anaidenko/claude-video-digest` to npm and then creates the GitHub Release.
Marketplace users get the new version through `plugin.json`.

Two actions here cannot be undone: the push, and (first release on npm only)
the hand-published release candidate. An npm version is permanent, and installed
copies pick up a bump on `main`. **Ask before each of them**, and show exactly
what will go out. Everything else is local and can be undone.

## 1. Preflight

This repo has no CI on `main`, so the local run is the only gate. Stop and
report if any of these fail:

```bash
git switch main && git status --porcelain        # must print nothing
git fetch origin && git status -sb               # not behind origin/main
npm run lint && npm run lint:py
npm test                                         # needs ffmpeg/ffprobe/python3 (npm run doctor)
./test/install-suite.sh && ./test/package-suite.sh
PREV="v$(node -p "require('./.claude-plugin/plugin.json').version")"
git log "$PREV"..HEAD --oneline                  # must not be empty
```

`npm run test:docker` repeats the suite on Linux; run it when the change
touches the script's platform handling.

`origin/main` must already hold everything except the release commit. If HEAD
is ahead, ask, then push `main`.

When `npm view @anaidenko/claude-video-digest` answers **404**, the package
does not exist yet: do [First publish](#first-publish-only-when-npm-has-no-package)
between steps 2 and 3.

## 2. Version and summary

- **Version**, from the changes since `$PREV`. A fix is a patch. A new
  capability users can see is a minor. If a user's setup stops working
  unchanged (a flag or config key removed, a platform dropped), it is a major.
  Ask when the call is not obvious.
- **Summary:** a short lowercase phrase naming the headline change *for
  users*, e.g. `clickable, one-per-line output links`. The tag and the Release
  title carry it.

## 3. CHANGELOG

The section becomes the GitHub Release notes verbatim, so it has to stand on
its own for a user. Headings here are bracketed and dated in UTC.

- If `## [Unreleased]` exists, rename it to `## [X.Y.Z] — YYYY-MM-DD` (today in
  UTC: `date -u +%F`). Then check it against `git log "$PREV"..HEAD`: add any
  user-visible change it is missing.
- Otherwise write the section from that log.
- Use `### Added` / `### Changed` / `### Fixed`, matching the entries below it.

## 4. Bump, commit, tag

The version lives only in `.claude-plugin/plugin.json`. Never add one to
`package.json`; `publish.yml` injects it at publish time.

```bash
node -e 'const f=".claude-plugin/plugin.json",fs=require("fs"),j=JSON.parse(fs.readFileSync(f));j.version="X.Y.Z";fs.writeFileSync(f,JSON.stringify(j,null,2)+"\n")'
git add .claude-plugin/plugin.json CHANGELOG.md
git diff --cached --stat                         # exactly these two files
git commit -m "chore(release): vX.Y.Z"
git tag -a vX.Y.Z -m "vX.Y.Z — <summary>"
```

`publish.yml` titles the Release with the tag's subject, and fails the run if
the tag does not equal `v` + the `plugin.json` version.

## 5. Ask before pushing

Show the user:
- the version and summary;
- the CHANGELOG section;
- `git log origin/main..HEAD --oneline`, which should be the single release
  commit;
- that the push publishes `X.Y.Z` to npm permanently, creates the GitHub
  Release, and offers the update to every installed copy.

Push only after an explicit yes in this conversation.

## 6. Push and watch

```bash
git push --follow-tags          # never --tags: it pushes the tag without the commit
gh run list --workflow publish.yml --commit "$(git rev-parse HEAD)" --json databaseId,status
gh run watch <databaseId> --exit-status
```

The run can take a few seconds to appear: repeat the `list` until it does.

## 7. Verify the result, not the log

```bash
npm view @anaidenko/claude-video-digest version                 # X.Y.Z; see the note below if it is missing
npm view @anaidenko/claude-video-digest@X.Y.Z dist.attestations # non-empty: provenance from CI
gh release view vX.Y.Z --json name,url
```

**A missing version is not yet a failure.** npm can answer "Your package is
being processed" even to a CI publish, and on a young package the version took
about 4 minutes to appear (1.2.0 of claude-video-digest, 2026-11-16). Poll
`npm view` for up to 10 minutes before suspecting the run. Do not re-run it:
the version is already taken.

A version published by hand has no attestations. That is expected for the
first-publish `rc.0`, and a red flag for any other version.

Then report the Release and npm links, plus the update line for users:
`npx @anaidenko/claude-video-digest`, or
`claude plugin marketplace update anaidenko && claude plugin update claude-video-digest@anaidenko`.

The marketplace repo (`anaidenko/claude-plugins`) needs no change unless the
plugin's description or repo URL changed.

## When the Publish run fails

| Failed step | Cause | Fix |
| --- | --- | --- |
| Check the tag matches plugin.json | tagged without the bump | Nothing was published: confirm with `npm view …@X.Y.Z` (404). Then `git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z`, add a fix commit (never amend a pushed one), and tag that commit. |
| Publish: 404, ENEEDAUTH, OIDC errors | the trusted publisher is missing, does not allow `npm publish`, or expired (a new one lapses 2 days after creation without a successful publish) | npmjs.com → package → Settings → Trusted publishing. Re-create it if it expired ([First publish](#first-publish-only-when-npm-has-no-package), step 3), then `gh run rerun <id> --failed`. |
| GitHub Release, npm already done | | `gh run rerun <id> --failed`: the npm job skips a version it already has. |
| Release notes are the generic fallback | the CHANGELOG heading did not match `## [X.Y.Z]` | `gh release edit vX.Y.Z --notes-file <file>` |
| A bad version reached npm | | Never `npm unpublish`. Run `npm deprecate @anaidenko/claude-video-digest@X.Y.Z "<why>"` and ship a fix. |

Never move a tag once npm has its version.

## First publish (only when npm has no package)

A trusted publisher can be configured only for a package that exists. A new
configuration **expires unless a publish succeeds through it within 2 days**.
So a release candidate creates the package by hand, and the real version goes
out through CI the same day, which validates the configuration.

Every npm write on the maintainer's account asks for a 2FA code, which this
session cannot enter. Give the user each npm command to run in their own
terminal, then check the result yourself with `npm view`.

This runs after step 2, so the version is known. `publish.yml` must already be
on `origin/main`, because npm checks that it exists. Do not push the release
commit early: once `plugin.json` changes on `main`, the marketplace offers the
version before npm or the Release has it.

1. **Ask first.** Show the user `X.Y.Z-rc.0` and say it stays in npm's version
   list for good, marked as a pre-release.
2. The user runs this from the clean, pushed HEAD:
   ```bash
   npm pkg set version=X.Y.Z-rc.0 && npm publish --tag next; git checkout package.json && git status --porcelain
   ```
   The rc is built from the pre-bump tree. Its `plugin.json` still says the
   previous version, which is harmless: npm does not deliver the plugin.

   **Expect a placeholder first.** npm answers "Your package is being
   processed", and for about 2 minutes `npm view … versions` lists only
   `0.0.0-stage`, tagged `latest`. That happens even with a plain
   `npm publish`, and the placeholder stays in the version list for good. Wait
   until the rc is listed, then have the user run
   `npm deprecate @anaidenko/claude-video-digest@0.0.0-stage "registry placeholder"`.
   The trusted publisher's 2-day clock should not start before the rc is
   visible.
3. The user creates the trusted publisher on npmjs.com → package → Settings →
   Trusted publishing → GitHub Actions. User `anaidenko`, repository
   `claude-video-digest`, workflow `publish.yml`, allow `npm publish`.
   Publishing access "Require two-factor authentication and disallow tokens"
   is compatible with it.
4. Check the release candidate: `npx @anaidenko/claude-video-digest@next --help`
   works.
5. Continue at step 3 now. The 2-day clock started at step 3 of this section,
   and only the CI publish of `X.Y.Z` stops it. If that run fails, fix it and
   re-run within the same window. Otherwise re-create the trusted publisher
   first.
