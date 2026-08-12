# Example output

Real output from this tool, so you can see what it actually produces before running it yourself.

## `visual/` — a contact sheet, from a video with no narration

Source: a 33-second clip of [Big Buck Bunny](https://www.bigbuckbunny.org) (CC BY 3.0), fetched
via the yt-dlp fallback (this page isn't a Zight/CloudApp/Droplr link, so this also demonstrates
that path). No speech, so `transcript` was set to `never` — that's a normal, cheap mode when you
only want the visual overview.

- `contact-sheet.jpg` — ten tiles, each timestamped.
- `frames/` — three of the ten individual full-resolution frames (the sheet has all ten; this
  is a sample so the repo doesn't carry every frame from every example).
- `meta.json` — what the tool recorded about the run.

## `audio/` — a transcript grouped by frame, from a video WITH narration

Source: a 25-second clip combining a plain color background with a real narrated public-domain
speech (JFK, Rice University, 1962 — Wikimedia Commons). Built specifically to demonstrate the
frame-grouped transcript: `--no-contact-sheet` was passed (frames were still extracted, since
grouping needs them; the sheet itself just wasn't rendered for this example).

- `transcript.txt` — the actual output. Read it to see the format: each frame's time window,
  the speech that started within it, and `—` for frames nobody spoke over. The full unbroken
  transcript follows at the end.
- `meta.json` — what the tool recorded about the run, including the measured loudness
  (`-15.8 dB` — well above the silence gate, which is why transcription ran at all).

## Reproducing these

Both were generated with ordinary invocations, no special flags beyond what's shown above —
`--max-frames`, `--no-contact-sheet`, `--transcript`. Nothing here required editing the script.
