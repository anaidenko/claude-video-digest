# Contributing

Bug reports and patches are welcome. The project is small on purpose — one bash script plus two
small Python helpers, no build step, no package to install.

## Running it

There is no test suite yet (see "Where help is most useful"). What exists is a set of checks
that have each caught a real bug, and any change should run through them:

```bash
./scripts/video-digest.sh doctor          # dependencies + the drawtext capability probe
shellcheck scripts/video-digest.sh        # clean except SC2329 (cleanup() is invoked via trap)
python3 -m py_compile scripts/lib/*.py
```

Then, against a throwaway clip:

```bash
ffmpeg -f lavfi -i "testsrc=duration=10:rate=2:size=320x240" /tmp/clip.mp4
./scripts/video-digest.sh /tmp/clip.mp4 --output /tmp/vd-out
```

## Checks that have each caught a real bug

Worth running for anything touching extraction, argument parsing, or the output path:

| Check | Why |
| --- | --- |
| **Run it twice** | Interactive prompts and cache bugs only appear on the second run — the first one has nothing to overwrite. |
| **Dedupe negative control** | On a clip where every frame differs, `--no-dedupe` and the default must produce the *same* count. If they differ, `-fps_mode vfr` is missing and dedupe is silently a no-op. |
| **Both transcript branches** | A silent clip must skip transcription; a narrated one must transcribe. A gate that always skips looks identical to a working one on silent input. |
| **Check the exit code, not the output** | Several bugs here printed a perfect summary and still exited 1. `echo "EXIT=$?"` immediately, and don't end the pipeline with `grep -c`. |
| **Check the artifact, not the log line** | Count the files on disk. A summary line saying "10 frames" is not evidence that ten frames exist. |

## The one rule

**A missing dependency must fail loudly, before any download or extraction happens.** Checks for
`ffmpeg`, `ffprobe` and `python3` sit at the top of the script for exactly this reason: a check
placed where a dependency is first *used* means the failure surfaces after a download and a full
extraction, leaving a half-populated directory and an error naming the symptom instead of the
cause. Please keep new dependencies inside that constraint — or make them genuinely optional and
degrade, like `whisper` and `yt-dlp` do.

## Before you conclude something works

[CLAUDE.md](CLAUDE.md) is this repo's record of things that looked right and weren't — a
short-circuit that ate an exit code, a capability probe that reported a false negative under
`pipefail`, a "discarded" temp dir that nothing discarded, and a host whose support was
"expected, same page shape" until running it proved otherwise. It's worth a read before
debugging anything here, and worth an entry in the same commit as your fix if you find another.

## Where help is most useful

- **Windows.** Untested, deliberately unclaimed. It's a bash script, so it needs WSL or Git
  Bash; nobody has confirmed either. A report either way would let the README say something
  definite.
- **More share hosts.** The scraper handles a page with an embedded video URL or an `og:video`
  meta tag, which covers Zight, CloudApp and Droplr. If your host isn't picked up, an issue with
  the link (or the page's `<meta>` tags, if the link is private) is enough to add it. ⚠️ Please
  don't add a host to the README's verified list without running it against a live link —
  Droplr was listed as "expected to work" on exactly that reasoning and turned out to need a
  code change.
- **A real test suite.** The checks above are run by hand today. Making them a script would be a
  genuine improvement.

## Releases

The version in `.claude-plugin/plugin.json` is the single source of truth — the plugin cache
keys on it, so an unbumped version means updates never reach anyone. Tag with
`git push --follow-tags` (a bare `--tags` pushes the tag without the commits behind it).
