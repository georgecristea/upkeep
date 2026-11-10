# upkeep CLI — design notes

One command that keeps a curated list of programs on the latest version, hands-free, without
sacrificing security. Runs manually (`upkeep update`) or on a nightly schedule.

## Principles

1. **Simple.** One TypeScript file, one JSON manifest, zero npm dependencies. Node 22.18+ runs `.ts` directly (type stripping), so there is no build step, no bundler, no `node_modules`.
2. **Curated, not "update everything".** Only what is in `upkeep.json` gets touched.
3. **Channel-correct.** Desktop apps via Homebrew cask, CLI tools via npm, self-updating tools via
   their own updater. Never fight a vendor's auto-updater.
4. **Non-interactive by construction.** No TTY, no sudo, no prompts. Anything that would prompt is a
   failure, not a hang.
5. **Verify what you install.** Checksums from Homebrew, code signature and pinned Apple Team ID for
   every app, official npm registry only, no shell string interpolation anywhere.
6. **Fail loud, never fail silent.** Every run logs before/after versions and sends a macOS
   notification on completion or failure.

## Layout

```
upkeep/
  upkeep.ts            # the whole tool (~560 lines)
  upkeep.json          # your list of targets (git-ignored, created on first run)
  upkeep.example.json  # one entry of each kind
  bin/upkeep           # shell shim: finds node, exec node ../upkeep.ts "$@"
  docs/cli-design.md
  README.md
```

Install: `ln -s "$PWD/bin/upkeep" ~/.local/bin/upkeep` from the clone.

## The manifest

The list the author started with:


```jsonc
{
  "npmMinReleaseAgeHours": 24,        // decided: 24. 0 = always newest; see Security
  "targets": [
    // Desktop apps — Homebrew cask, greedy upgrade, signature verified
    { "kind": "cask",   "id": "claude",     "app": "Claude.app",    "teamId": "Q6L2SF6YDW" },
    { "kind": "cask",   "id": "chatgpt",    "app": "ChatGPT.app",   "teamId": "2DC432GLL2" },
    { "kind": "cask",   "id": "ollama-app", "app": "Ollama.app",    "teamId": "3MU9H2V9Y9" },
    { "kind": "cask",   "id": "cmux",       "app": "cmux.app",      "teamId": "7WLXT3NR37" },
    { "kind": "cask",   "id": "lm-studio",  "app": "LM Studio.app", "teamId": "D65G88RHWN" },
    { "kind": "cask",   "id": "cursor",     "app": "Cursor.app",    "teamId": "VDXQ22DGB9" },
    { "kind": "cask",   "id": "warp",       "app": "Warp.app",      "teamId": "2BBY89MBSN" },
    { "kind": "cask",   "id": "ghostty",    "app": "Ghostty.app",   "teamId": "24VZTF6M5V" },
    { "kind": "cask",   "id": "visual-studio-code", "app": "Visual Studio Code.app", "teamId": "UBF8T346G9" },

    // CLI tools — npm global, official registry
    { "kind": "npm",    "id": "@openai/codex" },
    { "kind": "npm",    "id": "@github/copilot" },

    // Self-updating tools — argv arrays, never shell strings
    { "kind": "native", "id": "claude-code", "version": ["claude", "--version"], "update": ["claude", "update"] },
    { "kind": "native", "id": "oh-my-zsh",   "update": ["zsh", "~/.oh-my-zsh/tools/upgrade.sh"] }
  ]
}
```

Adding a program = one line. Removing = delete the line. `upkeep add <id>` writes the line for you,
auto-detecting cask vs npm vs formula and reading the Team ID from the installed app.

## Adapters (the only real logic)

Each adapter implements three functions: `installed()`, `latest()`, `update()`.

| kind    | installed()                          | latest()                          | update()                                             |
|---------|--------------------------------------|-----------------------------------|------------------------------------------------------|
| cask    | `CFBundleShortVersionString` of .app | `brew info --cask --json=v2`      | `brew upgrade --cask --greedy <id>` then verify sig  |
| npm     | `npm ls -g --json`                   | `npm view <id> version` + `time`  | `npm install -g <id>@<version>`                      |
| native  | argv from manifest (optional)        | n/a (tool decides)                | argv from manifest                                   |
| formula | `brew list --versions`               | `brew info --json=v2`             | `brew upgrade <id>`                                  |

The cask adapter compares the app's real on-disk version to the cask version and skips the upgrade
when they already match. This avoids re-downloading an app that already auto-updated itself, which
plain `brew upgrade --greedy` would do. An app not yet managed by Homebrew is force-installed from
the cask once; Homebrew manages it from then on.

## Commands

```
upkeep check            # table: name, installed, latest, status. No changes. Exit 1 if outdated.
upkeep update [id...]   # update everything (or the named targets). Non-interactive.
                        # Running apps are skipped and reported; --force quits and updates them.
upkeep add <id>         # detect kind, append to manifest
upkeep remove <id>
upkeep list
upkeep schedule install | remove | status   # launchd LaunchAgent, nightly
upkeep log              # tail the latest run
```

Flags: `--dry-run`, `--json`, `--quiet`.

## Security

- **No sudo, ever.** The tool never elevates. Casks that require a `.pkg` installer with sudo are
  rejected by `upkeep add`. Everything runs as your user under launchd.
- **No shell.** Every subprocess is `spawn(binary, argv)`. No `sh -c`, no string templates, so a
  manifest entry can never inject a command.
- **Pinned binaries.** `brew`, `npm`, `node`, `codesign`, `spctl` are resolved to absolute paths at
  startup (`/opt/homebrew/bin/...` or `/usr/local/bin/...` for Homebrew, `/usr/bin/...`). `PATH` is not trusted, which also matters
  because launchd's `PATH` is minimal.
- **Cask integrity.** Homebrew verifies the vendor download against the SHA-256 in the cask
  (confirmed for every app in the list above, with versioned URLs on the vendor's own domain).
- **App signature + Team ID pin.** After every cask upgrade: `codesign --verify --deep --strict`,
  `spctl --assess --type execute` (notarization), and the bundle's `TeamIdentifier` must equal the
  Team ID pinned in the manifest. Mismatch = run fails, notification fires, exit non-zero. No
  auto-remediation; you look at it.
- **npm registry lock.** Refuses to run if `npm config get registry` is not
  `https://registry.npmjs.org/`. npm verifies tarball integrity against registry metadata.
- **npm release cooldown (optional).** `npmMinReleaseAgeHours` skips versions published less than N
  hours ago, using `npm view <pkg> time`. Every major npm supply-chain compromise so far was yanked
  within hours; a 24 h delay would have avoided all of them. Trade-off: you get new CLI releases a day
  late. Desktop apps are not delayed: they are signed, notarized, and checksummed.
- **Lock file** in `~/.upkeep/lock` so a manual run and a scheduled run can't overlap.
- **Audit log.** `~/Library/Logs/upkeep/<timestamp>.log` with every command, every version
  before/after, every verification result.
- **Running apps are skipped by default.** `upkeep update` checks whether any process lives inside
  the app bundle and skips it with `skipped (running) — use --force`. `--force` quits the app
  (AppleScript quit, then SIGTERM after 15 s), updates it, and **reopens it in the background** once
  the whole run is done. One rule, one flag, and it also covers running upkeep from inside cmux or
  Warp: the terminal is just another running app. A scheduled run passes `--force` because nobody
  is at the keyboard.

## Scheduling

Off by default; manual runs work well on a laptop that sleeps overnight. It is one command away. `upkeep schedule install` writes `~/Library/LaunchAgents/com.upkeep.plist`:

- `StartCalendarInterval` at 04:00 (configurable). Runs `upkeep update --force`.
- Absolute path to `node` and `upkeep.ts`, explicit `PATH`, `HOME`.
- Stdout/stderr to `~/Library/Logs/upkeep/`.
- launchd runs a missed job at next wake, so a sleeping Mac catches up in the morning.
- `osascript display notification` at the end: "upkeep: 3 updated, 0 failed" or "upkeep FAILED: …".

## Notes from the first migration (done with `upkeep update` itself)

1. Every desktop app not yet managed by Homebrew is **force-installed** from its cask by
   `upkeep update`, which is also its first real update. Homebrew's `--adopt` was tried first and
   dropped: it runs `chmod -R` on the existing bundle, and macOS App Management protection refused
   that for cmux and Ghostty (and made Homebrew ask for sudo). Reinstalling from the cask works and
   needs no special path, so the adopt branch was deleted.
2. Copilot CLI moved from cask to npm to keep all CLIs on one channel.
   `brew uninstall --cask copilot-cli` then `upkeep update @github/copilot`.
3. Claude Code: stays on the native installer. Turn its built-in auto-updater off
   (`autoUpdates: false`), so `claude update` from upkeep is the only updater. No collision.
4. Codex: already npm. Nothing to do.
5. Oh My Zsh: runs its own `upgrade.sh` directly, which is non-interactive.

## Build order (as built)


1. `upkeep.ts` skeleton: manifest loading, adapter interface, `check`, `list`. Test read-only.
2. `update` for npm + native. Test on Codex and Claude Code.
3. `update` for cask with signature verification. Test on one app.
4. Migration steps above.
5. `add` / `remove`, `schedule`, notifications, log.
6. README, symlink into `~/.local/bin`.

## Explicitly out of scope

- Updating all Homebrew formulae. Only listed targets. A `brew-all` target could be added later.
- Mac App Store apps (`mas`), pipx, cargo. Easy adapters later if needed.
- GUI, config UI, plugins, retries with backoff, anything clever.
