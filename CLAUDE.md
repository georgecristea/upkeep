# upkeep

Two parts in one repo: the **`upkeep` CLI** (`upkeep.ts`, zero deps, run by Node directly) that
keeps a curated list of programs current, and **Upkeep.app**, a menu bar companion built on
MacUtilityKit (github.com/georgecristea/MacUtilityKit) like VoxKey and ClipVault. Design notes:
`docs/cli-design.md` (CLI), `docs/app-design.md` (app). The app never reimplements an adapter; it
only runs the CLI.

The user's list is `upkeep.json` next to `upkeep.ts` (git-ignored, created empty on first run);
`upkeep.example.json` is the tracked example. Never copy the example over a real list: `update`
installs any listed cask that is missing.

## Build, install, verify

```sh
upkeep check                          # CLI, read-only
swift build                           # compile the app
./scripts/install.sh                  # package, install to /Applications, relaunch — after every change
.build/debug/Upkeep --snapshot out.png [--screen settings|log|about] [--run-update <id>]
.build/debug/Upkeep --show --tap 356,29 --snapshot out.png   # click the gear in the live popover
.build/debug/Upkeep --icon out.png    # 4x preview of every menu bar icon state
```

`--run-update` performs real updates. The app needs the CLI at `~/.local/bin/upkeep`
(`ln -s "$PWD/bin/upkeep" ~/.local/bin/upkeep` from the clone). Diagnostics:
`~/Library/Logs/upkeep/app.log` (app) and timestamped run logs (CLI).

To change MacUtilityKit alongside the app: `swift package edit MacUtilityKit --path ../MacUtilityKit`
(`swift package unedit MacUtilityKit` to go back); ship by tagging MacUtilityKit and bumping
`Package.resolved` here.

## Gotchas

- Activate with `NSApp.activate()`; the deprecated variant is ignored on macOS 26 and kills clicks.
- Never quit the Claude desktop app from a Claude Code session running inside it: it hosts the session.
- Homebrew `--adopt` is avoided (macOS App Management refuses its chmod); force-install instead.
