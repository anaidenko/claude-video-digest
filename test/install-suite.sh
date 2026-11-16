#!/usr/bin/env bash
# Checks for the npx installer, bin/claude-video-digest.js.
#
#   ./test/install-suite.sh
#
# `claude` is shadowed by a stub that records every call and answers the two
# `--json` queries from STUB_MARKETPLACES / STUB_PLUGINS, so nothing is
# installed. Needs only node; no ffmpeg or Claude Code.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$REPO_ROOT/bin/claude-video-digest.js"
PLUGIN_ID="claude-video-digest@anaidenko"
PASS=0
FAIL=0

NODE="$(command -v node)" || {
    printf 'node not found; the installer needs it.\n' >&2
    exit 1
}

STUB_BIN="$(mktemp -d)"
EMPTY_BIN="$(mktemp -d)"
TOOLS_BIN="$(mktemp -d)"
STUB_LOG="$STUB_BIN/calls.log"
trap 'rm -rf "$STUB_BIN" "$EMPTY_BIN" "$TOOLS_BIN"' EXIT

cat >"$STUB_BIN/claude" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >>"$STUB_LOG"
case "\$*" in
    "plugin marketplace list --json") printf '%s\n' "\${STUB_MARKETPLACES:-[]}" ;;
    "plugin list --json") printf '%s\n' "\${STUB_PLUGINS:-[]}" ;;
    *) [ -n "\${STUB_FAIL_ON:-}" ] && [ "\$*" = "\$STUB_FAIL_ON" ] && exit 7 ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/claude"

# Stand-ins for the tools the plugin needs, so the dependency hints can be
# checked both ways without depending on what this machine has installed.
for tool in ffmpeg ffprobe python3 whisper yt-dlp; do
    printf '#!/bin/sh\nexit 0\n' >"$TOOLS_BIN/$tool"
    chmod +x "$TOOLS_BIN/$tool"
done

check() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        printf '  ok    %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$name" "$expected" "$actual"
        FAIL=$((FAIL + 1))
    fi
}

contains() {
    local name="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*)
            printf '  ok    %s\n' "$name"
            PASS=$((PASS + 1))
            ;;
        *)
            printf '  FAIL  %s\n        missing: %s\n        in:      %s\n' "$name" "$needle" "$haystack"
            FAIL=$((FAIL + 1))
            ;;
    esac
}

lacks() {
    local name="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*)
            printf '  FAIL  %s\n        unexpected: %s\n' "$name" "$needle"
            FAIL=$((FAIL + 1))
            ;;
        *)
            printf '  ok    %s\n' "$name"
            PASS=$((PASS + 1))
            ;;
    esac
}

# run [VAR=value ...] [-- installer args]: sets OUT, CODE and CALLS (the stub's
# calls joined by " | "). PATH holds the stub and the tool stand-ins only,
# unless the caller passes its own PATH=.
run() {
    local -a envs=() args=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    [ "${1:-}" = "--" ] && shift
    args=("$@")
    : >"$STUB_LOG"
    OUT="$(env PATH="$STUB_BIN:$TOOLS_BIN" ${envs[@]+"${envs[@]}"} "$NODE" "$INSTALLER" ${args[@]+"${args[@]}"} 2>&1 </dev/null)"
    CODE=$?
    CALLS="$(paste -sd'|' "$STUB_LOG" | sed 's/|/ | /g')"
}

OURS_GITHUB='[{"name":"anaidenko","source":"github","repo":"anaidenko/claude-plugins"}]'
OURS_URL='[{"name":"anaidenko","source":"git","url":"https://github.com/anaidenko/claude-plugins.git"}]'
FOREIGN='[{"name":"anaidenko","source":"github","repo":"anaidenko/claude-video-digest"}]'
INSTALLED="[{\"id\":\"$PLUGIN_ID\",\"version\":\"1.1.0\",\"scope\":\"user\"}]"
OTHER_PLUGIN='[{"id":"something-else@anaidenko","version":"1.0.0","scope":"user"}]'

printf '═══ npx installer\n'

run
check "fresh machine: adds the marketplace, then installs" \
    "plugin marketplace list --json | plugin marketplace add anaidenko/claude-plugins | plugin list --json | plugin install $PLUGIN_ID" \
    "$CALLS"
check "fresh machine: exits 0" "0" "$CODE"
contains "fresh machine: says it installed" "Installed $PLUGIN_ID" "$OUT"
contains "fresh machine: says to restart" "Restart Claude Code" "$OUT"

run STUB_MARKETPLACES="$OURS_GITHUB" STUB_PLUGINS="$OTHER_PLUGIN"
check "our marketplace present: refreshes it instead of adding" \
    "plugin marketplace list --json | plugin marketplace update anaidenko | plugin list --json | plugin install $PLUGIN_ID" \
    "$CALLS"

run STUB_MARKETPLACES="$OURS_URL"
contains "our marketplace added by git URL counts as ours" "plugin marketplace update anaidenko" "$CALLS"

run STUB_MARKETPLACES="$OURS_GITHUB" STUB_PLUGINS="$INSTALLED"
check "already installed: updates instead of installing" \
    "plugin marketplace list --json | plugin marketplace update anaidenko | plugin list --json | plugin update $PLUGIN_ID" \
    "$CALLS"
contains "already installed: says it is up to date" "$PLUGIN_ID is installed and up to date" "$OUT"

# The guard that protects a user's setup: a stray "anaidenko" marketplace must
# be left alone.
run STUB_MARKETPLACES="$FOREIGN"
check "foreign marketplace: exits 1" "1" "$CODE"
check "foreign marketplace: makes no change at all" "plugin marketplace list --json" "$CALLS"
contains "foreign marketplace: names what it points at" "anaidenko/claude-video-digest" "$OUT"
contains "foreign marketplace: prints the fix" "claude plugin marketplace remove anaidenko" "$OUT"

run STUB_FAIL_ON="plugin install $PLUGIN_ID"
check "a failing install exits 1" "1" "$CODE"
contains "a failing install says which command failed" "plugin install $PLUGIN_ID\` failed" "$OUT"

run STUB_MARKETPLACES="not json"
check "unreadable --json output: exits 1" "1" "$CODE"
check "unreadable --json output: makes no change" "plugin marketplace list --json" "$CALLS"

# Dependency hints: the plugin is installed either way, so the exit stays 0.
run
lacks "all tools present: no required-tool warning" "Required, not found" "$OUT"
lacks "all tools present: no optional-tool note" "Optional, not found" "$OUT"

run PATH="$STUB_BIN"
check "no tools: still exits 0 (the plugin did install)" "0" "$CODE"
contains "no tools: names the missing required ones" "Required, not found: ffmpeg, ffprobe, python3" "$OUT"
contains "no tools: names the missing optional ones" "Optional, not found: whisper, yt-dlp" "$OUT"
# YouTube has no fallback without yt-dlp, so its absence gets its own line,
# with this platform's install command.
case "$(uname -s)" in
    Darwin) YTDLP_INSTALL="brew install yt-dlp deno" ;;
    *) YTDLP_INSTALL="pipx install yt-dlp" ;;
esac
contains "no tools: says YouTube links need yt-dlp, and how to get it" "YouTube links need yt-dlp: $YTDLP_INSTALL" "$OUT"
run
lacks "all tools present: no YouTube note" "YouTube links need" "$OUT"

: >"$STUB_LOG"
OUT="$(env PATH="$EMPTY_BIN" "$NODE" "$INSTALLER" 2>&1 </dev/null)"
CODE=$?
check "no claude on PATH: exits 1" "1" "$CODE"
contains "no claude on PATH: says so" "not found on PATH" "$OUT"

run -- --help
check "--help: exits 0" "0" "$CODE"
check "--help: calls nothing" "" "$CALLS"
contains "--help: shows the npx line" "npx @anaidenko/claude-video-digest" "$OUT"

run -- --bogus
check "an unknown flag: exits 1" "1" "$CODE"
check "an unknown flag: calls nothing" "" "$CALLS"

# ── --uninstall ──
# HOME points at a scratch dir holding what the plugin leaves behind, so the
# real one is never touched. XDG_* are blanked so the HOME defaults apply.
FAKE_HOME="$(mktemp -d)"
trap 'rm -rf "$STUB_BIN" "$EMPTY_BIN" "${TOOLS_BIN:-}" "$FAKE_HOME"' EXIT
seed_home() {
    rm -rf "$FAKE_HOME" && mkdir -p "$FAKE_HOME"
    mkdir -p "$FAKE_HOME/.config/video-digest"
    printf '{}\n' >"$FAKE_HOME/.config/video-digest/config.json"
}
UNINSTALL_ENV=(HOME="$FAKE_HOME" XDG_STATE_HOME= XDG_CONFIG_HOME=)

seed_home
run "${UNINSTALL_ENV[@]}" STUB_PLUGINS="$INSTALLED" -- --uninstall
check "--uninstall: removes the user install, and touches no marketplace" \
    "plugin list --json | plugin uninstall $PLUGIN_ID" "$CALLS"
check "--uninstall: exits 0" "0" "$CODE"
contains "--uninstall: says so" "Uninstalled $PLUGIN_ID" "$OUT"
check "--uninstall: keeps the user's config" "kept" "$([ -f "$FAKE_HOME/.config/video-digest/config.json" ] && echo kept || echo gone)"
contains "--uninstall: says where the config is" "Kept your config: ~/.config/video-digest/config.json" "$OUT"
contains "--uninstall: points at the marketplace it leaves" "claude plugin marketplace remove anaidenko" "$OUT"

seed_home
run "${UNINSTALL_ENV[@]}" -- --uninstall
check "--uninstall, not installed: only looks" "plugin list --json" "$CALLS"
check "--uninstall, not installed: exits 0" "0" "$CODE"
contains "--uninstall, not installed: says so" "was not installed for your user" "$OUT"

run "${UNINSTALL_ENV[@]}" STUB_PLUGINS="[{\"id\":\"$PLUGIN_ID\",\"scope\":\"project\",\"projectPath\":\"/work/app\"}]" -- --uninstall
check "--uninstall, project scope only: removes nothing it cannot reach" "plugin list --json" "$CALLS"
contains "--uninstall, project scope only: names it" "Still installed with --scope project in /work/app" "$OUT"

run "${UNINSTALL_ENV[@]}" STUB_PLUGINS="$INSTALLED" STUB_FAIL_ON="plugin uninstall $PLUGIN_ID" -- --uninstall
check "--uninstall: a failing uninstall exits 1" "1" "$CODE"

run -- --uninstall --bogus
check "--uninstall with a stray flag: exits 1" "1" "$CODE"
check "--uninstall with a stray flag: calls nothing" "" "$CALLS"

printf '\n%d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
