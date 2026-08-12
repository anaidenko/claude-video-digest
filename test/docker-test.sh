#!/usr/bin/env bash
# Runs the test suite inside the project's own Dockerfile image, so a
# contributor without Linux (or without wanting to trust their host bash) can
# still get the cross-platform signal `npm test` gives natively.
#
# The Dockerfile's own ENTRYPOINT is the tool itself, not a shell — this
# builds the same image and overrides the entrypoint for the test run only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="video-digest-test"

docker build -t "$IMAGE" "$REPO_ROOT"

# The repo is mounted read-only and copied inside the container before the
# run: the test suite writes fixtures and cache dirs under $REPO_ROOT-derived
# paths in places, and a read-only bind mount would fail those writes.
docker run --rm --entrypoint bash -v "$REPO_ROOT:/repo:ro" -w /tmp "$IMAGE" -c '
    cp -r /repo /work-copy
    cd /work-copy
    chmod +x scripts/video-digest.sh test/run-tests.sh
    ./test/run-tests.sh
'
