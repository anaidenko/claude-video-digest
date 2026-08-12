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
