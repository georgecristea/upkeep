# Upkeep.app — menu bar companion design notes

> Status 2026-09-13: implemented. Every screen and the
> app-driven update path were verified with offscreen snapshots. Deviations from the plan below:
> `check --json` now reports `running` for apps so "Quit & update" appears before any run; failures
> from a run stay visible across the read-only re-check; `--snapshot`/`--run-update` test hooks added.
>
> 2026-09-14 (0.1.2): **update queue.** Runs are sequential (the CLI and Homebrew hold locks), but
> clicks are not: a row clicked during a run shows "Queued" with a cancel control and runs as the
> next batch (forced and non-forced targets batch separately); rows already handed to the CLI show
> "Waiting", the active one a spinner. One re-check, summary, and notification after the queue
> drains. Update all and refresh stay disabled during a run. `--run-update a,b` tests it.
>
> 2026-09-14 (0.1.3): **compact menu bar icon.** The count is a small digit set inside the ring of
> the arrows (one template image, `MenuBarIcon`) instead of text beside the glyph, so the status
> item is as narrow as any other icon. "9+" past nine; the outlined-circle variant while updating;
> a warning triangle when the CLI is missing. `--icon out.png` renders all states at 4x.

A thin macOS menu bar app built on MacUtilityKit (like VoxKey and ClipVault)
that wraps the `upkeep` CLI. The CLI stays the engine and the only source of truth; the app is a
face: a badge, a list, buttons, logs.

## Division of labour (the one rule)

| CLI owns                                              | App owns                                          |
|-------------------------------------------------------|---------------------------------------------------|
| the manifest, every adapter, verification, cooldown   | rendering, timers, notifications with actions     |
| lock file, audit log                                  | the badge in the menu bar                         |
| `check --json`, `update --json` (NDJSON progress)     | per-row / update-all buttons, quit-and-update     |

The app never reimplements an adapter. If it needs something new, the CLI grows a flag.
Same repo so the JSON contract and the app version together; `Package.swift` sits at the repo
root, next to the CLI files.

## CLI adaptations

1. `update --json` streams **NDJSON events** so the app can show live progress:
   `{"event":"start","targets":[ids]}` → `{"event":"updating","id"}` → `{"event":"result", …row}`
   → `{"event":"done","updated":n,"skipped":n,"failed":n,"log":path}`.
   Human output is unchanged without `--json`.
2. `--no-notify` suppresses the CLI's osascript notification (the app posts its own, with an action).
3. Nothing else. `check --json` already returns the rows the app needs.

## What the app does (judgment calls)

**Menu bar item.** Brand symbol, template-tinted. When updates are available, a small count badge
sits next to it ("3"). While an update runs the symbol swaps to a spinning-style glyph. On error,
an exclamation variant. Click → popover.

**Overview screen (root).**
- Header (MUKHeader): "Upkeep" + live subtitle: "All 13 up to date", "3 updates available",
  "Updating cursor…", or "Checking…". Trailing: refresh, gear, quit (same trio as ClipVault).
- Summary card (MUKCard): headline status, "Last checked 4 min ago", and the primary
  **Update all** button. Update all runs `upkeep update --json --no-notify` with *no* `--force`:
  running apps are reported as skipped, each with its own **Quit & update** button. A destructive
  step (quitting an app you are using) always stays a per-app, explicit click.
- Target list, grouped: **Apps** (casks), **CLI tools** (npm/formula), **Self-updating** (native).
  Row: real app icon for casks (NSWorkspace) or a symbol; name; `installed → latest` in
  monospaced digits; MUKBadge for status; a trailing action button (update / quit & update) when
  applicable; an inline note ("running", "signature verified", error text). A row being updated
  shows an indeterminate MUKProgressBar under it.
- Empty/error state (MUKEmptyState) when the CLI is not found at `~/.local/bin/upkeep` or node is
  missing, with the exact fix.
- Footer (MUKStatusFooter): last outcome, e.g. "2 updated, 1 skipped · 12:04".

**Settings screen (in-popover, MUKSettingsRow).**
- Check automatically: Off / every hour / every 6 hours / daily (default 6 hours). A check is a
  read-only `upkeep check`; it never updates by itself. The app is the passive watcher; the human
  clicks update. (Unattended updating stays the CLI's `schedule` feature, by design.)
- Notify when updates are available (default on). Notification carries an "Update all" action.
- Launch at login (MUKLaunchAtLoginManager).
- Edit target list… opens `upkeep.json` in the default editor. Adding/removing stays a one-line
  edit or `upkeep add`; a picker UI would be a second manifest editor to keep in sync. Not worth it.
- About Upkeep.

**Log screen.** The latest run log from `~/Library/Logs/upkeep/`, monospaced, with a Reveal in
Finder button. Reachable from the footer and the summary card after a run.

**About screen.** Same layout as ClipVault's: brand icon, version, copyright, MUK ack.

## Behaviour details

- On launch: check immediately, then on the interval. Also re-check when the popover opens if the
  last check is older than 10 minutes.
- Exactly one CLI process at a time. The CLI's own lock reports a concurrent terminal run as
  "another upkeep run is active"; the app shows that in the footer, no crash.
- After any update run, the app re-runs check so the list reflects reality (not the run output).
- Update-all and per-row updates both stream; rows flip to "updating" as events arrive.
- Notifications via UNUserNotificationCenter (works for an ad-hoc-signed bundled app). Actions:
  "Update all" (runs a non-forced update) and "Show" (opens popover).
- The app is the responsible process for macOS App Management. If that permission is ever needed,
  it is Upkeep's own entry, not a terminal's.

## Learnings carried over from VoxKey / ClipVault

- Popover behaviour is `.applicationDefined` with an outside-click monitor and resign-active
  observer, not `.transient`: transient dismissed on in-popover navigation.
- LSUIElement apps must `NSApp.activate` before showing the popover and clear the first responder
  so the first header click is not eaten. Restore the previous app on close.
- Settings / About / Log are in-popover screens with MUKBackHeader, never separate windows.
- Observe nested ObservableObjects directly in views; a change one level down does not re-render.
- `MUKTheme.brand` is set once in AppDelegate. Brand for Upkeep: symbol
  `arrow.triangle.2.circlepath`, teal-green gradient (distinct from VoxKey purple, ClipVault blue).
- Packaging: copy `package-app.sh`, `make-dmg.sh`, `notarize.sh`, `make-icon.swift` and adapt
  names. Universal build with host-arch fallback. Ad-hoc signing fallback when no identity exists.
- Reusable UI goes to MacUtilityKit. One addition planned: `MUKPrimaryButton` (gradient CTA),
  which ClipVault/VoxKey can adopt later. Everything else is Upkeep-specific.

## Signing

Without an Apple Development or Developer ID certificate, the build is **ad-hoc signed** (what the sibling scripts fall back to). That is
fine for local use. Notarization needs the one-time Apple Developer steps in `notarize.sh`.

## Layout

```
Package.swift                 (root, like siblings; depends on MacUtilityKit)
Sources/Upkeep/
  UpkeepMain.swift
  App/AppDelegate.swift  AppState.swift  AppSettings.swift
  Services/UpkeepCLI.swift  (Process runner, NDJSON parser, CLI discovery)
           Notifier.swift   (UNUserNotificationCenter + actions)
  Models/Target.swift        (Row / Status / Kind decoding, grouping)
  UI/StatusBarController.swift  MainPopoverView.swift  OverviewView.swift  TargetRowView.swift
     SettingsView.swift  LogView.swift  AboutView.swift
Packaging/Info.plist  Upkeep.entitlements  Upkeep.icns (generated)
scripts/package-app.sh  make-dmg.sh  notarize.sh  make-icon.swift
```

Target size: ~1,100 lines of Swift. macOS 14+, Swift 5 language mode, same as ClipVault.

## Build order

1. CLI: NDJSON events for `update --json`, `--no-notify`. Test from the terminal.
2. MacUtilityKit: `MUKPrimaryButton`. Commit there.
3. App skeleton: Package.swift, main, AppDelegate, StatusBarController, empty popover. Build.
4. UpkeepCLI service + models; AppState with check/update; Overview list. Build, run, screenshot.
5. Settings, Log, About screens; timer; notifications; badge.
6. Packaging scripts, icon, ad-hoc signed `dist/Upkeep.app`, install to /Applications.
7. Test: check, per-row update on a deliberately downgraded npm package, update all, skipped
   running app with quit & update visible, notification, log screen.
