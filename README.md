# claude-video-digest

Turns any video into a readable digest: a timestamped contact sheet, individual frames, and a
transcript grouped under the frame each line was spoken over. Claude can't play video — this
gives it something it can actually read.

![Example contact sheet](docs/hero-contact-sheet.jpg)

_Ten frames from a 33-second clip ([Big Buck Bunny](https://www.bigbuckbunny.org), CC BY 3.0),
each tile timestamped._

When the audio carries speech, the transcript arrives grouped under the frame each line was
spoken over — `—` marks a frame nobody spoke over:

```
frame_001.jpg  [0:00 - 0:05]
    (0:00) Now look into space to the moon and to the planets beyond, and we have vowed that we shall

frame_003.jpg  [0:09 - 0:13]
    —

frame_005.jpg  [0:17 - 0:21]
    (0:17) We have vowed that we shall not see space filled with weapons of mass destruction, but
```

A complete run — sheet, every frame, transcript, `meta.json` — is in
[`docs/example-output/`](docs/example-output/).

## Use

Inside Claude Code, just ask — the bundled skill runs it for you:

> watch this: https://d.pr/v/abc123
>
> what does the recording in this ticket show?

Or run it directly:

```bash
# A share link (Zight, CloudApp, Droplr) or any page with an embedded video
./scripts/video-digest.sh https://d.pr/v/abc123

# A local file
./scripts/video-digest.sh ./recording.mp4

# Keep the output instead of writing to the OS temp dir
./scripts/video-digest.sh <url> --output ./tmp-media

# More frames when a sequence matters (deletes, reordering, fast interactions)
./scripts/video-digest.sh <url> --max-frames 40 --no-dedupe

# Just the transcript, no images
./scripts/video-digest.sh <url> --no-contact-sheet --no-frames

# Label the output directory
./scripts/video-digest.sh <url> --ticket 1234 --title "login fails on submit"

# What's installed, what's missing
./scripts/video-digest.sh doctor
```

Each run produces a directory:

```
contact-sheet.jpg   read this first — one image, the whole clip
frames/             individual frames, full resolution
transcript.txt      only when the audio carries signal, grouped by frame
source.url          only for a URL input
meta.json           what was extracted, and the real recording date
source.mp4          kept or deleted depending on keepSource
```

## Install

```bash
claude plugin marketplace add anaidenko/claude-video-digest
claude plugin install claude-video-digest
```

**Required:**
- `ffmpeg`, `ffprobe` — frame extraction and the contact sheet
- `python3` — reads the config, writes `meta.json`, groups the transcript

**Optional** (each degrades cleanly rather than failing the run):
- `curl` — needed only for a URL input; a local file works without it
- `whisper` — transcription; missing it means no `transcript.txt`, not an error
- `yt-dlp` — sites beyond the built-in scraper (Loom, YouTube, Vimeo, hundreds more)

Run `./scripts/video-digest.sh doctor` to see exactly what's present. **Missing a required
dependency fails immediately** with an install hint (`brew install ffmpeg` / `apt-get install
ffmpeg`) — before any download or extraction runs, so a broken environment never produces a
half-written output directory.

### Update

```bash
claude plugin marketplace update anaidenko
claude plugin update claude-video-digest@anaidenko
```

Both steps matter: the first refreshes the cached marketplace listing from GitHub (skip it and
the second command still sees the old version); the second needs the `@anaidenko` suffix — the
bare plugin name fails with "not found" even though it's installed. `claude plugin list` shows
the new version right away, but the CLI itself says **restart to apply** — the running session
keeps the old code until you do.

### Uninstall

```bash
claude plugin uninstall claude-video-digest
claude plugin marketplace remove anaidenko
```

The second line is optional — only needed if you also want to stop tracking this marketplace
(e.g. before switching to the project-level install below, or if you registered it from a local
path by mistake and want to re-add it from GitHub).

### For a team — install with the project, not per developer

Commit this to the repo's `.claude/settings.json` and everyone who clones it gets the plugin,
with no per-developer install step:

```json
{
    "extraKnownMarketplaces": {
        "anaidenko": {
            "source": { "source": "github", "repo": "anaidenko/claude-video-digest" }
        }
    },
    "enabledPlugins": { "claude-video-digest@anaidenko": true }
}
```

Project-scoped plugins are versioned with the repo, survive git worktrees, and update through
the normal `claude plugin update`.

<details>
<summary>Why not <code>npx skills add</code>?</summary>

The [vercel-labs `skills`](https://github.com/vercel-labs/skills) CLI does discover this repo,
but it copies **only the skill directory** — you get `SKILL.md` and none of `scripts/`, which
lives at the repo root. The result installs cleanly and then cannot run. That CLI fits
text-only skills; this one ships an executable, so use one of the plugin installs above.

</details>

**Platforms:** macOS and Linux, both covered by the test suite (`npm test` for macOS's bash 3.2,
`npm run test:docker` for Debian's bash 5.x — both currently 47-48 assertions, green). Windows
untested — expected to work under Docker Desktop / WSL2, but not claimed until someone confirms
it. A `Dockerfile` is included:

```bash
docker build -t video-digest .
docker run --rm -v "$PWD:/work" -w /work video-digest <input> --output /work/out
```

## Configuration

Defaults work with no config. Exactly one config file is read, first match wins — it's a
choice, not a merge:

1. `--config <path>`, if given
2. `.video-digest.json` in the current working directory
3. `~/.config/video-digest/config.json`

CLI flags always win over whichever file was picked.

**"Current working directory" means the shell's `$PWD` when the script runs** — for the bundled
skill, that's wherever your Claude Code session is working, which varies run to run. Because a
project-local `.video-digest.json` fully shadows the `~/.config/` file rather than layering on
top of it, put settings you want to apply everywhere in `~/.config/video-digest/config.json`,
and only add a per-directory `.video-digest.json` when a specific project needs a different
full set of overrides.

| Key | Default | Example | What it does |
| --- | --- | --- | --- |
| `output` | OS temp dir | `"./tmp-media"` | where recordings are written |
| `maxFrames` | derived from duration | `40` | hard cap on frame count; overrides the derived budget entirely |
| `secondsPerFrame` | `5` | `3` | sampling density before floor/ceiling — one frame roughly every N seconds of clip |
| `framesFloor` | `10` | `5` | never derive fewer frames than this, even for a very short clip |
| `framesCeiling` | `30` | `100` | never derive more frames than this, even for a very long clip — raise it if you'd rather have a denser sheet than a capped one |
| `minInterval` | `1` | `0.5` | minimum seconds between kept frames |
| `sampleFps` | `2` | `4` | pre-dedupe sampling rate |
| `dedupe` | `true` | `false` | drop near-identical frames rather than sampling evenly |
| `contactSheet` | `true` | `false` | produce the contact sheet — independent of `frames`, either or both can be on |
| `frames` | `true` | `false` | write individual frame files — independent of `contactSheet`, either or both can be on |
| `transcript` | `"auto"` | `"always"` | `auto` gates on measured loudness; `always`; `never` |
| `keepSource` | `"auto"` | `"always"` | `auto` deletes in a temp dir, keeps in a persistent one |
| `silenceFloorDb` | `-60` | `-50` | loudness threshold for the `auto` transcript gate, in dBFS (always ≤ 0 — 0 is full scale, more negative is quieter); mean volume below this is treated as silence |
| `cellArea` | `480000` | `800000` | contact-sheet cell size budget, in pixels² |
| `jpegQuality` | `2` | `5` | ffmpeg `-q:v` for the sheet (lower is higher quality) |
| `whisperModel` | `"base"` | `"small"` | Whisper model size |

The commonly-changed keys have a CLI flag (`--max-frames`, `--transcript always`,
`--no-dedupe`, …); see `--help`. The rest are config-file-only tuning knobs.

## Why this exists

A couple of good video-watching tools already exist. Four things here are specific to this one —
each followed by what the others do instead:

- **A contact sheet labelled with timestamps.** One image places every event on the clip's
  timeline. _Elsewhere:_ one tool emits no sheet; the other tiles frames labelled with
  filenames, not times.
- **The transcript is grouped under the frame each line was spoken over**, so speech and screen
  state arrive already correlated. _Elsewhere:_ both keep them separate.
- **Transcription runs only when the audio carries signal**, measured as loudness. _Elsewhere:_
  both check only that an audio stream exists — so both will transcribe a digitally-silent
  screen recording (recorders write such a track when the mic is off) and return hallucinated
  captions.
- **The share hosts screen-recording tools actually use work**: Zight, CloudApp and Droplr, all
  verified against live links. _Elsewhere:_ both are built entirely on yt-dlp, which doesn't
  know those hosts, so neither can open such a link at all.

For everything yt-dlp *does* support, this falls back to it — so you get both.

## A note on fetching URLs

Given a URL, the scraper follows a second URL taken from *that page's own content* to find the
video — the page, not just you, has a say in what gets requested next. This is bounded (only
`http(s)`, redirects capped) but not eliminated: pointing this at a URL you don't trust carries
the same class of risk as `curl -L`. It's built for share links from people you're working
with, not arbitrary URLs.

## License

MIT — see [LICENSE](LICENSE). Contributions welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).
