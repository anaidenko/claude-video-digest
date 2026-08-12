# Linux runner — for machines without macOS, and for verifying this script's
# portability (it is written to run identically on both).
#
#   docker build -t video-digest .
#   docker run --rm -v "$PWD:/work" -w /work video-digest <url|file.mp4> --output /work/out
#
# Debian's ffmpeg is built with libfreetype, which drawtext needs for the
# contact sheet's burned-in timestamps; several slimmer ffmpeg images omit it,
# and the sheet silently loses its labels rather than failing — `doctor`
# reports which case you're in.
#
# Whisper and yt-dlp are deliberately NOT installed by default: Whisper pulls
# PyTorch (~1 GB) for a step most recordings never need (skipped on silent
# tracks), and yt-dlp only matters for sites the built-in scraper can't
# resolve. Build with:
#   --build-arg WITH_WHISPER=1
#   --build-arg WITH_YTDLP=1

FROM debian:bookworm-slim

ARG WITH_WHISPER=0
ARG WITH_YTDLP=0

# python3 is NOT optional: it reads the config file and writes meta.json on
# every run, and the transcript grouper runs on it too. Without it the script
# refuses to start rather than failing after a download — see CLAUDE.md.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash ffmpeg curl ca-certificates python3 python3-pip \
    && if [ "$WITH_WHISPER" = "1" ]; then \
        pip3 install --no-cache-dir --break-system-packages openai-whisper; \
    fi \
    && if [ "$WITH_YTDLP" = "1" ]; then \
        pip3 install --no-cache-dir --break-system-packages yt-dlp; \
    fi \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/video-digest.sh /usr/local/bin/video-digest
COPY scripts/lib/ /usr/local/bin/lib/
RUN chmod +x /usr/local/bin/video-digest /usr/local/bin/lib/*.py

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/video-digest"]
