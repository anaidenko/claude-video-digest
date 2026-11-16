#!/usr/bin/env node
// Installs this plugin into Claude Code, updates it, or removes it.
//
//   npx @anaidenko/claude-video-digest               install, or update if installed
//   npx @anaidenko/claude-video-digest --uninstall   remove it and what it left behind
//   npx @anaidenko/claude-video-digest --help
//
// It runs the same `claude plugin` commands the README lists, so the plugin
// still comes from the anaidenko marketplace (git), never from this package.
// That keeps one delivery path for installed copies, whichever way they were
// first installed.
//
// This is not a hook, so the hooks' rule (fail silently, exit 0) does not
// apply: it runs once, by hand, and a failure nobody sees is a failure
// nobody fixes. Every failure exits non-zero and says why.
//
// Everything above the "This plugin" section is shared with the other
// anaidenko plugins' installers and reads its names from the manifests, so
// keep it identical across them.
'use strict';

const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const readJson = file => JSON.parse(fs.readFileSync(path.join(ROOT, file), 'utf8'));
const PLUGIN = readJson('.claude-plugin/plugin.json').name;
const PACKAGE = readJson('package.json');

const MARKETPLACE = 'anaidenko';
const MARKETPLACE_REPO = 'anaidenko/claude-plugins';
const PLUGIN_ID = `${PLUGIN}@${MARKETPLACE}`;
const README = `${PACKAGE.homepage}#readme`;

function fail(message) {
    process.stderr.write(`\n${message}\n`);
    process.exit(1);
}

function usage() {
    process.stdout.write(`Usage: npx ${PACKAGE.name} [--uninstall]

Installs the ${PLUGIN} plugin into Claude Code, or updates it if it is
already installed. It adds the ${MARKETPLACE_REPO} marketplace when missing,
then runs \`claude plugin install\` (or \`update\`).

  --uninstall   Remove the plugin, and the files it keeps outside Claude Code.
                Your own config is left in place, and its path is printed.

Details: ${README}
`);
}

// Runs `claude <args> --json` and returns the parsed output.
function claudeJson(args) {
    const r = spawnSync('claude', [...args, '--json'], { encoding: 'utf8' });
    if (r.error && r.error.code === 'ENOENT') {
        fail('Claude Code CLI (`claude`) not found on PATH.\n' +
            'Install Claude Code first: https://code.claude.com/docs\n' +
            'Then run this again.');
    }
    if (r.error || r.status !== 0) {
        fail(`\`claude ${args.join(' ')} --json\` failed:\n${(r.stderr || '').trim()}`);
    }
    try {
        return JSON.parse(r.stdout);
    } catch {
        fail(`Could not read the output of \`claude ${args.join(' ')} --json\`.\n` +
            'Your Claude Code may be too old for this installer; run the two\n' +
            `commands from ${README} instead.`);
    }
}

// Runs a mutating `claude` command in the open, so its own output shows.
function claude(args) {
    process.stdout.write(`\n$ claude ${args.join(' ')}\n`);
    const r = spawnSync('claude', args, { stdio: 'inherit' });
    if (r.error || r.status !== 0) {
        fail(`\`claude ${args.join(' ')}\` failed (exit ${r.status ?? r.error.code}).`);
    }
}

// True when the marketplace entry is ours, however it was added: the GitHub
// shorthand reports `repo`, a git URL reports `url`.
function isOurs(entry) {
    const repo = String(entry.repo || '').toLowerCase();
    const url = String(entry.url || '').toLowerCase();
    return repo === MARKETPLACE_REPO ||
        /github\.com[/:]anaidenko\/claude-plugins(\.git)?\/?$/.test(url);
}

function describe(entry) {
    return entry.repo || entry.url || entry.path || `a ${entry.source || 'different'} source`;
}

function onPath(cmd) {
    return (process.env.PATH || '').split(path.delimiter)
        .some(d => d && fs.existsSync(path.join(d, cmd)));
}

const home = () => os.homedir();
const tilde = p => (p.startsWith(home() + path.sep) ? `~${p.slice(home().length)}` : p);

function installedEntries() {
    const plugins = claudeJson(['plugin', 'list']);
    return Array.isArray(plugins) ? plugins.filter(p => p.id === PLUGIN_ID) : [];
}

function report(headline, lines) {
    process.stdout.write(`\n${headline}\n` +
        lines.map(line => `  - ${line}`).join('\n') + `\n\nMore: ${README}\n`);
}

function install() {
    const marketplaces = claudeJson(['plugin', 'marketplace', 'list']);
    const entry = Array.isArray(marketplaces) && marketplaces.find(m => m.name === MARKETPLACE);

    if (!entry) {
        claude(['plugin', 'marketplace', 'add', MARKETPLACE_REPO]);
    } else if (!isOurs(entry)) {
        // An early install may have registered a plugin's own repo under this
        // name. Removing a user's marketplace can take its plugins with it, so
        // that is their call, not this script's.
        fail(`A marketplace named "${MARKETPLACE}" already exists, but it points at\n` +
            `${describe(entry)}, not ${MARKETPLACE_REPO}. It is most likely left over\n` +
            'from an older install. To replace it, run:\n\n' +
            `  claude plugin marketplace remove ${MARKETPLACE}\n` +
            `  claude plugin marketplace add ${MARKETPLACE_REPO}\n\n` +
            'and then run this installer again.');
    } else {
        claude(['plugin', 'marketplace', 'update', MARKETPLACE]);
    }

    const installed = installedEntries().length > 0;
    claude(['plugin', installed ? 'update' : 'install', PLUGIN_ID]);

    // `claude plugin update` succeeds whether or not there was anything newer,
    // so claim only what is true either way.
    report(installed ? `${PLUGIN_ID} is installed and up to date.` : `Installed ${PLUGIN_ID}.`,
        nextSteps());
}

function uninstall() {
    const entries = installedEntries();
    const user = entries.filter(p => (p.scope || 'user') === 'user');
    // A project or local install belongs to that project's settings; removing
    // it from here would need that project's directory, so it is only named.
    const elsewhere = entries.filter(p => p.scope && p.scope !== 'user');

    if (user.length) claude(['plugin', 'uninstall', PLUGIN_ID]);

    const lines = [];
    for (const dir of leftovers()) {
        if (!fs.existsSync(dir)) continue;
        fs.rmSync(dir, { recursive: true, force: true });
        lines.push(`Removed ${tilde(dir)}`);
    }
    for (const file of keptFiles().filter(f => fs.existsSync(f))) {
        lines.push(`Kept your config: ${tilde(file)} (delete it if you no longer need it)`);
    }
    for (const p of elsewhere) {
        lines.push(`Still installed with --scope ${p.scope}${p.projectPath ? ` in ${tilde(p.projectPath)}` : ''}: ` +
            `run \`claude plugin uninstall ${PLUGIN_ID} --scope ${p.scope}\` there`);
    }
    lines.push(`The ${MARKETPLACE} marketplace stays, for its other plugins; ` +
        `\`claude plugin marketplace remove ${MARKETPLACE}\` removes it`);
    if (user.length) lines.push('Restart Claude Code, or run /reload-plugins in an open session.');

    report(user.length ? `Uninstalled ${PLUGIN_ID}.` : `${PLUGIN_ID} was not installed for your user.`, lines);
}

function main() {
    const args = process.argv.slice(2);
    if (args.includes('--help') || args.includes('-h')) {
        usage();
        return;
    }
    const removing = args.length === 1 && args[0] === '--uninstall';
    if (args.length > 0 && !removing) {
        usage();
        process.exit(1);
    }
    if (process.platform === 'win32') {
        fail(`${PLUGIN} supports macOS and Linux only. See ${README}`);
    }
    if (removing) uninstall();
    else install();
}

// ── This plugin ──────────────────────────────────────────────────────────────

// What it needs after install. The skill checks the same tools at run time and
// fails before doing any work; this only says so earlier.
function nextSteps() {
    const steps = ['Restart Claude Code, or run /reload-plugins in an open session.'];
    const missing = ['ffmpeg', 'ffprobe', 'python3'].filter(cmd => !onPath(cmd));
    if (missing.length) {
        const ffmpeg = process.platform === 'darwin' ? 'brew install ffmpeg' : 'sudo apt install ffmpeg';
        steps.push(`Required, not found: ${missing.join(', ')}. ffmpeg/ffprobe: ${ffmpeg}; python3: your OS package manager.`);
    }
    const optional = ['whisper', 'yt-dlp'].filter(cmd => !onPath(cmd));
    if (optional.length) {
        steps.push(`Optional, not found: ${optional.join(', ')} (whisper: transcripts; yt-dlp: YouTube, and sites the built-in scraper cannot read).`);
    }
    // A YouTube link has no fallback: without yt-dlp it is refused outright.
    if (!onPath('yt-dlp')) {
        const ytdlp = process.platform === 'darwin' ? 'brew install yt-dlp deno' : 'pipx install yt-dlp';
        steps.push(`YouTube links need yt-dlp: ${ytdlp}`);
    }
    return steps;
}

// Directories it keeps outside Claude Code, removed by --uninstall. Digests
// go to the OS temp dir or an --output the user chose, so there are none.
function leftovers() {
    return [];
}

// The user's own files: never removed, only pointed out.
function keptFiles() {
    const config = process.env.XDG_CONFIG_HOME || path.join(home(), '.config');
    return [path.join(config, 'video-digest', 'config.json')];
}

main();
