#!/usr/bin/env bash
# Turn a video into a readable digest: a timestamped contact sheet, individual
# frames, and — only when the audio track carries real signal — a transcript
# grouped under the frame each line was spoken over.
#
# Takes a URL, a local file path, or (for known share hosts) a bare share id.
# yt-dlp does not support Zight/CloudApp/Droplr-style share hosts, so those are
# scraped directly; anything yt-dlp does support (YouTube, Loom, Vimeo, ...) is
# handed to it when it is installed.

set -euo pipefail

# --- defaults, overridable by config file then CLI flags --------------------
# Empty MAX_FRAMES = derive from duration (see BUDGET below); an explicit value
# from config or --max-frames overrides.
MAX_FRAMES=""
FRAMES_FLOOR=10
FRAMES_CEILING=30
SECONDS_PER_FRAME=4.5
MIN_INTERVAL=1
SAMPLE_FPS=2
DEDUPE=1
CONTACT_SHEET=1
WRITE_FRAMES=1
TRANSCRIPT_MODE="auto" # auto | always | never
CELL_AREA=480000
JPEG_QUALITY=2
KEEP_SOURCE="auto" # auto | always | never
SILENCE_FLOOR=-60
WHISPER_MODEL="base"
OUTPUT_DIR=""
FORCE=0
TICKET=""
TITLE=""
SOURCE=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage:
    video-digest.sh <url|file.mp4> [options]
    video-digest.sh doctor

Options:
    --ticket <id>        label for the output directory (any short id you use)
    --title <text>       short slug for the output directory
    --output <dir>        where to write output (default: OS temp dir; see README)
    --max-frames <n>     override the frame cap (default: ~1 per 4.5s, 10-30)
    --min-interval <s>   minimum seconds between frames (default 1)
    --sample-fps <n>     pre-dedupe sampling rate (default 2)
    --no-dedupe          even sampling instead of scene-change dedupe
    --no-contact-sheet   skip the contact sheet
    --no-frames          skip writing individual frame files
    --transcript <mode>  auto (default) | always | never
    --keep-source <mode> auto (default) | always | never — see README
    --force              re-download and re-extract; overrides an archived hit
    --config <file>      use this config file instead of the discovered one
    -h, --help            this message

Config file (JSON): .video-digest.json in the current directory, or
~/.config/video-digest/config.json — see README for the full field list.
Precedence: built-in defaults < config file < CLI flags.

Output, per recording, in its own directory:
    contact-sheet.jpg   read this first
    frames/             individual frames, for a closer look
    transcript.txt      only when the audio carries signal
    source.url          only when the input was a URL
    meta.json  source.mp4 (unless --keep-source never / auto-deleted)
EOF
}

die() {
    printf 'video-digest: %s\n' "$1" >&2
    exit 1
}

note() {
    printf '  %s\n' "$1" >&2
}

need() {
    command -v "$1" >/dev/null 2>&1 && return 0
    case "$(uname -s)" in
        Darwin) die "$1 not found. Install it: brew install $2" ;;
        *) die "$1 not found. Install it: apt-get install $2 (or your distro's equivalent)" ;;
    esac
}

# --- doctor subcommand --------------------------------------------------
# Non-interactive: prints what's present and what's missing, for pasting into
# an issue. Distinct from an installer — this tool has no interactive install
# step (see README "Why no interactive installer").
run_doctor() {
    printf 'video-digest doctor\n\n'
    local all_ok=1
    check() {
        local bin="$1" required="$2" note_text="${3:-}"
        if command -v "$bin" >/dev/null 2>&1; then
            printf '  [ok]      %-10s %s\n' "$bin" "$(command -v "$bin")"
        elif [ "$required" = "required" ]; then
            printf '  [MISSING] %-10s required — %s\n' "$bin" "$note_text"
            all_ok=0
        else
            printf '  [absent]  %-10s optional — %s\n' "$bin" "$note_text"
        fi
    }
    check ffmpeg required "frame extraction and the contact sheet"
    check ffprobe required "duration/audio probing"
    check python3 required "meta.json and transcript grouping"
    check curl optional "fetching a URL input"
    check whisper optional "transcription (skipped without it, not an error)"
    check yt-dlp optional "sites beyond the built-in scraper (Loom, YouTube, Vimeo, ...)"

    if command -v ffmpeg >/dev/null 2>&1; then
        # Capture first, then match — same reason as the real probe below:
        # `grep -q` in a pipe can exit before ffmpeg finishes writing, ffmpeg
        # dies of SIGPIPE, and pipefail can turn that into a false "missing"
        # on a build that actually has the filter.
        ffmpeg_filters="$(ffmpeg -hide_banner -filters 2>/dev/null || true)"
        if printf '%s' "$ffmpeg_filters" | command grep -q ' drawtext '; then
            printf '  [ok]      drawtext   contact sheet will have timestamps\n'
        else
            printf '  [absent]  drawtext   this ffmpeg build lacks libfreetype — sheet will have no timestamps\n'
        fi
    fi

    printf '\n'
    if [ "$all_ok" -eq 1 ]; then
        printf 'All required dependencies are present.\n'
        exit 0
    else
        printf 'Missing required dependencies — see above.\n'
        exit 1
    fi
}

# --- config file loading -----------------------------------------------
# JSON via python3, which is already required for meta.json — no new
# dependency. Precedence is enforced by load order: defaults are already set
# above, the config file overwrites them, CLI flags (parsed after this)
# overwrite those.
CONFIG_FILE_ARG=""
find_config_file() {
    [ -n "$CONFIG_FILE_ARG" ] && { printf '%s' "$CONFIG_FILE_ARG"; return 0; }
    [ -f "./.video-digest.json" ] && { printf '%s' "./.video-digest.json"; return 0; }
    local user_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/video-digest/config.json"
    [ -f "$user_cfg" ] && { printf '%s' "$user_cfg"; return 0; }
    return 1
}

load_config_file() {
    local cfg="$1"
    [ -n "$cfg" ] || return 0
    [ -f "$cfg" ] || die "config file not found: $cfg"
    command -v python3 >/dev/null 2>&1 || die "python3 is required to read $cfg"
    local out
    out="$(python3 "$SCRIPT_DIR/lib/read-config.py" "$cfg")" || die "could not parse config file: $cfg"
    # read-config.py prints one VAR=value per line, values already validated
    # and shell-quoted; eval is safe here because the producer is our own
    # script, not user-controlled text.
    eval "$out"
}

# A pre-scan for --config so it can be honoured before the main option loop
# (which needs config values loaded before CLI flags override them). Must
# skip every OTHER value-taking flag's argument while walking, or a value
# that happens to equal "--config" (e.g. `--title --config`) is misread as
# the flag itself — and the token right after it (which may be an unrelated
# flag like --output) misread as the config path.
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
    case "${args[$i]}" in
        --config)
            j=$((i + 1))
            [ $j -lt ${#args[@]} ] || die "--config needs a value"
            CONFIG_FILE_ARG="${args[$j]}"
            i=$((i + 2))
            continue
            ;;
        --ticket|--title|--output|--max-frames|--min-interval|--sample-fps|--transcript|--keep-source)
            i=$((i + 2)) # skip this flag's own value too
            continue
            ;;
    esac
    i=$((i + 1))
done

if [ "${1:-}" = "doctor" ]; then
    run_doctor
fi

if cfg_path="$(find_config_file)"; then
    load_config_file "$cfg_path"
fi

# --- argument parsing (flags override config) --------------------------

while [ $# -gt 0 ]; do
    # ⚠️ `${2:-}` only guards the EXPANSION; `shift 2` with a single argument
    # left still fails, and set -e then kills the script with no message at
    # all (a flag typo'd as the last argument, e.g. `... --ticket`, silently
    # exits 1). Value-taking flags therefore validate `$#` before consuming.
    case "$1" in
        --ticket|--title|--output|--max-frames|--min-interval|--sample-fps|--transcript|--keep-source|--config)
            [ $# -ge 2 ] || die "$1 needs a value" ;;
    esac
    case "$1" in
        --ticket) TICKET="$2"; shift 2 ;;
        --title) TITLE="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --max-frames) MAX_FRAMES="$2"; shift 2 ;;
        --min-interval) MIN_INTERVAL="$2"; shift 2 ;;
        --sample-fps) SAMPLE_FPS="$2"; shift 2 ;;
        --no-dedupe) DEDUPE=0; shift ;;
        --no-contact-sheet) CONTACT_SHEET=0; shift ;;
        --no-frames) WRITE_FRAMES=0; shift ;;
        --transcript) TRANSCRIPT_MODE="$2"; shift 2 ;;
        --keep-source) KEEP_SOURCE="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --config) shift 2 ;; # already consumed by the pre-scan above
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *)
            [ -n "$SOURCE" ] && die "more than one source given: '$SOURCE' and '$1'"
            SOURCE="$1"; shift ;;
    esac
done

[ -n "$SOURCE" ] || { usage >&2; exit 1; }

case "$TRANSCRIPT_MODE" in auto|always|never) ;; *) die "--transcript must be auto, always, or never" ;; esac
case "$KEEP_SOURCE" in auto|always|never) ;; *) die "--keep-source must be auto, always, or never" ;; esac
[ "$CONTACT_SHEET" -eq 1 ] || [ "$WRITE_FRAMES" -eq 1 ] || [ "$TRANSCRIPT_MODE" != "never" ] \
    || die "nothing to produce: --no-contact-sheet, --no-frames and --transcript never were all given"

# Checked up front, not where they are first used: the python3 that writes
# meta.json runs last, so a missing interpreter would surface only after the
# download and the whole extraction had already happened.
need ffmpeg ffmpeg
need ffprobe ffmpeg
need python3 python3

if [ -n "$MAX_FRAMES" ]; then
    case "$MAX_FRAMES" in *[!0-9]*) die "max-frames must be a positive integer" ;; esac
    [ "$MAX_FRAMES" -gt 0 ] || die "max-frames must be a positive integer"
fi

# Both feed arithmetic downstream; zero reaches awk as a division by zero and
# ffmpeg as an exit-234 filter error, neither of which names the flag that
# caused it.
for pair in "min-interval:$MIN_INTERVAL" "sample-fps:$SAMPLE_FPS"; do
    flag="${pair%%:*}"; val="${pair#*:}"
    case "$val" in
        '' | *[!0-9.]* | *.*.*) die "$flag must be a positive number" ;;
    esac
    awk -v v="$val" 'BEGIN{exit !(v > 0)}' || die "$flag must be greater than zero"
done

# --- resolve the output root --------------------------------------------
# Default to the OS temp dir rather than the caller's project: a stranger's
# repo should not gain untracked files just from running this tool. Opting
# into a persistent dir (config "output", or --output) is what makes cache
# reuse and a kept source.mp4 meaningful.
if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="${TMPDIR:-/tmp}/video-digest"
    OUTPUT_IS_TEMP=1
else
    OUTPUT_IS_TEMP=0
fi
MEDIA_ROOT="$OUTPUT_DIR"
VIDEOS_DIR="$MEDIA_ROOT/videos"
ARCHIVE_DIR="$VIDEOS_DIR/archived"

if [ "$OUTPUT_IS_TEMP" -eq 0 ] && [ -d "$(pwd)/.git" ]; then
    case "$OUTPUT_DIR" in
        /*) resolved_output="$OUTPUT_DIR" ;;
        *) resolved_output="$(pwd)/$OUTPUT_DIR" ;;
    esac
    case "$resolved_output" in
        "$(pwd)"/*)
            if ! git -C "$(pwd)" check-ignore -q "$resolved_output" 2>/dev/null; then
                note "output dir '$OUTPUT_DIR' is inside a git repo and not gitignored — consider adding it"
            fi
            ;;
    esac
fi

# --- extractor chain -----------------------------------------------------
# 1. local file path (checked first, cheapest)
# 2. direct scrape: fetch the page, find an embedded .mp4 — covers Zight/
#    CloudApp/Droplr-style hosts that yt-dlp does not know
# 3. yt-dlp, if installed: hands off anything the scrape could not resolve
#    (Loom, YouTube, Vimeo, hundreds more) — Loom in particular serves HLS,
#    not a scrapable .mp4, so a hand-rolled extractor would just duplicate
#    yt-dlp badly
#
# ⚠️ Do not lower-case or otherwise rewrite a SHARE_ID once accepted: it is
# the cache key, and the directory lookup globs on it verbatim — that is what
# "validate, never normalise" means for a value already known to be clean
# (e.g. a Zight-style share id, always plain alphanumeric). A URL's last path
# segment is NOT that: arbitrary sites use colons, spaces, percent-encoding
# in their paths (a wiki "File:x.ogv" page, for instance), and none of that
# is a signal anything is wrong — it is just an ordinary URL. So a URL-derived
# id IS slugified for filesystem safety; a local file's basename, which the
# user controls and can simply rename, is still validated strictly, since a
# stray shell-hostile byte there is worth surfacing rather than silently
# mangling.

SHARE_URL=""
LOCAL_INPUT=""

if [ -f "$SOURCE" ]; then
    LOCAL_INPUT="$(cd "$(dirname "$SOURCE")" && pwd)/$(basename "$SOURCE")"
    SHARE_ID="$(basename "$SOURCE")"
    SHARE_ID="${SHARE_ID%.*}"
    case "$SHARE_ID" in
        *[!A-Za-z0-9._-]* | -* | .*)
            die "'$SHARE_ID' has characters that cannot be used in a directory name — rename the file" ;;
    esac
elif printf '%s' "$SOURCE" | command grep -qE '^https?://'; then
    SHARE_URL="$SOURCE"
    raw_id="${SOURCE%/}"
    raw_id="${raw_id##*/}"
    raw_id="${raw_id%%\?*}"
    [ -n "$raw_id" ] || raw_id="video"
    SHARE_ID="$(printf '%s' "$raw_id" | tr '[:upper:]' '[:lower:]' \
        | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-60)"
    [ -n "$SHARE_ID" ] || SHARE_ID="video"
else
    die "not a URL or an existing file path: '$SOURCE'"
fi

[ -n "$SHARE_ID" ] || die "could not derive an id from '$SOURCE'"

# --- directory lookup -----------------------------------------------------
# Bash passes an unmatched glob through literally, so nullglob is load-bearing:
# without it the no-match case counts the pattern itself as a hit.
shopt -s nullglob

# Returns 0 with the path, 1 for no match, 2 for ambiguous. It must NOT die:
# callers capture it in $(...), where `exit` only kills the subshell — the
# caller would then read a plain non-zero, take its "no match" branch and
# carry on with exit 0, which silently defeats both the archived/ guard and
# existing-dir reuse.
find_dir() {
    local base="$1" hits=()
    hits=("$base"/*-"$SHARE_ID" "$base"/*-"$SHARE_ID"-*)
    [ ${#hits[@]} -eq 0 ] && return 1
    if [ ${#hits[@]} -gt 1 ]; then
        printf '%s\n' "${hits[@]}" >&2
        return 2
    fi
    printf '%s' "${hits[0]}"
}

if [ "$FORCE" -eq 0 ] && [ -d "$ARCHIVE_DIR" ]; then
    archived="$(find_dir "$ARCHIVE_DIR")" && rc=0 || rc=$?
    [ "$rc" -eq 2 ] && die "several archived directories match id '$SHARE_ID' (listed above). Resolve by hand."
    [ "$rc" -eq 0 ] && die "'$SHARE_ID' is in archived/ ($archived). Move it back, or pass --force."
fi

mkdir -p "$VIDEOS_DIR" "$ARCHIVE_DIR"

TARGET_DIR=""
existing="$(find_dir "$VIDEOS_DIR")" && rc=0 || rc=$?
if [ "$rc" -eq 2 ]; then
    die "several directories match id '$SHARE_ID' (listed above). Resolve by hand."
elif [ "$rc" -eq 0 ]; then
    TARGET_DIR="$existing"
fi

# --- acquire the video -------------------------------------------------

slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
        | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-40
}

SOURCE_MP4=""
CDN_URL=""
RECORDED=""
DATE_SOURCE=""
TMP_DL=""
NO_FRAMES_TMP="" # set below only when --no-frames — the throwaway FRAMES_DIR
EXTRACTOR="local"

# An EXIT trap's return value becomes the script's exit code, so a trailing
# short-circuit that evaluates false (here: no temp dir to remove, i.e. every
# cache hit) would exit 1 after a completely successful run.
cleanup() {
    if [ -n "$TMP_DL" ]; then rm -rf "$TMP_DL"; fi
    if [ -n "$NO_FRAMES_TMP" ]; then rm -rf "$NO_FRAMES_TMP"; fi
    return 0
}
trap cleanup EXIT

if [ -n "$TARGET_DIR" ] && [ -f "$TARGET_DIR/source.mp4" ] && [ "$FORCE" -eq 0 ]; then
    SOURCE_MP4="$TARGET_DIR/source.mp4"
    note "reusing cached download: $TARGET_DIR"
else
    TMP_DL="$(mktemp -d)"
    if [ -n "$LOCAL_INPUT" ]; then
        cp "$LOCAL_INPUT" "$TMP_DL/source.mp4"
        DATE_SOURCE="ffprobe"
    else
        need curl curl
        note "fetching $SHARE_URL"
        page="$TMP_DL/page.html"
        fetched=0
        # ⚠️ SSRF: the scraper follows a URL taken from the PAGE's own content
        # below (CDN_URL), not one the user chose — a malicious page can point
        # that second request at any host, including internal ones, and -L
        # means a redirect chain can do the same even starting from a URL that
        # looked external. This is not eliminated here (a CLI tool fetching a
        # URL a user handed it has some irreducible version of this risk), but
        # bounded: only http(s) is followed, redirect depth is capped, and the
        # resolved host is printed so a silent pivot is at least visible.
        if curl -sSL --proto '=https,http' --max-redirs 3 --max-time 60 "$SHARE_URL" -o "$page" 2>/dev/null; then
            fetched=1
        fi

        CDN_URL=""
        if [ "$fetched" -eq 1 ]; then
            # The viewer variant (Zight-family) is the plain playable file;
            # fall back to any embedded mp4 on the page.
            CDN_URL="$(command grep -oE 'https?://[^"'"'"']+\.mp4[^"'"'"']*' "$page" \
                | command grep 'source=viewer' | head -1 || true)"
            [ -n "$CDN_URL" ] || CDN_URL="$(command grep -oE 'https?://[^"'"'"']+\.mp4[^"'"'"']*' "$page" | head -1 || true)"
        fi

        if [ -n "$CDN_URL" ]; then
            CDN_URL="${CDN_URL//&amp;/&}"
            EXTRACTOR="scrape"
            # The page's content chose this URL, not the user — print the host
            # so a pivot to somewhere unexpected (see the SSRF note above) is
            # visible rather than silent.
            cdn_host="$(printf '%s' "$CDN_URL" | sed -E 's#^https?://([^/]+).*#\1#')"
            note "downloading from $cdn_host"
            curl -sSL --proto '=https,http' --max-redirs 3 --max-time 600 -o "$TMP_DL/source.mp4" "$CDN_URL" \
                || die "download failed: $CDN_URL"

            # A share link can expire or sit behind a login wall and still
            # answer 200 with an HTML page instead of the video — downloaded
            # as if it were one, that used to fail later with "could not read
            # duration", which blames the wrong thing. A cheap magic-byte
            # check catches the common case (an HTML error/login page) before
            # ffmpeg ever runs, without false-rejecting a real video whose
            # container this check doesn't specifically recognise.
            first_bytes="$(command grep -aiEc '<html|<!doctype html' "$TMP_DL/source.mp4" 2>/dev/null | head -1 || true)"
            if [ "${first_bytes:-0}" -gt 0 ] 2>/dev/null; then
                die "the link returned an HTML page, not a video — it may have expired or need login: $CDN_URL"
            fi

            # The CDN filename usually carries the real recording date, which
            # can predate whatever this URL was shared in by weeks.
            fname="$(printf '%s' "$CDN_URL" | sed 's/?.*//')"
            fname="$(basename "$fname" | sed 's/%20/ /g')"
            RECORDED="$(printf '%s' "$fname" | command grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || true)"
            [ -n "$RECORDED" ] && DATE_SOURCE="cdn-filename"
        elif command -v yt-dlp >/dev/null 2>&1; then
            EXTRACTOR="yt-dlp"
            note "no embedded mp4 found on the page — handing off to yt-dlp"
            yt-dlp --no-progress -o "$TMP_DL/source.%(ext)s" "$SHARE_URL" \
                || die "yt-dlp could not download: $SHARE_URL"
            found="$(find "$TMP_DL" -maxdepth 1 -name 'source.*' -type f | head -1)"
            [ -n "$found" ] || die "yt-dlp reported success but wrote no file"
            [ "$found" = "$TMP_DL/source.mp4" ] || mv "$found" "$TMP_DL/source.mp4"
        else
            die "no video found on $SHARE_URL, and yt-dlp is not installed to try further — install yt-dlp for broader site support, or pass a local file"
        fi
    fi

    [ -s "$TMP_DL/source.mp4" ] || die "downloaded file is empty"
    SOURCE_MP4="$TMP_DL/source.mp4"
fi

# --- probe ---------------------------------------------------------------
# Derive timing from duration, never nb_frames/r_frame_rate: real-world clips
# can report a variable rate that makes those unreliable.

DURATION="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$SOURCE_MP4" 2>/dev/null || true)"
case "$DURATION" in ''|N/A) die "could not read duration — is this a video file?" ;; esac

if [ -z "$RECORDED" ]; then
    created="$(ffprobe -v error -show_entries format_tags=creation_time -of default=nw=1:nk=1 "$SOURCE_MP4" 2>/dev/null || true)"
    RECORDED="$(printf '%s' "$created" | command grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)"
    if [ -n "$RECORDED" ]; then
        DATE_SOURCE="ffprobe-creation-time"
    else
        RECORDED="$(date +%F)"
        DATE_SOURCE="today-fallback"
    fi
fi

# --- settle the directory name -------------------------------------------
# ⚠️ SHARE_ID keeps its case — it is the cache key, and the lookup globs
# `*-$SHARE_ID`. Lower-casing it here (slugify does) would make every re-run
# miss its own directory. Ticket and title are sanitised; a title of pure
# punctuation slugifies to nothing, which would otherwise leave a dangling
# separator.
name="$RECORDED"
ticket_slug="$(slugify "$TICKET")"
title_slug="$(slugify "$TITLE")"
[ -n "$ticket_slug" ] && name="$name-$ticket_slug"
name="$name-$SHARE_ID"
[ -n "$title_slug" ] && name="$name-$title_slug"
WANT_DIR="$VIDEOS_DIR/$name"

if [ -n "$TARGET_DIR" ]; then
    if [ "$TARGET_DIR" != "$WANT_DIR" ]; then
        # Only enrich a name that is missing detail; never churn a path the
        # user may already have referenced elsewhere.
        if [ ${#WANT_DIR} -gt ${#TARGET_DIR} ] && [ ! -d "$WANT_DIR" ]; then
            mv "$TARGET_DIR" "$WANT_DIR"
            note "renamed: $(basename "$TARGET_DIR") -> $name"
            TARGET_DIR="$WANT_DIR"
            # A cache hit resolved SOURCE_MP4 under the old name, which the mv
            # just invalidated; ffmpeg would then fail on a path that no
            # longer exists.
            [ -f "$TARGET_DIR/source.mp4" ] && SOURCE_MP4="$TARGET_DIR/source.mp4"
        else
            note "keeping existing name: $(basename "$TARGET_DIR")"
        fi
    fi
else
    TARGET_DIR="$WANT_DIR"
    mkdir -p "$TARGET_DIR"
fi

if [ "$WRITE_FRAMES" -eq 1 ]; then
    FRAMES_DIR="$TARGET_DIR/frames"
    rm -rf "$FRAMES_DIR"
    mkdir -p "$FRAMES_DIR"
else
    # Frames are still extracted to build the sheet; the dir is meant to be
    # discarded after. It previously wasn't — nothing removed it, so every
    # --no-frames run leaked a directory of JPEGs into the OS temp dir. It
    # goes through `cleanup()` now, same as the other scratch dirs.
    FRAMES_DIR="$(mktemp -d)"
    NO_FRAMES_TMP="$FRAMES_DIR"
fi

if [ -n "$TMP_DL" ] && [ -f "$TMP_DL/source.mp4" ]; then
    mv "$TMP_DL/source.mp4" "$TARGET_DIR/source.mp4"
    SOURCE_MP4="$TARGET_DIR/source.mp4"
fi
if [ -n "$SHARE_URL" ]; then
    # `[InternetShortcut]` rather than a bare url: double-clickable in Finder
    # (macOS types .url as com.microsoft.internet-shortcut, claimed by Safari)
    # while the url stays on its own line for `grep URL=`.
    printf '[InternetShortcut]\nURL=%s\n' "$SHARE_URL" > "$TARGET_DIR/source.url"
fi

# --- extract frames --------------------------------------------------------

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; cleanup' EXIT

# `showinfo` reports each surviving frame's pts_time on stderr. Dedupe keeps
# frames at UNEVEN intervals, so a nominal duration/count average cannot say
# when a frame actually happened — and the transcript is grouped by those
# real times.
if [ "$DEDUPE" -eq 1 ]; then
    # -fps_mode vfr is load-bearing: without it ffmpeg re-duplicates the
    # frames mpdecimate just dropped, and the filter becomes a silent no-op.
    ffmpeg -hide_banner -nostats -nostdin -y -loglevel info -i "$SOURCE_MP4" \
        -vf "fps=$SAMPLE_FPS,mpdecimate=hi=64*12:lo=64*5:frac=0.33,showinfo" \
        -fps_mode vfr -q:v 3 "$WORK/raw_%04d.jpg" 2> "$WORK/info.log"
else
    ffmpeg -hide_banner -nostats -nostdin -y -loglevel info -i "$SOURCE_MP4" \
        -vf "fps=$SAMPLE_FPS,showinfo" -q:v 3 "$WORK/raw_%04d.jpg" 2> "$WORK/info.log"
fi

raw=("$WORK"/raw_*.jpg)
RAW_COUNT=${#raw[@]}
[ "$RAW_COUNT" -gt 0 ] || die "no frames extracted from $SOURCE_MP4"

# One pts_time per extracted frame, in order.
raw_times=()
while IFS= read -r t; do raw_times+=("$t"); done < <(
    command grep -oE 'pts_time:[0-9.]+' "$WORK/info.log" | cut -d: -f2
)

# The budget scales with duration rather than being a flat number: a fixed
# small number is ample for a short clip but steps straight over the action
# on a long one. Roughly a frame per SECONDS_PER_FRAME, floored so short clips
# are unaffected and capped so a long one cannot flood the reader.
if [ -n "$MAX_FRAMES" ]; then
    BUDGET="$MAX_FRAMES"
else
    BUDGET="$(awk -v d="$DURATION" -v s="$SECONDS_PER_FRAME" -v lo="$FRAMES_FLOOR" -v hi="$FRAMES_CEILING" 'BEGIN{
        n = int(d / s + 0.5);
        if (n < lo) n = lo;
        if (n > hi) n = hi;
        print n
    }')"
fi
# The min-interval clamp keeps auto-derived budgets from asking for more frames
# than the clip has distinct seconds. An explicit --max-frames is a deliberate
# request for denser coverage — usually to inspect a fast interaction frame by
# frame — so it wins over the heuristic; otherwise a short clip silently
# ignores the flag. Found in real triage use: --max-frames 40 on a 13.7s clip
# produced only 14 frames, and the missing frames were exactly the ones that
# would have shown what actually happened (see CLAUDE.md).
if [ -z "$MAX_FRAMES" ]; then
    by_interval="$(awk -v d="$DURATION" -v m="$MIN_INTERVAL" 'BEGIN{v=int(d/m); print (v<1?1:v)}')"
    [ "$by_interval" -lt "$BUDGET" ] && BUDGET="$by_interval"
fi
[ "$RAW_COUNT" -lt "$BUDGET" ] && BUDGET="$RAW_COUNT"

# Both ends are pinned. The FIRST frame is the starting state; the LAST is the
# outcome, and even spacing almost always drops the tail. "Last" means the
# last frame that SURVIVED dedupe, not the last of the file: mpdecimate has
# already discarded the static run-out, so this lands on the final frame
# where something was still happening rather than on a black screen.
i=0
kept=0
last_idx=$((RAW_COUNT - 1))
FRAME_TIMES=()
while [ $i -lt "$RAW_COUNT" ]; do
    pick="$(awk -v i="$i" -v n="$RAW_COUNT" -v b="$BUDGET" 'BEGIN{print int(i*b/n)}')"
    prev="$(awk -v i="$i" -v n="$RAW_COUNT" -v b="$BUDGET" 'BEGIN{print int((i-1)*b/n)}')"
    take=0
    [ "$i" -eq 0 ] && take=1
    [ "$i" -eq "$last_idx" ] && take=1
    [ "$pick" != "$prev" ] && take=1
    if [ "$take" -eq 1 ]; then
        kept=$((kept + 1))
        cp "${raw[$i]}" "$(printf '%s/frame_%03d.jpg' "$FRAMES_DIR" "$kept")"
        FRAME_TIMES+=("${raw_times[$i]:-}")
    fi
    i=$((i + 1))
done

INTERVAL="$(awk -v d="$DURATION" -v k="$kept" 'BEGIN{printf "%.2f", (k>0? d/k : 0)}')"

# --- contact sheet -----------------------------------------------------
# Timestamps are approximate: ordinal x interval, not true PTS.

SHEET=""
if [ "$CONTACT_SHEET" -eq 1 ]; then
    # Portrait phone frames need more columns, or the sheet becomes a tall
    # strip no screen can show at once; landscape needs fewer. Aim for a
    # roughly square sheet.
    ASPECT="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
        -of csv=p=0:s=x "$SOURCE_MP4" 2>/dev/null || true)"
    FRAME_W="${ASPECT%x*}"
    FRAME_H="${ASPECT#*x}"
    case "$FRAME_W$FRAME_H" in ''|*[!0-9]*) FRAME_W=16; FRAME_H=9 ;; esac

    COLS="$(awk -v k="$kept" -v w="$FRAME_W" -v h="$FRAME_H" 'BEGIN{
        r = (w>0 ? h/w : 1);            # cell aspect: >1 for portrait
        c = int(sqrt(k*r) + 0.999);     # square-ish sheet
        if (c < 1) c = 1;
        if (c > k) c = k;
        print c
    }')"
    ROWS="$(awk -v k="$kept" -v c="$COLS" 'BEGIN{r=int((k+c-1)/c); print (r<1?1:r)}')"

    # Cell size is budgeted by AREA, not width. A width cap silently punishes
    # landscape sources: a large landscape frame capped by width is a much
    # bigger downscale than the same cap on a portrait frame. Equal area
    # gives both orientations the same number of pixels to render text with.
    CELL_W="$(awk -v w="$FRAME_W" -v h="$FRAME_H" -v area="$CELL_AREA" 'BEGIN{
        if (w <= 0 || h <= 0) { print 480; exit }
        scale = sqrt(area / (w * h));
        if (scale > 1) scale = 1;   # never upscale — no detail to gain
        c = w * scale;
        if (c < 280) c = 280;       # a tiny source still needs a readable cell
        printf "%d", int(c/2)*2     # even width: some encoders reject odd dimensions
    }')"

    # drawtext runs BEFORE the tile scales the frame down, so the size must be
    # given in SOURCE pixels: pick how tall the label should be in the
    # finished sheet, then divide by the downscale factor.
    LABEL_IN_SHEET=26 # px, in the finished contact sheet
    FONT_SIZE="$(awk -v w="$FRAME_W" -v c="$CELL_W" -v t="$LABEL_IN_SHEET" 'BEGIN{
        f = (c > 0 ? t * w / c : t);   # undo the tile downscale
        if (f < 14) f = 14;
        print int(f)
    }')"
    BOX_BORDER="$(awk -v f="$FONT_SIZE" 'BEGIN{b=int(f/6); if(b<2)b=2; print b}')"

    SHEET="$TARGET_DIR/contact-sheet.jpg"

    # drawtext needs libfreetype, which several ffmpeg builds omit; without it
    # the sheet loses its timestamps but is still worth producing.
    # Capture first, then match: `grep -q` in a pipe exits early, ffmpeg dies
    # of SIGPIPE, and pipefail turns that into a false "filter missing".
    FILTERS="$(ffmpeg -hide_banner -filters 2>/dev/null || true)"
    LABELLED=1
    printf '%s' "$FILTERS" | command grep -q ' drawtext ' || LABELLED=0

    if [ "$LABELLED" -eq 1 ]; then
        ffmpeg -hide_banner -nostats -nostdin -y -loglevel error -framerate 1 -i "$FRAMES_DIR/frame_%03d.jpg" \
            -vf "drawtext=text='%{eif\:n*$INTERVAL\:d}s':x=$BOX_BORDER:y=$BOX_BORDER:fontsize=$FONT_SIZE:fontcolor=yellow:box=1:boxcolor=black@0.75:boxborderw=$BOX_BORDER,scale=$CELL_W:-1,tile=${COLS}x${ROWS}:margin=8:padding=6:color=white" \
            -frames:v 1 -q:v "$JPEG_QUALITY" "$SHEET"
    else
        note "ffmpeg has no drawtext (libfreetype) — contact sheet will have no timestamps"
        ffmpeg -hide_banner -nostats -nostdin -y -loglevel error -framerate 1 -i "$FRAMES_DIR/frame_%03d.jpg" \
            -vf "scale=$CELL_W:-1,tile=${COLS}x${ROWS}:margin=8:padding=6:color=white" \
            -frames:v 1 -q:v "$JPEG_QUALITY" "$SHEET"
    fi

    [ -s "$SHEET" ] || die "contact sheet was not written"
fi

# --- transcript, only when the audio carries signal (unless forced) --------

TRANSCRIPT_STATE="skipped (transcript: never)"
if [ "$TRANSCRIPT_MODE" != "never" ]; then
    has_audio="$(ffprobe -v error -select_streams a -show_entries stream=codec_type -of csv=p=0 "$SOURCE_MP4" 2>/dev/null || true)"
    if [ -z "$has_audio" ]; then
        TRANSCRIPT_STATE="skipped (no audio track)"
    else
        # A present stream is not signal: the muxer emits warnings that swamp
        # the filter output, so this needs its own isolated invocation.
        mean="$(ffmpeg -hide_banner -nostats -i "$SOURCE_MP4" -map 0:a:0 -af volumedetect -f null /dev/null 2>&1 \
            | command grep -oE 'mean_volume: -?[0-9.]+' | command grep -oE '\-?[0-9.]+$' | head -1 || true)"
        if [ -z "$mean" ]; then
            TRANSCRIPT_STATE="skipped (could not measure loudness)"
        elif [ "$TRANSCRIPT_MODE" != "always" ] && awk -v m="$mean" -v f="$SILENCE_FLOOR" 'BEGIN{exit !(m < f)}'; then
            TRANSCRIPT_STATE="skipped (silent track, ${mean} dB)"
        elif ! command -v whisper >/dev/null 2>&1; then
            TRANSCRIPT_STATE="skipped (whisper not installed; audio has signal at ${mean} dB)"
        else
            note "transcribing (${mean} dB)"
            # json, not txt: the segment timings are what tie speech to frames.
            if whisper "$SOURCE_MP4" --model "$WHISPER_MODEL" --output_format json --output_dir "$WORK" >/dev/null 2>&1; then
                out=("$WORK"/*.json)
                if [ ${#out[@]} -gt 0 ]; then
                    # Unreachable today (RAW_COUNT > 0 is enforced earlier and
                    # the loop that fills FRAME_TIMES always keeps index 0),
                    # but bash 3.2 + set -u throws "unbound variable" on an
                    # empty array expansion — guard it anyway, the same trap
                    # CLAUDE.md documents for every other array here.
                    if [ ${#FRAME_TIMES[@]} -gt 0 ]; then
                        printf '%s\n' "${FRAME_TIMES[@]}" > "$WORK/frame_times.txt"
                    else
                        : > "$WORK/frame_times.txt"
                    fi
                    if [ "$WRITE_FRAMES" -eq 1 ] && python3 "$SCRIPT_DIR/lib/group-transcript.py" \
                        "${out[0]}" "$WORK/frame_times.txt" "$DURATION" \
                        "$TARGET_DIR/transcript.txt" 2>/dev/null; then
                        TRANSCRIPT_STATE="written (${mean} dB)"
                    else
                        # Grouping needs the frame files (--no-frames drops
                        # them) and is a convenience regardless — never lose
                        # the transcript text over it.
                        python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['text'].strip())" \
                            "${out[0]}" > "$TARGET_DIR/transcript.txt" 2>/dev/null \
                            && TRANSCRIPT_STATE="written, ungrouped (${mean} dB)" \
                            || TRANSCRIPT_STATE="whisper output could not be read"
                    fi
                else
                    TRANSCRIPT_STATE="whisper produced no output"
                fi
            else
                TRANSCRIPT_STATE="whisper failed"
            fi
        fi
    fi
fi

# --- keepSource: delete the video if the mode says so -----------------------
# Deletion is the LAST thing that touches source.mp4 — Whisper transcribes
# from it above, and any future --force re-extraction needs it present until
# this point.
KEEP_DECISION="kept"
case "$KEEP_SOURCE" in
    never) KEEP_DECISION="deleted (--keep-source never)" ;;
    always) KEEP_DECISION="kept (--keep-source always)" ;;
    auto)
        if [ "$OUTPUT_IS_TEMP" -eq 1 ]; then
            KEEP_DECISION="deleted (auto: temp output dir)"
        else
            KEEP_DECISION="kept (auto: persistent output dir)"
        fi
        ;;
esac
case "$KEEP_DECISION" in
    deleted*) rm -f "$TARGET_DIR/source.mp4" ;;
esac

# --- meta + summary ----------------------------------------------------

# Built by python, not a heredoc: a `"` in a filename or CDN url would
# otherwise interpolate straight into the document and produce invalid JSON
# that nothing notices until a reader chokes on it.
DEDUPED_JSON=false
[ "$DEDUPE" -eq 1 ] && DEDUPED_JSON=true
SHARE_ID="$SHARE_ID" SHARE_URL="${SHARE_URL:-}" CDN_URL="${CDN_URL:-}" \
EXTRACTOR="$EXTRACTOR" \
RECORDED="$RECORDED" DATE_SOURCE="$DATE_SOURCE" DURATION="$DURATION" \
KEPT="$kept" INTERVAL="$INTERVAL" SAMPLE_FPS="$SAMPLE_FPS" \
DEDUPED="$DEDUPED_JSON" RAW_COUNT="$RAW_COUNT" TRANSCRIPT_STATE="$TRANSCRIPT_STATE" \
SOURCE_KEPT="$KEEP_DECISION" \
python3 -c '
import json, os, sys
e = os.environ
json.dump({
    "id": e["SHARE_ID"],
    "source_url": e["SHARE_URL"],
    "resolved_url": e["CDN_URL"],
    "extractor": e["EXTRACTOR"],
    "recorded": e["RECORDED"],
    "recorded_source": e["DATE_SOURCE"],
    "duration_sec": float(e["DURATION"]),
    "frames": int(e["KEPT"]),
    "frame_interval_sec": float(e["INTERVAL"]),
    "sampled_fps": float(e["SAMPLE_FPS"]),
    "deduped": e["DEDUPED"] == "true",
    "frames_before_thinning": int(e["RAW_COUNT"]),
    "timestamps_approximate": True,
    "transcript": e["TRANSCRIPT_STATE"],
    "source_video": e["SOURCE_KEPT"],
}, open(sys.argv[1], "w"), indent=2)
' "$TARGET_DIR/meta.json" || die "could not write meta.json"

printf '\n%s  %ss  %s frames (from %s)  recorded %s (%s)\n' \
    "$SHARE_ID" "$DURATION" "$kept" "$RAW_COUNT" "$RECORDED" "$DATE_SOURCE"
if [ -n "$SHEET" ]; then printf 'sheet:      %s\n' "$SHEET"; fi
if [ "$WRITE_FRAMES" -eq 1 ]; then printf 'frames:     %s\n' "$FRAMES_DIR"; fi
printf 'transcript: %s\n' "$TRANSCRIPT_STATE"
printf 'source:     %s\n' "$KEEP_DECISION"
# ⚠️ Must be a real `if`, not `[ ... ] && printf`: this is the LAST statement
# in the script, and a short-circuit that evaluates false becomes the
# script's own exit code even though everything above succeeded. Hit this
# for real while writing it — the false branch (OUTPUT_IS_TEMP=0) exited 1
# after a fully successful run.
if [ "$OUTPUT_IS_TEMP" -eq 1 ]; then
    printf 'output:     %s (OS temp dir — pass --output to persist)\n' "$TARGET_DIR"
fi

exit 0
