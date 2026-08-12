#!/usr/bin/env python3
"""Read a video-digest JSON config file and print shell VAR=value assignments.

The shell script `eval`s this output, so every value printed here must be a
safe shell assignment — quoting is done with shlex.quote, and unknown keys
are rejected rather than silently accepted (a typo'd config key should be
loud, not ignored).

Usage: read-config.py <config.json>
"""

import json
import shlex
import sys

# Maps a config key to the shell variable it sets, and how to validate/coerce
# it. Keep this in sync with the defaults block at the top of video-digest.sh.
FIELDS = {
    "output": ("OUTPUT_DIR", str),
    "maxFrames": ("MAX_FRAMES", "int_or_null"),
    "secondsPerFrame": ("SECONDS_PER_FRAME", "number"),
    "framesFloor": ("FRAMES_FLOOR", "int"),
    "framesCeiling": ("FRAMES_CEILING", "int"),
    "minInterval": ("MIN_INTERVAL", "number"),
    "sampleFps": ("SAMPLE_FPS", "number"),
    "contactSheet": ("CONTACT_SHEET", "bool01"),
    "frames": ("WRITE_FRAMES", "bool01"),
    "transcript": ("TRANSCRIPT_MODE", "enum:auto,always,never"),
    "cellArea": ("CELL_AREA", "int"),
    "jpegQuality": ("JPEG_QUALITY", "int"),
    "dedupe": ("DEDUPE", "bool01"),
    "keepSource": ("KEEP_SOURCE", "enum:auto,always,never"),
    "silenceFloorDb": ("SILENCE_FLOOR", "number"),
    "whisperModel": ("WHISPER_MODEL", str),
}


def coerce(key, value, kind):
    if kind is str:
        return str(value)
    if kind == "int":
        return str(int(value))
    if kind == "int_or_null":
        return "" if value is None else str(int(value))
    if kind == "number":
        # Not just str(value): a non-numeric JSON value (e.g. a typo'd
        # string) would otherwise pass straight through as shell text and
        # silently change what the awk-based gates in video-digest.sh
        # compare against, rather than failing loudly here.
        return str(float(value))
    if kind == "bool01":
        return "1" if value else "0"
    if kind.startswith("enum:"):
        choices = kind[len("enum:") :].split(",")
        if value not in choices:
            raise ValueError(f"{key} must be one of {choices}, got {value!r}")
        return str(value)
    raise AssertionError(f"unhandled kind {kind}")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: read-config.py <config.json>", file=sys.stderr)
        return 2

    with open(sys.argv[1], encoding="utf-8") as fh:
        try:
            data = json.load(fh)
        except json.JSONDecodeError as exc:
            print(f"invalid JSON: {exc}", file=sys.stderr)
            return 1

    if not isinstance(data, dict):
        print("config file must contain a JSON object", file=sys.stderr)
        return 1

    lines = []
    for key, value in data.items():
        if key not in FIELDS:
            print(f"unknown config key: {key!r}", file=sys.stderr)
            return 1
        var, kind = FIELDS[key]
        try:
            shell_value = coerce(key, value, kind)
        except (ValueError, TypeError) as exc:
            print(f"config error for {key!r}: {exc}", file=sys.stderr)
            return 1
        lines.append(f"{var}={shlex.quote(shell_value)}")

    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
