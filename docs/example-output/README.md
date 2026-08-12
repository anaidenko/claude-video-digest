# Example output

One real run, unedited — exactly the directory layout the tool produces.

Source: a 25-second clip pairing a plain background with a real narrated public-domain speech
(JFK at Rice University, 1962 — Wikimedia Commons), chosen so a single example can show every
part of the output at once: the sheet, the frames, and a transcript with real speech in it.

| File | |
| --- | --- |
| `contact-sheet.jpg` | The whole clip as one image, each tile timestamped. Read this first. |
| `frames/` | Every extracted frame, full resolution — for when the sheet's downscale hides a detail. |
| `transcript.txt` | Grouped by frame: each block holds the speech that started while that frame was on screen, with `—` where nobody spoke. The unbroken transcript follows at the end. |
| `meta.json` | What was extracted and how — frame counts before and after thinning, the measured loudness (`-15.8 dB`, well above the silence gate, which is why transcription ran), and where the recording date came from. |

A run from a URL also writes `source.url` (a double-clickable shortcut back to the original) and,
depending on `keepSource`, `source.mp4`. Neither is included here — the first is meaningless
without the original link, and the second is just the input video.

Generated with an ordinary invocation, no special flags:

```bash
./scripts/video-digest.sh <clip> --output <dir> --title "narrated demo" --max-frames 6
```
