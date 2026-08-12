#!/usr/bin/env bash
# Test suite for video-digest.sh.
#
# Every case here corresponds to a bug that actually shipped and was found
# later — see CLAUDE.md. A test that has never failed for a real reason is
# usually testing the wrong thing.
#
#   ./test/run-tests.sh          # the suite
#   ./test/run-tests.sh --keep   # leave the scratch dir behind for inspection

set -uo pipefail # NOT -e: a failing assertion must record and continue

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$REPO_ROOT/scripts/video-digest.sh"

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

WORK="$(mktemp -d)"
cleanup() {
    if [ "$KEEP" -eq 1 ]; then
        printf '\nScratch dir kept: %s\n' "$WORK"
    else
        rm -rf "$WORK"
    fi
    return 0
}
trap cleanup EXIT

PASS=0
FAIL=0

ok() {
    PASS=$((PASS + 1))
    printf '  \033[32mok\033[0m   %s\n' "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf '  \033[31mFAIL\033[0m %s\n' "$1"
    [ -n "${2:-}" ] && printf '       %s\n' "$2"
}

# assert_eq <expected> <actual> <description>
assert_eq() {
    if [ "$1" = "$2" ]; then ok "$3"; else fail "$3" "expected '$1', got '$2'"; fi
}

frame_count() {
    find "$1" -name 'frame_*.jpg' 2>/dev/null | wc -l | tr -d ' '
}

need_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'test suite needs %s\n' "$1" >&2
        exit 2
    }
}

need_tool ffmpeg
need_tool ffprobe
need_tool python3

printf '\nvideo-digest test suite\n'
printf 'bash %s on %s\n\n' "${BASH_VERSION%%(*}" "$(uname -s)"

# --- fixtures --------------------------------------------------------------

printf 'building fixtures...\n'
# Every frame differs — the dedupe negative control depends on this.
ffmpeg -hide_banner -nostdin -y -loglevel error -f lavfi \
    -i "testsrc=duration=10:rate=2:size=320x240" "$WORK/moving.mp4"
# Long enough that the min-interval clamp (~duration/1) and an explicit
# --max-frames give unmistakably different answers — see the frame-budget test.
ffmpeg -hide_banner -nostdin -y -loglevel error -f lavfi \
    -i "testsrc=duration=30:rate=3:size=320x240" "$WORK/long.mp4"
# Completely static — mpdecimate should collapse it.
ffmpeg -hide_banner -nostdin -y -loglevel error -f lavfi \
    -i "color=c=blue:s=320x240:d=6:r=2" "$WORK/static.mp4"
# Has an audio track that is digitally silent — the silence gate's whole point.
ffmpeg -hide_banner -nostdin -y -loglevel error -f lavfi \
    -i "testsrc=duration=5:rate=2:size=320x240" -f lavfi -i "anullsrc=r=44100:cl=mono" \
    -shortest -c:a aac "$WORK/silent-audio.mp4"
# Not a video at all.
printf 'this is not a video\n' > "$WORK/notvideo.mp4"
# HTML masquerading as a video file.
printf '<!DOCTYPE html><html><body>login required</body></html>' > "$WORK/htmlpage.mp4"

# --- syntax and lint -------------------------------------------------------

printf '\nstatic checks\n'
if bash -n "$TOOL" 2>/dev/null; then ok "video-digest.sh parses"; else fail "video-digest.sh parses"; fi
for py in "$REPO_ROOT"/scripts/lib/*.py; do
    if python3 -m py_compile "$py" 2>/dev/null; then
        ok "$(basename "$py") compiles"
    else
        fail "$(basename "$py") compiles"
    fi
done
if command -v shellcheck >/dev/null 2>&1; then
    # SC2329: cleanup() is invoked via trap, which shellcheck cannot trace.
    if shellcheck -e SC2329 "$TOOL" >/dev/null 2>&1; then
        ok "shellcheck clean"
    else
        fail "shellcheck clean" "$(shellcheck -e SC2329 "$TOOL" 2>&1 | head -5)"
    fi
else
    printf '  skip shellcheck (not installed)\n'
fi

# --- basics ----------------------------------------------------------------

printf '\nbasics\n'
"$TOOL" doctor >/dev/null 2>&1
assert_eq 0 $? "doctor exits 0 when dependencies are present"

"$TOOL" --help >/dev/null 2>&1
assert_eq 0 $? "--help exits 0"

"$TOOL" >/dev/null 2>&1
assert_eq 1 $? "no arguments exits 1"

out="$("$TOOL" "$WORK/moving.mp4" --output "$WORK/basic" --title basic 2>&1)"
rc=$?
assert_eq 0 "$rc" "a local file processes successfully"
[ -s "$WORK/basic/videos/"*"-basic/contact-sheet.jpg" ] 2>/dev/null \
    && ok "contact sheet is written" || fail "contact sheet is written"
[ -s "$WORK/basic/videos/"*"-basic/meta.json" ] 2>/dev/null \
    && ok "meta.json is written" || fail "meta.json is written"
if python3 -c "import json,glob,sys; json.load(open(glob.glob('$WORK/basic/videos/*-basic/meta.json')[0]))" 2>/dev/null; then
    ok "meta.json is valid JSON"
else
    fail "meta.json is valid JSON"
fi

# --- exit codes ------------------------------------------------------------
# A run that printed a perfect summary and still exited 1 shipped twice here:
# a short-circuit as the script's last statement, and an EXIT trap whose own
# return value became the exit code.

printf '\nexit codes\n'
"$TOOL" "$WORK/moving.mp4" --output "$WORK/exit-persistent" >/dev/null 2>&1
assert_eq 0 $? "exits 0 with a persistent --output (short-circuit-as-last-statement regression)"

"$TOOL" "$WORK/moving.mp4" >/dev/null 2>&1
assert_eq 0 $? "exits 0 with the temp-dir default"

"$TOOL" "$WORK/moving.mp4" --output "$WORK/exit-cached" --title cached >/dev/null 2>&1
"$TOOL" "$WORK/moving.mp4" --output "$WORK/exit-cached" --title cached >/dev/null 2>&1
assert_eq 0 $? "exits 0 on a cache hit (EXIT-trap regression)"

# --- argument validation ---------------------------------------------------
# `VAR="${2:-}"; shift 2` guards the expansion but not the shift: a flag with
# nothing after it used to die silently with no message.

printf '\nargument validation\n'
for flag in --ticket --title --output --max-frames --transcript --keep-source; do
    err="$("$TOOL" "$WORK/moving.mp4" "$flag" 2>&1)"
    rc=$?
    if [ "$rc" -eq 1 ] && printf '%s' "$err" | grep -q "needs a value"; then
        ok "$flag with no value fails with a message"
    else
        fail "$flag with no value fails with a message" "rc=$rc out='$err'"
    fi
done

"$TOOL" "$WORK/moving.mp4" --output "$WORK/x" --min-interval 0 >/dev/null 2>&1
assert_eq 1 $? "--min-interval 0 is rejected"
"$TOOL" "$WORK/moving.mp4" --output "$WORK/x" --sample-fps 0 >/dev/null 2>&1
assert_eq 1 $? "--sample-fps 0 is rejected"
"$TOOL" "$WORK/moving.mp4" --output "$WORK/x" --max-frames abc >/dev/null 2>&1
assert_eq 1 $? "--max-frames with a non-integer is rejected"
"$TOOL" "$WORK/moving.mp4" --output "$WORK/x" --transcript bogus >/dev/null 2>&1
assert_eq 1 $? "--transcript with an invalid mode is rejected"
"$TOOL" --nonexistent-flag >/dev/null 2>&1
assert_eq 1 $? "an unknown flag is rejected"
"$TOOL" "$WORK/does-not-exist.mp4" >/dev/null 2>&1
assert_eq 1 $? "a nonexistent path is rejected"
"$TOOL" "$WORK/notvideo.mp4" --output "$WORK/x" >/dev/null 2>&1
assert_eq 1 $? "a non-video file is rejected"

# The --config pre-scan used to match the literal string anywhere in argv.
printf '{"maxFrames": 3}\n' > "$WORK/cfg.json"
"$TOOL" "$WORK/moving.mp4" --title "order test" --config "$WORK/cfg.json" --output "$WORK/order" >/dev/null 2>&1
assert_eq 0 $? "--config surrounded by other flags is read correctly"

# --- dedupe ----------------------------------------------------------------
# Without -fps_mode vfr, mpdecimate is a silent no-op: ffmpeg re-duplicates
# the frames it just dropped. The control is a clip where nothing CAN be
# dropped, so both paths must agree.

printf '\ndedupe\n'
"$TOOL" "$WORK/moving.mp4" --output "$WORK/dd-on" --no-contact-sheet --transcript never --max-frames 100 >/dev/null 2>&1
"$TOOL" "$WORK/moving.mp4" --output "$WORK/dd-off" --no-dedupe --no-contact-sheet --transcript never --max-frames 100 >/dev/null 2>&1
on="$(frame_count "$WORK/dd-on")"
off="$(frame_count "$WORK/dd-off")"
assert_eq "$off" "$on" "negative control: an all-different clip loses nothing to dedupe ($on vs $off)"
[ "$on" -gt 1 ] && ok "the control actually produced frames ($on)" || fail "the control actually produced frames" "got $on"

"$TOOL" "$WORK/static.mp4" --output "$WORK/dd-static" --no-contact-sheet --transcript never >/dev/null 2>&1
static_n="$(frame_count "$WORK/dd-static")"
[ "$static_n" -le 2 ] && ok "a static clip collapses to almost nothing ($static_n)" \
    || fail "a static clip collapses to almost nothing" "got $static_n"

# --- frame budget ----------------------------------------------------------
# An explicit --max-frames used to be silently clamped back down by the
# min-interval heuristic it was meant to override.

printf '\nframe budget\n'
# ⚠️ This assertion only discriminates when the request EXCEEDS the clamp.
# The clamp is `duration / min-interval`, so on a 10s clip it sits at 10 and
# a `--max-frames 18` check passes with or without the bug — which is exactly
# what happened when the regression was planted to validate this suite, twice.
# Here: 10s of source at --min-interval 1 clamps to 10; asking for 20 must
# therefore yield ~20 if the override works, and ~10 if it doesn't.
"$TOOL" "$WORK/moving.mp4" --output "$WORK/budget-hi" --no-contact-sheet --transcript never \
    --min-interval 1 --max-frames 20 --sample-fps 4 >/dev/null 2>&1
hi="$(frame_count "$WORK/budget-hi")"
[ "$hi" -ge 15 ] && ok "an explicit --max-frames beats the min-interval clamp ($hi frames)" \
    || fail "an explicit --max-frames beats the min-interval clamp" "got $hi, expected >=15 (clamped would be ~10)"

"$TOOL" "$WORK/moving.mp4" --output "$WORK/budget-default" --no-contact-sheet --transcript never >/dev/null 2>&1
def="$(frame_count "$WORK/budget-default")"
[ "$def" -ge 1 ] && [ "$def" -le 30 ] && ok "the default budget stays within its bounds ($def)" \
    || fail "the default budget stays within its bounds" "got $def"

# --- transcript gate -------------------------------------------------------
# Both competitors check that an audio STREAM exists; the point here is that
# a present-but-silent track must not reach the transcriber.

printf '\ntranscript gate\n'
out="$("$TOOL" "$WORK/silent-audio.mp4" --output "$WORK/tr-silent" --no-contact-sheet 2>&1)"
if printf '%s' "$out" | grep -qi "silent track"; then
    ok "a digitally-silent audio track skips transcription"
else
    fail "a digitally-silent audio track skips transcription" "$(printf '%s' "$out" | grep -i transcript || echo "$out" | tail -2)"
fi

out="$("$TOOL" "$WORK/moving.mp4" --output "$WORK/tr-none" --no-contact-sheet 2>&1)"
if printf '%s' "$out" | grep -qi "no audio track"; then
    ok "a clip with no audio track skips transcription"
else
    fail "a clip with no audio track skips transcription" "$(printf '%s' "$out" | grep -i transcript)"
fi

out="$("$TOOL" "$WORK/moving.mp4" --output "$WORK/tr-never" --no-contact-sheet --transcript never 2>&1)"
printf '%s' "$out" | grep -qi "transcript: never" \
    && ok "--transcript never is honoured" || fail "--transcript never is honoured"

# --- output location and keepSource ---------------------------------------

printf '\noutput location\n'
"$TOOL" "$WORK/moving.mp4" --output "$WORK/keep-persist" --title kp --transcript never >/dev/null 2>&1
if [ -f "$WORK/keep-persist/videos/"*"-kp/source.mp4" ] 2>/dev/null; then
    ok "keepSource auto keeps the video in a persistent output dir"
else
    fail "keepSource auto keeps the video in a persistent output dir"
fi

"$TOOL" "$WORK/moving.mp4" --output "$WORK/keep-never" --title kn --keep-source never --transcript never >/dev/null 2>&1
if [ -f "$WORK/keep-never/videos/"*"-kn/source.mp4" ] 2>/dev/null; then
    fail "--keep-source never deletes the video"
else
    ok "--keep-source never deletes the video"
fi

# --no-frames used to leak a temp directory of JPEGs on every run.
before="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'tmp.*' 2>/dev/null | wc -l | tr -d ' ')"
for _ in 1 2 3; do
    "$TOOL" "$WORK/moving.mp4" --output "$WORK/noframes" --no-frames --transcript never >/dev/null 2>&1
done
after="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'tmp.*' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$before" "$after" "--no-frames leaves no temp directories behind (3 runs)"

# --- cache and guards ------------------------------------------------------

printf '\ncache and guards\n'
"$TOOL" "$WORK/moving.mp4" --output "$WORK/cache" --title cc --transcript never >/dev/null 2>&1
out="$("$TOOL" "$WORK/moving.mp4" --output "$WORK/cache" --title cc --transcript never 2>&1)"
printf '%s' "$out" | grep -qi "reusing cached" \
    && ok "a second run reuses the cached download" || fail "a second run reuses the cached download"

# Extraction parameters must still apply on a cache hit.
"$TOOL" "$WORK/moving.mp4" --output "$WORK/cache" --title cc --transcript never --max-frames 18 >/dev/null 2>&1
n="$(frame_count "$WORK/cache")"
[ "$n" -gt 10 ] && ok "extraction re-runs with new parameters on a cache hit ($n)" \
    || fail "extraction re-runs with new parameters on a cache hit" "got $n"

dir="$(find "$WORK/cache/videos" -maxdepth 1 -type d -name '*-cc' | head -1)"
mkdir -p "$WORK/cache/videos/archived"
mv "$dir" "$WORK/cache/videos/archived/"
"$TOOL" "$WORK/moving.mp4" --output "$WORK/cache" --title cc --transcript never >/dev/null 2>&1
assert_eq 1 $? "an archived recording is refused"
"$TOOL" "$WORK/moving.mp4" --output "$WORK/cache" --title cc --transcript never --force >/dev/null 2>&1
assert_eq 0 $? "--force overrides the archived guard"

# --- config file -----------------------------------------------------------

printf '\nconfig file\n'
printf '{"maxFrames": 4, "transcript": "never"}\n' > "$WORK/good.json"
"$TOOL" "$WORK/moving.mp4" --output "$WORK/cfg-good" --config "$WORK/good.json" --no-contact-sheet >/dev/null 2>&1
assert_eq 0 $? "a valid config file is accepted"

printf '{"bogusKey": 1}\n' > "$WORK/bad-key.json"
"$TOOL" "$WORK/moving.mp4" --output "$WORK/x" --config "$WORK/bad-key.json" >/dev/null 2>&1
assert_eq 1 $? "an unknown config key is rejected"

printf '{not json\n' > "$WORK/malformed.json"
"$TOOL" "$WORK/moving.mp4" --output "$WORK/x" --config "$WORK/malformed.json" >/dev/null 2>&1
assert_eq 1 $? "malformed config JSON is rejected"

printf '{"silenceFloorDb": "notanumber"}\n' > "$WORK/bad-num.json"
"$TOOL" "$WORK/moving.mp4" --output "$WORK/x" --config "$WORK/bad-num.json" >/dev/null 2>&1
assert_eq 1 $? "a non-numeric value in a numeric config field is rejected"

# A config file must not be able to execute anything through the eval in
# load_config_file(). ⚠️ The payload needs a SPACE followed by a command —
# `VAR=x"; cmd; "` with no space is a single shell WORD (quotes are just
# quote-removal inside it) and evals harmlessly, which is what a first version
# of this exact test used, passed, and proved nothing. `VAR=x; cmd #` is the
# one that actually breaks unquoted eval tokenization (verified: it silently
# created a marker file when read-config.py's shlex.quote() was removed).
python3 -c "import json; json.dump({'whisperModel': 'base; touch $WORK/PWNED #'}, open('$WORK/evil.json', 'w'))"
rm -f "$WORK/PWNED"
"$TOOL" "$WORK/moving.mp4" --output "$WORK/x" --config "$WORK/evil.json" --transcript never >/dev/null 2>&1
if [ -e "$WORK/PWNED" ]; then
    fail "a config value cannot execute shell commands" "PWNED marker was created"
else
    ok "a config value cannot execute shell commands"
fi

# --- summary ---------------------------------------------------------------

printf '\n%s passed, %s failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
