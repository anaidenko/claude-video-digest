#!/usr/bin/env python3
"""Group Whisper segments under the frame each was spoken over.

Reading a flat transcript next to a contact sheet means pairing them by hand.
Grouped, a frame and the words spoken while it was on screen sit together, which
is the only reason the audio is worth transcribing at all.

Usage: group-transcript.py <whisper.json> <frame_times.txt> <duration> <out.txt>
"""

import json
import sys


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2

    whisper_json, times_file, duration_s, out_file = sys.argv[1:5]

    with open(whisper_json, encoding="utf-8") as fh:
        data = json.load(fh)

    segments = [
        {
            "start": float(s["start"]),
            "end": float(s["end"]),
            "text": " ".join(s["text"].split()),
        }
        for s in data.get("segments", [])
        if s.get("text", "").strip()
    ]

    with open(times_file, encoding="utf-8") as fh:
        frame_times = [float(line) for line in fh if line.strip()]

    duration = float(duration_s)

    if not frame_times:
        with open(out_file, "w", encoding="utf-8") as fh:
            fh.write(data.get("text", "").strip() + "\n")
        return 0

    # A frame's window runs from its own timestamp to the next frame's. A segment
    # belongs to the window it STARTS in — speech does not stop at frame
    # boundaries, and splitting a sentence across two windows leaves both halves
    # meaningless.
    windows = []
    for i, start in enumerate(frame_times):
        end = frame_times[i + 1] if i + 1 < len(frame_times) else max(duration, start)
        windows.append({"frame": i + 1, "start": start, "end": end, "texts": []})

    for seg in segments:
        placed = False
        for w in windows:
            if w["start"] <= seg["start"] < w["end"]:
                w["texts"].append(seg)
                placed = True
                break
        if not placed:
            # Starts before the first frame or after the last window's end.
            target = windows[0] if seg["start"] < windows[0]["start"] else windows[-1]
            target["texts"].append(seg)

    def clock(t: float) -> str:
        return f"{int(t) // 60:d}:{int(t) % 60:02d}"

    lines = [
        "Transcript grouped by frame.",
        "Each block covers the time that frame was on screen; a segment is filed",
        "under the frame it STARTS in, so sentences stay whole.",
        "",
    ]

    for w in windows:
        header = (
            f"frame_{w['frame']:03d}.jpg  [{clock(w['start'])} - {clock(w['end'])}]"
        )
        lines.append(header)
        if w["texts"]:
            for seg in w["texts"]:
                lines.append(f"    ({clock(seg['start'])}) {seg['text']}")
        else:
            lines.append("    —")
        lines.append("")

    lines.append("=" * 60)
    lines.append("Full transcript, unbroken:")
    lines.append("")
    full = data.get("text", "").strip()
    lines.append(full if full else "(empty)")
    lines.append("")

    with open(out_file, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))

    return 0


if __name__ == "__main__":
    sys.exit(main())
