# claude-video-digest

Turns any video into a readable digest: a timestamped contact sheet, individual frames, and a
transcript grouped under the frame each line was spoken over. Claude can't play video — this
gives it something it can actually read.

![Example contact sheet](docs/example-contact-sheet.jpg)
_Nine frames from a 33-second public-domain clip ([Big Buck Bunny](https://www.bigbuckbunny.org),
CC BY 3.0), each labelled with its approximate timestamp._

## Why not just point Claude at a video-watching tool that already exists?

A couple of good ones do the general job. This one exists for what they don't:

- **Neither produces a timestamped contact sheet.** One emits no sheet at all; the other tiles
  frames labelled with filenames, not when they happened.
- **Neither ties the transcript to the frames.** You get speech and screen state as two separate
  things you have to correlate yourself.
- **Neither checks whether the audio actually has anything on it.** Both will run a transcriber
  over a digitally-silent track (screen recorders write one when the mic is off) and hand you
  hallucinated captions.
- **Neither handles the share hosts screen-recording tools actually use** — Zight, CloudApp,
  Droplr-style links — because both are built entirely on yt-dlp, which doesn't know those hosts.

This tool scrapes those hosts directly, and falls back to yt-dlp (if installed) for everything
yt-dlp does support — YouTube, Loom, Vimeo, and hundreds more. So it isn't a competing "let AI
watch video" tool; it's the one that also handles the recordings the others can't open.

## Install

As a Claude Code plugin:

```
/plugin marketplace add anaidenko/claude-video-digest
/plugin install claude-video-digest
```

Or run the script directly — it has no plugin-specific dependency:

```bash
git clone https://github.com/anaidenko/claude-video-digest.git
./claude-video-digest/scripts/video-digest.sh <url-or-file>
```

Check what's installed and what's missing:

```bash
./scripts/video-digest.sh doctor
```

**Required:** `ffmpeg`, `ffprobe`, `python3`. **Optional:** `curl` (only for a URL input),
`whisper` (transcription — skipped, not an error, without it), `yt-dlp` (sites the built-in
scraper can't resolve).

## Use

```bash
./scripts/video-digest.sh <url|file.mp4> [options]
```

The skill (`skills/watch-video/SKILL.md`) does this automatically inside Claude Code whenever a
video is relevant to what you're doing — you don't need to remember the command.

Output, per recording, in its own directory:

```
contact-sheet.jpg   read this first — one image, the whole clip
frames/              individual frames, full resolution
transcript.txt       only when the audio carries signal, grouped by frame
source.url           only for a URL input
meta.json            what was extracted and how
source.mp4            kept or deleted depending on keepSource (see below)
```

## Where output goes

By default, the **OS temp directory** — nothing lands in your project. Pass `--output <dir>` (or
set `"output"` in the config) to use a persistent directory instead, which is what makes caching
and a kept `source.mp4` worth anything. Re-running the same input reuses what's already there.

If the resolved output directory sits inside a git repo and isn't gitignored, the tool prints a
one-line suggestion — it never prompts. A tool Claude runs must not wait on a question no one is
there to answer.

## Configuration

Three layers, later wins: built-in defaults → config file → CLI flags. Config file is
`.video-digest.json` in the current directory, or `~/.config/video-digest/config.json`.

| Key | Default | What it does |
| --- | --- | --- |
| `output` | OS temp dir | where recordings are written |
| `maxFrames` | derived from duration | hard cap on frame count |
| `secondsPerFrame` | `4.5` | target sampling density before the floor/ceiling |
| `framesFloor` / `framesCeiling` | `10` / `30` | bounds on the derived frame count |
| `minInterval` | `1` | minimum seconds between kept frames |
| `sampleFps` | `2` | pre-dedupe sampling rate |
| `dedupe` | `true` | drop near-identical frames (scene-change based), not just evenly spaced |
| `contactSheet` | `true` | produce the tiled sheet |
| `frames` | `true` | write individual frame files |
| `transcript` | `"auto"` | `"auto"` gates on measured loudness, `"always"` forces it, `"never"` skips it |
| `keepSource` | `"auto"` | `"auto"` deletes in the temp-dir default, keeps in a persistent one |
| `silenceFloorDb` | `-60` | loudness threshold for the `"auto"` transcript gate |
| `cellArea` | `480000` | contact-sheet cell size budget, in pixels² (area, not width — see CLAUDE.md) |
| `jpegQuality` | `2` | ffmpeg `-q:v` for the sheet |
| `whisperModel` | `"base"` | Whisper model size |

Every CLI flag has the same name in kebab-case (`--max-frames`, `--transcript always`, ...); see
`--help` for the full list.

## Verified platforms

- **macOS** — native, no container needed.
- **Linux** — verified in `debian:bookworm-slim` via the included `Dockerfile`.
- **Windows** — not tested. Expected to work under Docker Desktop / WSL2; not claimed until
  someone runs it and reports back.

```bash
docker build -t video-digest .
docker run --rm -v "$PWD:/work" -w /work video-digest <input> --output /work/out
```

## License

MIT — see [LICENSE](LICENSE).
