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
# Just over the 15-minute line where a long-video warning starts. Tiny and
# static, so it encodes and digests in about a second.
ffmpeg -hide_banner -nostdin -y -loglevel error -f lavfi \
    -i "color=c=blue:s=64x48:r=1:d=960" "$WORK/long16.mp4"

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

# --- URL inputs: stubbed curl and yt-dlp --------------------------------------
# Every URL case runs against stand-ins put first on PATH: video-digest.sh does
# not reset PATH, so they shadow the real tools. The suite must never reach the
# network. The curl stub knows only *.fixture.test and YouTube URLs and fails
# on anything else, and every case that expects a call asserts the stub's log,
# so a real curl or yt-dlp answering instead shows up as a failure.

printf '\nURL harness\n'
STUB_BIN="$WORK/stub-bin"
STUB_LOG="$WORK/stub-log"
# ffmpeg, ffprobe, python3 and the curl stub, but no yt-dlp. On Homebrew all of
# them share /opt/homebrew/bin, so absence needs a directory of its own.
NOYT_BIN="$WORK/noyt-bin"
NOYT_PATH="$NOYT_BIN:/usr/bin:/bin"
mkdir -p "$STUB_BIN" "$STUB_LOG" "$NOYT_BIN"
STUB_CLIP="$WORK/moving.mp4"
STUB_META="$WORK/stub-meta.json"
export STUB_LOG STUB_CLIP STUB_META
printf '{"title": "Stub Video Title", "upload_date": "20240102", "duration": 10.0}\n' > "$STUB_META"

cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
# curl stand-in: serves fixture pages by URL. Never touches the network and
# never reads stdin.
printf '%s\n' "$*" >> "$STUB_LOG/curl.log"
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --proto|--max-redirs|--max-time) shift 2 ;;
        http://*|https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
[ -n "$out" ] || { echo "curl stub: no -o given" >&2; exit 2; }
case "$url" in
    https://cdn.fixture.test/*.mp4*)
        cp "$STUB_CLIP" "$out" ;;
    https://player.fixture.test/* | https://www.youtube.com/embed/*)
        printf '<!DOCTYPE html><html><body>a video player</body></html>\n' > "$out" ;;
    https://share.fixture.test/clip/*)
        printf '<html><body><video src="https://cdn.fixture.test/files/2025-03-04%%20demo.mp4?source=viewer"></video></body></html>\n' > "$out" ;;
    https://share.fixture.test/player/*)
        printf '<html><head><meta property="og:video:url" content="https://player.fixture.test/video/76979871?h=8c4e"></head></html>\n' > "$out" ;;
    https://share.fixture.test/novideo/*)
        printf '<html><body>no video here</body></html>\n' > "$out" ;;
    https://share.fixture.test/thumbonly/*)
        printf '<html><body><video autoplay muted src="https://cdn.fixture.test/sessions/thumbnails/abc-00001.mp4"></video></body></html>\n' > "$out" ;;
    https://share.fixture.test/thumbfirst/*)
        printf '<html><body><video src="https://cdn.fixture.test/sessions/thumbnails/abc-00001.mp4"></video><a href="https://cdn.fixture.test/files/2025-06-07-real.mp4">download</a></body></html>\n' > "$out" ;;
    *youtube.com/* | *youtu.be/* | *youtube-nocookie.com/*)
        printf '<html><head><meta property="og:video:url" content="https://www.youtube.com/embed/jNQXAC9IVRw"></head></html>\n' > "$out" ;;
    *)
        printf 'curl stub: no fixture for %s\n' "$url" >&2
        exit 6 ;;
esac
exit 0
STUB

cat > "$STUB_BIN/yt-dlp" <<'STUB'
#!/usr/bin/env bash
# yt-dlp stand-in: logs its argv one argument per line, writes the fixture clip
# where -o asks (as .webm, so the rename to source.mp4 stays covered), and
# appends YTDLP_STUB_META (a JSON file) to a --print-to-file target. With
# YTDLP_STUB_ERROR set it fails the way yt-dlp does: an ERROR: line on stderr,
# after a warning that is not the reason. Never reads stdin.
{ printf -- '--- call\n'; printf '%s\n' "$@"; } >> "$STUB_LOG/yt-dlp.log"
if [ "${1:-}" = "--version" ]; then echo "2026.07.04"; exit 0; fi
if [ -n "${YTDLP_STUB_ERROR:-}" ]; then
    printf 'WARNING: [stub] a warning that is not the reason\n' >&2
    printf 'ERROR: %s\n' "$YTDLP_STUB_ERROR" >&2
    exit 1
fi
out="" meta_to=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output) out="$2"; shift 2 ;;
        --print-to-file) meta_to="$3"; shift 3 ;;
        *) shift ;;
    esac
done
[ -n "$out" ] || { echo "ERROR: yt-dlp stub: no -o given" >&2; exit 2; }
cp "$STUB_CLIP" "${out/\%(ext)s/webm}"
if [ -n "$meta_to" ]; then cat "${YTDLP_STUB_META:-$STUB_META}" >> "$meta_to"; fi
exit 0
STUB
chmod +x "$STUB_BIN/curl" "$STUB_BIN/yt-dlp"

ln -s "$(command -v ffmpeg)" "$NOYT_BIN/ffmpeg"
ln -s "$(command -v ffprobe)" "$NOYT_BIN/ffprobe"
# The interpreter itself, not a pyenv shim that needs its own PATH to work.
ln -s "$(python3 -c 'import sys; print(sys.executable)')" "$NOYT_BIN/python3"
ln -s "$STUB_BIN/curl" "$NOYT_BIN/curl"

# For the JS-runtime choice: the yt-dlp stub plus stand-ins for node and deno,
# which video-digest.sh only looks up, never runs.
JS_BIN="$WORK/js-bin"
DENO_BIN="$WORK/deno-bin"
mkdir -p "$JS_BIN" "$DENO_BIN"
ln -s "$STUB_BIN/yt-dlp" "$JS_BIN/yt-dlp"
printf '#!/bin/sh\nexit 0\n' > "$JS_BIN/node"
printf '#!/bin/sh\nexit 0\n' > "$DENO_BIN/deno"
chmod +x "$JS_BIN/node" "$DENO_BIN/deno"

# Preconditions, not tests: if they fail, every case below would prove nothing.
harness_broken() { printf 'harness: %s\n' "$1" >&2; exit 2; }
[ "$(PATH="$STUB_BIN:$PATH"; command -v curl)" = "$STUB_BIN/curl" ] || harness_broken "the curl stub does not shadow curl"
[ "$(PATH="$STUB_BIN:$PATH"; command -v yt-dlp)" = "$STUB_BIN/yt-dlp" ] || harness_broken "the yt-dlp stub does not shadow yt-dlp"
(PATH="$NOYT_PATH"; command -v yt-dlp >/dev/null 2>&1) && harness_broken "yt-dlp is still reachable on $NOYT_PATH"
(PATH="$JS_BIN:$NOYT_PATH"; command -v deno >/dev/null 2>&1) && harness_broken "deno is reachable on $JS_BIN:$NOYT_PATH"
"$NOYT_BIN/python3" -c 'import json' 2>/dev/null || harness_broken "the python3 symlink cannot import json"
ok "stubs shadow curl and yt-dlp; a PATH without yt-dlp is available"

with_stubs() { PATH="$STUB_BIN:$PATH" "$@"; }
without_ytdlp() { PATH="$NOYT_PATH" "$@"; }
node_no_deno() { PATH="$JS_BIN:$NOYT_PATH" "$@"; }
node_and_deno() { PATH="$DENO_BIN:$JS_BIN:$NOYT_PATH" "$@"; }

# run_tool <path-wrapper> <args...>: runs video-digest.sh on fresh stub logs,
# keeping its combined output in OUT and its exit status in RC.
run_tool() {
    local wrap="$1"
    shift
    rm -rf "$STUB_LOG"
    mkdir -p "$STUB_LOG"
    OUT="$("$wrap" "$TOOL" "$@" 2>&1)"
    RC=$?
}

# check <description> <command...>: ok when the command succeeds.
check() {
    local desc="$1"
    shift
    if "$@"; then
        ok "$desc"
    else
        fail "$desc" "rc=$RC; $(tail -2 <<<"$OUT" | tr '\n' ' ')"
    fi
}
not() { ! "$@"; }
# A here-string, not a pipe: `grep -q` closing a pipe early is the pipefail
# trap CLAUDE.md records.
said() { grep -q -- "$1" <<<"$OUT"; }
called() { [ -s "$STUB_LOG/$1.log" ]; }
ytdlp_got() { grep -qxF -- "$1" "$STUB_LOG/yt-dlp.log" 2>/dev/null; }
ytdlp_pair() { grep -A1 -xF -- "$1" "$STUB_LOG/yt-dlp.log" 2>/dev/null | grep -qxF -- "$2"; }
meta_field() {
    python3 - "$1" "$2" <<'PY'
import glob, json, sys
hits = glob.glob(sys.argv[1] + "/videos/*/meta.json")
if len(hits) != 1:
    print("<%d meta.json files>" % len(hits))
else:
    print(json.load(open(hits[0])).get(sys.argv[2], "<no such field>"))
PY
}
dir_count() {
    find "$1/videos" -mindepth 1 -maxdepth 1 -type d ! -name archived 2>/dev/null | wc -l | tr -d ' '
}

# Zight/CloudApp/Droplr keep working exactly as before: the scraper finds the
# file, and yt-dlp is never involved.
run_tool with_stubs "https://share.fixture.test/clip/demo" --output "$WORK/url-zight" --no-contact-sheet --transcript never
assert_eq 0 "$RC" "a page with an embedded .mp4 digests"
assert_eq scrape "$(meta_field "$WORK/url-zight" extractor)" "...through the scraper"
check "...served by the curl stub, not the network" called curl
check "...without calling yt-dlp" not called yt-dlp
assert_eq 2025-03-04 "$(meta_field "$WORK/url-zight" recorded)" "...dated by its CDN filename"

# A Loom share page carries one .mp4: cdn.loom.com/sessions/thumbnails/<id>-
# 00001.mp4, a 5-second silent preview. The scrape took it and digested the
# preview of a 280-second video with exit 0 (verified live). A thumbnail is
# never the video.
run_tool with_stubs "https://share.fixture.test/thumbonly/abc" --output "$WORK/url-thumb" --no-contact-sheet --transcript never
assert_eq 0 "$RC" "a page whose only .mp4 is a thumbnail digests"
check "...through yt-dlp, not the thumbnail" ytdlp_got "https://share.fixture.test/thumbonly/abc"
assert_eq yt-dlp "$(meta_field "$WORK/url-thumb" extractor)" "...and says so"
run_tool without_ytdlp "https://share.fixture.test/thumbonly/abc" --output "$WORK/url-thumb-noyt" --no-contact-sheet --transcript never
assert_eq 1 "$RC" "...without yt-dlp it fails rather than digest the thumbnail"
run_tool with_stubs "https://share.fixture.test/thumbfirst/abc" --output "$WORK/url-thumbfirst" --no-contact-sheet --transcript never
assert_eq "https://cdn.fixture.test/files/2025-06-07-real.mp4" "$(meta_field "$WORK/url-thumbfirst" resolved_url)" \
    "a thumbnail listed before the real file is passed over"

YT=jNQXAC9IVRw
YT_URL="https://www.youtube.com/watch?v=$YT"
OTHER_URL="https://www.youtube.com/watch?v=dQw4w9WgXcQ"
PLAYLIST=PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf

# --- YouTube: one cache id per video (plan step 2) ---------------------------
# The id was the URL's last path segment minus the query, so every watch?v=
# link derived "watch", and a second video would silently reuse the first
# one's source.mp4. Tested through cache reuse, which needs no download: a
# directory holding source.mp4 for $YT must be found from every URL form of
# that video, and never from another video.

printf '\nYouTube: one cache id per video\n'
mkdir -p "$WORK/ytid/videos/2020-01-01-yt-jnqxac9ivrw"
cp "$WORK/moving.mp4" "$WORK/ytid/videos/2020-01-01-yt-jnqxac9ivrw/source.mp4"
for url in \
    "$YT_URL" \
    "$YT_URL&t=30s" \
    "$YT_URL&list=$PLAYLIST&index=2" \
    "https://www.youtube.com/watch?feature=share&v=$YT" \
    "https://youtu.be/$YT?si=AbCdEfGhIjKlMnOp" \
    "https://m.youtube.com/watch?v=$YT" \
    "https://music.youtube.com/watch?v=$YT" \
    "https://www.youtube.com/shorts/$YT" \
    "https://www.youtube.com/live/$YT?feature=share" \
    "https://www.youtube.com/embed/$YT" \
    "https://www.youtube-nocookie.com/embed/$YT"; do
    run_tool with_stubs "$url" --output "$WORK/ytid" --no-contact-sheet --transcript never
    check "reuses the video's cache: $url" said "reusing cached download"
done
assert_eq 1 "$(dir_count "$WORK/ytid")" "...and all of them share one directory"

# Another video must miss that cache, and still reach a download.
run_tool with_stubs "$OTHER_URL" --output "$WORK/ytid" --no-contact-sheet --transcript never
check "another video misses the first one's cache" not said "reusing cached download"
check "...and goes on to download" eval 'called curl || called yt-dlp'

# What the old scheme wrote for the first watch?v= video ever digested.
mkdir -p "$WORK/ytold/videos/2020-01-01-watch"
cp "$WORK/moving.mp4" "$WORK/ytold/videos/2020-01-01-watch/source.mp4"
run_tool with_stubs "$OTHER_URL" --output "$WORK/ytold" --no-contact-sheet --transcript never
check "a watch?v= link no longer derives the id \"watch\"" not said "reusing cached download"
check "...and goes on to download" eval 'called curl || called yt-dlp'

# --- YouTube: straight to yt-dlp (plan step 3) --------------------------------
# The page scrape used to intercept YouTube: the watch page's og:video points
# at /embed/<id>, an HTML player, so the run died blaming an expired link and
# yt-dlp was never tried.

printf '\nYouTube: straight to yt-dlp\n'
run_tool without_ytdlp "$YT_URL" --output "$WORK/yt-noytdlp" --transcript never
assert_eq 1 "$RC" "without yt-dlp a YouTube link fails"
check "...with a message that names yt-dlp" said "^video-digest: .*yt-dlp"
check "...before fetching anything" not called curl
check "...before creating the output dir" not test -e "$WORK/yt-noytdlp"

run_tool with_stubs "$YT_URL" --output "$WORK/yt-ok" --transcript never
assert_eq 0 "$RC" "with yt-dlp a YouTube link digests"
assert_eq yt-dlp "$(meta_field "$WORK/yt-ok" extractor)" "...through yt-dlp"
check "...which gets the link itself" ytdlp_got "$YT_URL"
check "...without fetching the page" not called curl
check "...and the .webm download becomes a contact sheet" \
    test -s "$(find "$WORK/yt-ok/videos" -name contact-sheet.jpg | head -1)"

run_tool with_stubs "$YT_URL" --output "$WORK/yt-two" --no-contact-sheet --transcript never
run_tool with_stubs "$OTHER_URL" --output "$WORK/yt-two" --no-contact-sheet --transcript never
assert_eq 2 "$(dir_count "$WORK/yt-two")" "two watch?v= videos get two directories"

run_tool with_stubs "https://www.youtube.com/playlist?list=$PLAYLIST" --output "$WORK/yt-playlist" --transcript never
assert_eq 1 "$RC" "a YouTube link with no video id (a playlist) is refused"
check "...before any fetch" not called curl
check "...or download" not called yt-dlp
check "...or output dir" not test -e "$WORK/yt-playlist"

# --- og:video pointing at a player page (plan step 4) -------------------------
# Vimeo's og:video is player.vimeo.com/video/<id>, an HTML page; the magic-byte
# check caught it and blamed an expired link, though yt-dlp could have tried.

printf '\nog:video pointing at a player page\n'
run_tool with_stubs "https://share.fixture.test/player/abc" --output "$WORK/og-player" --no-contact-sheet --transcript never
assert_eq 0 "$RC" "HTML behind og:video falls through to yt-dlp"
check "...which gets the share URL, not the player URL" ytdlp_got "https://share.fixture.test/player/abc"
assert_eq yt-dlp "$(meta_field "$WORK/og-player" extractor)" "...and is recorded as the extractor"

export YTDLP_STUB_ERROR="Unsupported URL: https://share.fixture.test/player/abc"
run_tool with_stubs "https://share.fixture.test/player/abc" --output "$WORK/og-player-fail" --no-contact-sheet --transcript never
unset YTDLP_STUB_ERROR
assert_eq 1 "$RC" "when yt-dlp fails too, the run fails"
check "...naming the HTML page" said "^video-digest: .*HTML"
check "...and yt-dlp's reason" said "^video-digest: .*Unsupported URL"

run_tool without_ytdlp "https://share.fixture.test/player/abc" --output "$WORK/og-player-noyt" --no-contact-sheet --transcript never
assert_eq 1 "$RC" "without yt-dlp, HTML behind og:video still fails"
check "...and suggests yt-dlp" said "^video-digest: .*yt-dlp"

# --- every yt-dlp call is hardened (plan step 5) ------------------------------

printf '\nyt-dlp invocation\n'
for url in "$YT_URL&list=$PLAYLIST" "https://share.fixture.test/player/abc" "https://share.fixture.test/novideo/x"; do
    run_tool with_stubs "$url" --output "$WORK/yt-flags" --no-contact-sheet --transcript never
    check "only the one video, even with &list=: $url" ytdlp_got "--no-playlist"
    # res is yt-dlp's SMALLER dimension. A [height<=720] filter assumes
    # landscape: on a vertical Short (720x1280) it skipped 720p and fetched
    # 360x640, a quarter of the sheet's pixel budget (verified live).
    check "...capped at 720p on the short side" ytdlp_pair "-S" "res:720"
    check "...with no height filter that assumes landscape" not grep -q 'height<=' "$STUB_LOG/yt-dlp.log"
    check "...without a self-update" ytdlp_got "--no-update"
done

export YTDLP_STUB_ERROR="[youtube] $YT: Sign in to confirm you're not a bot"
run_tool with_stubs "$YT_URL" --output "$WORK/yt-fail" --no-contact-sheet --transcript never
unset YTDLP_STUB_ERROR
assert_eq 1 "$RC" "a failing yt-dlp fails the run"
check "...and the error carries yt-dlp's reason" said "^video-digest: .*Sign in to confirm"

run_tool node_no_deno "$YT_URL" --output "$WORK/js-node" --no-contact-sheet --transcript never
check "without deno, yt-dlp is pointed at node" ytdlp_pair "--js-runtimes" "node"
run_tool node_and_deno "$YT_URL" --output "$WORK/js-deno" --no-contact-sheet --transcript never
check "with deno, yt-dlp is called" called yt-dlp
check "...and left on its default runtime" not ytdlp_got "--js-runtimes"

# --- yt-dlp metadata (plan step 6) --------------------------------------------
# Without it every YouTube digest was dated today, and its directory said
# nothing about what it held.

printf '\nyt-dlp metadata\n'
run_tool with_stubs "$YT_URL" --output "$WORK/yt-meta" --no-contact-sheet --transcript never
assert_eq 0 "$RC" "a YouTube digest with metadata succeeds"
assert_eq 2024-01-02 "$(meta_field "$WORK/yt-meta" recorded)" "...dated by the upload date"
assert_eq yt-dlp-upload-date "$(meta_field "$WORK/yt-meta" recorded_source)" "...and says so"
assert_eq "Stub Video Title" "$(meta_field "$WORK/yt-meta" title)" "...meta.json carries the video's title"
check "...which names the directory" test -d "$WORK/yt-meta/videos/2024-01-02-yt-jnqxac9ivrw-stub-video-title"

# A cache hit downloads nothing, so it must not lose what the download said.
run_tool with_stubs "$YT_URL" --output "$WORK/yt-meta" --no-contact-sheet --transcript never
check "a second run is a cache hit" said "reusing cached download"
check "...which does not call yt-dlp" not called yt-dlp
assert_eq 2024-01-02 "$(meta_field "$WORK/yt-meta" recorded)" "...and keeps the upload date"
assert_eq "Stub Video Title" "$(meta_field "$WORK/yt-meta" title)" "...and the title"

run_tool with_stubs "$YT_URL" --output "$WORK/yt-meta-title" --title "My Label" --no-contact-sheet --transcript never
check "--title still names the directory" test -d "$WORK/yt-meta-title/videos/2024-01-02-yt-jnqxac9ivrw-my-label"

: > "$WORK/empty-meta.json"
export YTDLP_STUB_META="$WORK/empty-meta.json"
run_tool with_stubs "$YT_URL" --output "$WORK/yt-nometa" --no-contact-sheet --transcript never
unset YTDLP_STUB_META
assert_eq 0 "$RC" "missing yt-dlp metadata does not fail the run"
check "...the digest is dated another way" not test "$(meta_field "$WORK/yt-nometa" recorded_source)" = yt-dlp-upload-date

# Long videos are digested as they are, but the reader is told up front that
# 30 frames will be sparse and a transcript slow.
run_tool with_stubs "$WORK/long16.mp4" --output "$WORK/long" --no-contact-sheet --transcript never
check "a video over 15 minutes gets a warning" said "long video"
run_tool with_stubs "$WORK/moving.mp4" --output "$WORK/short" --no-contact-sheet --transcript never
check "...a short one does not" not said "long video"

# --- doctor: what YouTube needs (plan step 7) ---------------------------------
# A stale yt-dlp is the likeliest YouTube failure (YouTube breaks old ones
# regularly), so doctor shows its version; and a missing JS runtime degrades
# YouTube silently, so doctor names the one yt-dlp will get.

printf '\ndoctor\n'
run_tool with_stubs doctor
check "doctor shows the yt-dlp version" said '\[ok\] *yt-dlp .*2026\.07\.04'
check "...and that YouTube links need it" said '\[ok\] *yt-dlp .*YouTube'
run_tool without_ytdlp doctor
assert_eq 0 "$RC" "doctor without yt-dlp, deno or node still exits 0 (all optional)"
check "...says how to install yt-dlp" said '\[absent\] *yt-dlp .*install yt-dlp'
check "...and that no JS runtime is there" said '\[absent\] *deno '
run_tool node_no_deno doctor
check "doctor names node as the JS runtime when deno is missing" said '\[ok\] *node '
run_tool node_and_deno doctor
check "doctor names deno when it is there" said '\[ok\] *deno '

# --- summary ---------------------------------------------------------------

printf '\n%s passed, %s failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
