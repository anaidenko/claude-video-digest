---
name: watch-video
description: Watch a video — a screen recording, a demo clip, a bug report attachment, any video file or URL — by turning it into a readable contact sheet, frames and a transcript. Use whenever a message, ticket or comment carries a video link or path and the recording would answer a question — "watch this", "check the video", "what does the recording show", "what did they say". Handles phone and tablet captures in either orientation; transcribes only when the audio actually carries speech.
---

# watch-video

Claude cannot play video, but it can read images. This turns a recording into a contact sheet
plus individual frames, and transcribes the audio when there is any.

**Public share links need no auth** — most screen-recording tools (Zight, CloudApp, Loom,
Droplr, ...) produce links that are viewable without logging in. Fetch them directly; don't ask
the user for screenshots as a first move.

## Run it

```
./scripts/video-digest.sh <url|file.mp4> [--ticket <id>] [--title <text>]
```

Pass `--ticket` and `--title` when known — they name the output directory, which is how the
user navigates a persistent cache later. By default output goes to the OS temp directory; pass
`--output <dir>` for a persistent one.

Useful flags: `--max-frames N`, `--no-dedupe`, `--transcript never`, `--force`,
`--sample-fps N` (raises the pre-dedupe frame pool — combine with `--no-dedupe` when a
transient frame keeps getting dropped). Full list and current config: `--help`.

## Read it

1. **`contact-sheet.jpg` first** — one image, the whole clip, timestamps burned in. Usually
   enough on its own.
2. **`frames/frame_NNN.jpg`** only when the sheet leaves something unresolved.
3. **`transcript.txt`** when present. It is **grouped by frame**: each block gives the words
   spoken while that frame was on screen, so speech and screen state read together. A `—` means
   nobody spoke over that frame. The unbroken transcript follows at the end for a quick
   "what is this clip about".

The first and last frames are always included — the opening state and the outcome. "Last" is
the last frame that survived dedupe, not the end of the file, so it lands on real content
instead of a black screen a recorder can leave at the end.

Timestamps on the sheet are approximate (frame ordinal × interval, not true PTS) — fine for
navigating, not for quoting exact times.

Cell size adapts to the source, so tablet and phone recordings in either orientation both stay
legible. The frames in `frames/` are always full resolution — open one when the sheet's
downscale hides a detail.

## What to watch out for

- **The default frame count is a starting point, not a limit.** When the sheet doesn't settle
  the question, re-run with a higher `--max-frames` and say what was ambiguous. Do this before
  handing anything back to the user.
- **A sequence where a count changes (items deleted, created, or reordered) needs dense
  re-extraction before any conclusion goes into a report.** The default budget is tuned for
  "what is this clip about", not "what exactly happened, in what order". A real triage session
  read a sparse sheet as "a deleted item reappeared" — re-extracted at a much higher
  `--max-frames`, the same clip showed something else entirely (a second, different item was
  deleted; a transient loading state the sparse sheet had skipped explained the miscount). The
  wrong conclusion had already been written into a report before the density was raised. Treat
  any story involving a count as provisional until checked at higher density, not just when the
  sheet already looks ambiguous.
- **Dedupe can drop the exact frame that explains a discrepancy.** It keeps visually distinct
  frames, but a brief loading/transient state can look similar enough to the frame before or
  after it to get dropped. If a count or an order doesn't add up, re-run with `--no-dedupe` in
  addition to a higher `--max-frames`.
- **A missing `transcript.txt` usually means silence, not failure.** Screen recorders often
  write an empty audio track when the mic is off; the tool measures loudness and skips
  transcription below a threshold. The summary line says which happened.
- **The recording date is not necessarily today, or the date it was shared.** `meta.json`
  carries `recorded` and `recorded_source` — check them before assuming a recording reflects
  the current state of anything.
- **`archived/` (inside a persistent output dir) is the user's.** A recording moved there is
  resolved; the tool refuses to re-process it without `--force`. Don't move things in or out on
  the user's behalf.
- **`source.url` is a double-clickable shortcut** to the original, for when frames aren't
  enough. It exists only for a URL input — a local file has no url to record.
- Frames answer _what happened on screen_. They do not prove _why_ — confirm the mechanism
  elsewhere before reporting a cause.

## Dependencies

`ffmpeg` (with `libfreetype` for timestamps), `ffprobe` and `python3` are required and checked
up front. `curl` is needed only for a URL input, `whisper` only when the audio carries speech,
`yt-dlp` only for sites the built-in scraper can't resolve — all three degrade gracefully
without failing the run. See `./scripts/video-digest.sh doctor` for what's currently available.
