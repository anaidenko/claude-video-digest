# Changelog

Notable changes per release. Dates are UTC.

## [1.1.0] — 2026-08-12

### Added

- **README: Update and Uninstall sections.** Verified live: `claude plugin update <name>` fails
  with "not found" even when installed — the `@marketplace` suffix is required, and
  `marketplace update` has to run first or the version check uses a stale cache.

### Changed

- **The skill's closing summary now links its output files instead of naming them as bare
  text.** `contact-sheet.jpg`, `frames/`, `transcript.txt`, `source.url` and `meta.json` are
  each rendered as `[label](file:///abs/path)`, one per line — a bare path is inert in most
  chat hosts, and several links joined by `·` on one line render as a cluttered run-on. The
  `transcript.txt` line is omitted entirely (not linked to a missing file) when the run
  produced no transcript.

## [1.0.0] — 2026-08-12

First stable release: the tool is now covered by a test suite on two platforms, and the plugin
install path has been verified end to end rather than assumed.

### Fixed

- **The skill failed on a real plugin install (exit 127).** `SKILL.md` invoked the script by a
  relative path, which Claude Code resolves against the skill's own directory — but the script
  lives at the plugin root. It now uses `${CLAUDE_PLUGIN_ROOT}`. This could only surface on an
  actual plugin install; every clone-based test passed because the relative path is correct from
  a repo root.
- **A run with a persistent `--output` never printed where it wrote anything.** The output
  directory was reported only for temp-dir runs. It now always prints, along with a path to
  `source.url`, and the skill relays these so an answer ends with the files you can open.

### Added

- **Test suite** — `npm test` (48 assertions) and `npm run test:docker`, which runs the same
  suite inside the project's Debian image. Verified on macOS bash 3.2 and Debian bash 5.x.
  Every case corresponds to a bug that actually shipped.
- **Team install documentation** — project-scoped install via the repo's own
  `.claude/settings.json`, so a plugin ships with the project instead of per developer.

### Changed

- `secondsPerFrame` default 4.5 → 5.
- README's configuration table gained an example column; `contactSheet` and `frames` are listed
  separately (they are independent); `silenceFloorDb`'s negative default is explained as dBFS.
- **Corrected the documented config-file precedence.** The two config files do not layer: the
  first match wins (`--config`, then `./.video-digest.json`, then
  `~/.config/video-digest/config.json`), so a project-local file fully shadows the user-wide one.
  The previous description was wrong.

## [0.2.0] — 2026-08-12

### Added

- **Droplr support, verified against live links.** The extractor now falls back to `og:video` /
  `og:video:secure_url` / `twitter:player:stream` meta tags when no URL on the page ends in a
  video extension. Droplr serves `cdn-std.droplr.net/files/acc_NNN/<id>` — no extension at all —
  so every extension-based pattern missed it, and yt-dlp doesn't support the host either. This
  also makes the scraper work on any host that advertises its video through Open Graph.
  ⚠️ Previous releases described Droplr as "expected to work, unverified" on the reasoning that
  its pages had the same shape as Zight's. They don't, and it didn't — running it is what
  established that.
- `CHANGELOG.md`, `CONTRIBUTING.md`, `package.json`, and GitHub issue templates.

### Changed

- README restructured: demo and usage examples first, comparison with other tools moved below
  the practical sections.
- `docs/example-output/` now carries real output from two runs — a contact sheet from a clip
  with no narration, and a frame-grouped transcript from a narrated one — since a single
  screenshot only demonstrated half of what the tool does.

### Note on 0.1.1

`plugin.json` was not bumped for 0.1.1, so plugin installs never saw it — its fixes reach users
with this release instead. The version in `.claude-plugin/plugin.json` is the single source of
truth for the plugin cache; a tag alone doesn't deliver anything.

## [0.1.1] — 2026-08-12

Two real bugs, a security hardening pass, and a fix carried over from the tool's first real
triage use. Found by an independent review of 0.1.0 on the same day it shipped.

### Fixed

- A value-taking flag with nothing after it (`… --ticket`) exited 1 **silently**: `${2:-}`
  guards the expansion, not the following `shift 2`, and `set -e` killed the script with no
  message. All value-taking flags now validate before consuming.
- `--no-frames` leaked a temp directory of JPEGs on every run — a comment claimed the directory
  was discarded, but nothing discarded it.
- An explicit `--max-frames` was silently clamped back down on short clips by the same
  heuristic it was meant to override (`--max-frames 40` on a 13.7s clip produced 14 frames).
  Real cost in the originating project: a wrong conclusion written into a report before the
  clamp was discovered.
- The `--config` pre-scan matched the literal string anywhere in the arguments, so it could
  misread an adjacent flag's value as the config path.
- Config numeric fields (`silenceFloorDb`, `secondsPerFrame`) accepted non-numeric values
  silently instead of erroring.
- `doctor`'s `drawtext` probe used a piped `grep -q` that can report a false negative under
  `pipefail` — inconsistent with the capture-then-match form used elsewhere for the same check.

### Security

- The scraper follows a URL chosen by the *fetched page*, not by the user, and `-L` means a
  redirect chain can retarget it. Now bounded with `--proto '=https,http'` and `--max-redirs 3`,
  and the resolved host is printed before downloading so a pivot is visible. Documented in the
  README — the risk is reduced, not eliminated.
- A share link that returns HTTP 200 with an HTML page (expired link, login wall) used to fail
  later with a misleading "could not read duration". Now detected before ffmpeg runs, with an
  accurate message.

## [0.1.0] — 2026-08-12

Initial release.

### Added

- Extractor chain: local file → scrape an embedded video from the page → yt-dlp fallback when
  installed (YouTube, Loom, Vimeo, and hundreds more).
- Timestamped contact sheet, with the grid and cell size adapting to the source's orientation
  and frame count.
- Transcript grouped under the frame each line was spoken over, gated on **measured loudness**
  so a digitally-silent audio track doesn't produce hallucinated captions.
- Layered configuration: built-in defaults → config file → CLI flags.
- `doctor` subcommand reporting required and optional dependencies.
- `Dockerfile` for Linux and machines without macOS.

[0.2.0]: https://github.com/anaidenko/claude-video-digest/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/anaidenko/claude-video-digest/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/anaidenko/claude-video-digest/releases/tag/v0.1.0
