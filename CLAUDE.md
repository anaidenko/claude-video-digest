# CLAUDE.md

Notes for working on this repo with Claude Code. This file only records what is easy to get
wrong — update it in the same commit as the fix, not after.

## The one rule

**A missing dependency must fail loudly, before any download or extraction happens** —
`ffmpeg`/`ffprobe`/`python3` are checked at the very top of the script. A check placed where a
dependency is first *used* (e.g. at the point `meta.json` gets written) means a missing
interpreter surfaces only after a download and full extraction already ran, leaving a
half-populated directory and an error that names the symptom, not the cause.

## Traps that already cost time here

- **A short-circuit (`[ cond ] && cmd`) as the LAST statement of the script becomes the exit
  code.** Hit this for real writing the output-summary block: `[ "$OUTPUT_IS_TEMP" -eq 1 ] &&
  printf '...'` was the final line, and on a persistent `--output` (the false branch) the whole
  script exited 1 despite every prior step succeeding — no error printed, everything correct on
  disk, only `$?` lying. Fixed with a real `if`, plus an explicit `exit 0` as a backstop. The
  same short-circuit is completely safe mid-script (several exist above it); it is specifically
  dangerous as the last line of the script, or of the `EXIT` trap (`cleanup()` has the same
  issue and is guarded the same way).
- **`exit` inside `$(...)` only kills the subshell.** `find_dir()` is captured with
  `x="$(find_dir ...)"`; if it used `die`/`exit` on an ambiguous match, the caller would see a
  plain non-zero, take the "not found" branch, and the script would carry on to completion with
  exit 0 — silently defeating the archived-directory guard and the cache-reuse lookup. `find_dir`
  instead returns 0/1/2 and the *caller* dies at the top level.
- **A pipe closing early inverts a capability probe into a false negative.**
  `ffmpeg -filters | grep -q ' drawtext '` reports "missing" on a build that has it: `grep -q`
  exits at the first match, `ffmpeg` dies of SIGPIPE, and `pipefail` promotes that into the
  branch behaving as if nothing matched. Fixed by capturing the full output first, then
  matching against the string. Nothing errors when this goes wrong — it just silently takes the
  degraded path.
- **`ffmpeg` needs `-y -nostdin` on every invocation.** Without them, a second run against an
  existing output path can block on `Overwrite? [y/N]` — a hang, not an error, in whatever ran
  the tool non-interactively.
- **`mpdecimate` is a silent no-op without `-fps_mode vfr`.** ffmpeg re-duplicates the frames the
  filter just dropped to hold a constant output rate, so dedupe appears to run and does nothing.
  Verified with a negative control: a clip where every sampled frame differs must produce the
  same frame count with and without `--no-dedupe` — if it doesn't, this is why.
- **A URL-derived id must be slugified; a local-file-derived id must be strictly validated —
  not the same rule for both.** The id is the cache-directory key, globbed verbatim on lookup,
  so it must never be silently rewritten *after* first use (that would break cache reuse for a
  value already on disk). But an arbitrary URL's last path segment can contain colons, spaces,
  percent-encoding — ordinary and not a sign anything is wrong (a Wikimedia `File:x.ogv` page
  path, for instance) — so rejecting it outright makes the tool fail on ordinary URLs. Slugifying
  a URL-derived id *before* it's ever written to disk is safe and necessary; a local file's
  basename is the user's to rename, so a genuinely hostile byte there is surfaced instead.
- **`drawtext` (timestamp labels on the contact sheet) needs `libfreetype`, and not every ffmpeg
  build has it — including some official Debian images.** The tool degrades to an unlabelled
  sheet rather than failing; `doctor` reports which case you're in. Don't assume any particular
  base image ships it; check.
- **Contact-sheet cell size is budgeted by AREA, not width.** A width cap punishes landscape
  sources far harder than portrait ones at the same cap — equal *area* gives both orientations
  the same pixel budget to render text with.
- **`drawtext` runs before the tile filter scales the frame down**, so its `fontsize` must be
  computed in *source* pixels (desired sheet-pixel size × downscale factor), not sheet pixels
  directly — reading it as sheet-pixel size once produced a label large enough to cover the
  frame it was labelling.
- **An `EXIT` trap's return value becomes the script's own exit code.** `cleanup()` must end
  with an explicit `return 0`; a trailing short-circuit there fails the whole run on a
  successful cache-hit path (nothing to clean up → the test is false → exit 1).
- **`VAR="${2:-}"; shift 2` only guards the expansion, not the shift.** If `$1` is the last
  argument (a flag typo'd at the end of the command, e.g. `... --ticket`), `${2:-}` happily
  expands to empty — but `shift 2` with a single argument left still fails, and `set -e` kills
  the script with **no error message at all**. Every value-taking flag now checks `[ $# -ge 2 ]`
  before consuming, with a real `die "$1 needs a value"`.
- **An argument pre-scan that matches a literal flag string anywhere in `$@` misreads other
  flags' values.** The `--config` pre-scan (needed before the main parse loop, since config
  values must load before CLI flags can override them) originally checked every token for
  equality with `--config` — so `--title --config --output /x` read `--output` as the config
  path. The pre-scan has to walk the same value-taking-flag structure as the main loop and skip
  each flag's own argument, not just look for one literal string.
- **A "discarded temp dir" comment is not the same as code that discards it.** `--no-frames`
  still extracts frames (to build the sheet) into a `mktemp -d`, with a comment saying it's
  "discarded after" — nothing did. It leaked one directory of JPEGs into the OS temp dir per
  run. Fixed the same way as the other scratch dirs: tracked in a variable, removed in
  `cleanup()`. A comment describing cleanup that hasn't been wired up reads exactly like real
  cleanup on a skim.
- **An explicit `--max-frames` was silently ignored on short clips.** The auto-derived budget
  is clamped by `MIN_INTERVAL` (so it never asks for more frames than the clip has distinct
  seconds), and that same clamp used to apply even when the caller had explicitly overridden
  the budget — so `--max-frames 40` on a 13.7s clip still produced 14 frames, with no error and
  no indication the flag hadn't been honoured. **Real cost, not theoretical**: a triage session
  read a sparse sheet, missed a transient frame the clamp had quietly excluded from even the
  explicit request, and wrote a wrong conclusion into a report before re-extracting denser and
  finding the real explanation. Fixed by skipping the clamp entirely when `MAX_FRAMES` is set —
  an explicit ask beats a heuristic. Verified in both directions: 40 with the flag (now yields
  up to 40), unchanged with no flag (negative control).
- **`find_config_file()` picks ONE file, it does not merge.** `--config` beats a local
  `.video-digest.json` beats `~/.config/video-digest/config.json` — first match wins, full stop.
  A project-local config file fully shadows the user-wide one rather than overlaying it, so a
  key set only in `~/.config/` silently stops applying the moment a directory gets its own
  `.video-digest.json`. Documenting this as "layered, later wins" (an easy assumption — it's how
  most tools' config precedence works) was wrong and shipped in README once already; re-check
  `find_config_file()` itself before describing the precedence anywhere.
- **`--force` and re-extraction are two different things, and conflating them wastes a
  re-download.** A prior version of this tool (the one this was extracted from) tied
  re-extraction to `--force`, which also re-downloads — so trying a higher `--max-frames` on an
  already-cached clip meant re-fetching an unchanged video just to get denser frames. **Not a
  bug here**: this script's cache-hit branch only ever sets `SOURCE_MP4`; frame extraction runs
  unconditionally afterward using whatever parameters were passed on *this* invocation,
  regardless of whether the download was fresh or reused. Verified: `--max-frames 10` then
  `--max-frames 40` on the same cached clip correctly produced 11 then 28 frames, no `--force`
  needed. Recorded here so nobody "fixes" this into the other tool's behaviour by mistake.

## Security notes

- **The scraper is a bounded SSRF surface, not a closed one.** Given a URL, it fetches the page
  and then follows a *second* URL found in that page's own content (the embedded `.mp4`) — so
  the page, not the user, has a say in what gets requested next, and `curl -L` means a redirect
  chain can retarget the request even from an initially-external URL. Mitigations in place:
  `--proto '=https,http'` (no `file://`/`gopher://` etc.), `--max-redirs 3`, and the resolved
  host is printed before downloading so a pivot is visible rather than silent. None of this
  closes the hole — a CLI tool that fetches a URL you hand it has some irreducible version of
  this risk — it just bounds and surfaces it. README says so explicitly; don't let that caveat
  quietly disappear in a future edit.
- **A share link can 200 with an HTML page instead of a video** — expired link, login wall,
  moved content. Downloaded and handed to ffmpeg as if it were the real thing, this used to
  surface as "could not read duration — is this a video file?", which blames the wrong layer.
  A magic-byte check (`<html`/`<!doctype html` in the first bytes) now catches the common case
  before ffmpeg runs, with a message that names what actually happened.

## Design decisions that look arbitrary and aren't

- **Frame budget scales with duration** (`~1 per secondsPerFrame`, floored and capped) rather
  than being a flat number — a fixed count is fine for a short clip and steps straight over the
  action on a long one.
- **First and last frame are always kept**, regardless of the dedupe/budget math — the opening
  state and the outcome are usually the two frames a reader actually needs, and even spacing
  reliably drops the tail.
- **A missing `whisper`/`yt-dlp`/`curl` degrades gracefully** (no transcript / no fallback
  extractor / URL inputs refused) rather than failing the whole run — only `ffmpeg`, `ffprobe`
  and `python3` are hard requirements, checked up front.
- **Output defaults to the OS temp directory, not the current directory.** Writing untracked
  files into a stranger's project by default would be rude; a persistent location is opt-in via
  `--output` / config, and that's also what `keepSource: auto` keys off.

## Known gap

**Droplr is verified** — but it needed a code change, and the reason generalises.

The original extractor only matched URLs ending in a video extension, which was enough for
Zight/CloudApp. Droplr's page embeds **no such URL at all**: the video lives in an `og:video`
meta tag pointing at `cdn-std.droplr.net/files/acc_NNN/<id>` — no extension, so every
extension-based pattern misses it, and yt-dlp doesn't support the host either, so the run died
with "Unsupported URL" despite the video being one meta tag away.

Fixed by falling back to `og:video` / `og:video:secure_url` / `twitter:player:stream` meta tags
when no extension-matched URL is found. Verified against three separate live `d.pr/v/` links.

⚠️ **The lesson: "same shape, should work" was wrong, and only running it showed that.** Before
this, both README and this file said Droplr was "expected to work — same page shape as Zight".
The page shape was similar; the URL shape was not. If another host is ever added to the claimed
list, run it, don't reason about it.
