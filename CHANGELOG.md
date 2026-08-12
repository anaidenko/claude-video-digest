# Changelog

Notable changes per release. Dates are UTC.

## [Unreleased]

### Added

- **Droplr support, verified against live links.** The extractor now falls back to `og:video` /
  `og:video:secure_url` / `twitter:player:stream` meta tags when no URL on the page ends in a
  video extension. Droplr serves `cdn-std.droplr.net/files/acc_NNN/<id>` — no extension at all —
  so every extension-based pattern missed it, and yt-dlp doesn't support the host either. This
  also makes the scraper work on any host that advertises its video through Open Graph.

### Changed

- README restructured: demo and usage examples first, comparison with other tools moved below
  the practical sections.
- `docs/example-output/` now carries real output from two runs — a contact sheet from a clip
  with no narration, and a frame-grouped transcript from a narrated one — since a single
  screenshot only demonstrated half of what the tool does.

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

[Unreleased]: https://github.com/anaidenko/claude-video-digest/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/anaidenko/claude-video-digest/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/anaidenko/claude-video-digest/releases/tag/v0.1.0
