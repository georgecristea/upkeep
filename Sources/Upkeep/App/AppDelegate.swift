import AppKit
import MacUtilityKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MUKTheme.brand = MUKBrand(
            name: "Upkeep",
            tagline: "Your core tools, always current",
            symbol: "arrow.triangle.2.circlepath",
            accent: Color(red: 0.10, green: 0.62, blue: 0.55),
            accentSecondary: Color(red: 0.30, green: 0.80, blue: 0.60))

        let state = AppState()
        let statusBarController = StatusBarController(appState: state)
        state.requestShowPopover = { [weak statusBarController] in statusBarController?.showPopover() }

        self.appState = state
        self.statusBarController = statusBarController

        state.start()

        // `Upkeep --icon out.png` writes a 4x preview of every menu bar icon state and quits.
        if let path = Self.argument(after: "--icon") {
            MenuBarIcon.writePreview(to: path)
            NSApp.terminate(nil)
            return
        }
        // `open Upkeep.app --args --show` opens the popover right away (used by tests and scripts).
        // With `--tap x,y` it then clicks inside the real popover, and with `--snapshot out.png`
        // writes the popover's contents to a PNG and quits: an end-to-end UI test on the live popover.
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { statusBarController.showPopover() }
            if let tap = Self.tapPoint(height: MUKTheme.popoverHeight) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    guard let view = statusBarController.popoverContentView else { AppLog.write("tap: no popover window"); return }
                    Self.click(at: tap, in: view)
                }
            }
            if let path = Self.argument(after: "--snapshot") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                    if let view = statusBarController.popoverWindow?.contentView { Self.write(view: view, to: path) }
                    NSApp.terminate(nil)
                }
            }
            return
        }
        // `Upkeep --snapshot out.png [--screen settings|log|about]` renders the popover offscreen
        // once the first check completes, writes a PNG, and quits. UI verification without a desktop.
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index + 1]
            if let screenIndex = CommandLine.arguments.firstIndex(of: "--screen"), screenIndex + 1 < CommandLine.arguments.count {
                switch CommandLine.arguments[screenIndex + 1] {
                case "settings": state.popoverScreen = .settings
                case "log": state.popoverScreen = .log
                case "about": state.popoverScreen = .about
                default: break
                }
            }
            // `--run-update <id>[,<id>...]` (with --snapshot) clicks each target's update button back to
            // back through the app's own path (the second and later ones queue), then snapshots the
            // post-run state and summary.
            let updateIDs = Self.argument(after: "--run-update")?.split(separator: ",").map(String.init) ?? []
            snapshotWhenReady(state: state, to: path, updateIDs: updateIDs, attempts: 0)
        }
    }

    private var testRunStarted = false

    private func snapshotWhenReady(state: AppState, to path: String, updateIDs: [String], attempts: Int) {
        var ready = state.phase == .idle && (state.lastChecked != nil || state.cliProblem != nil)
        if ready, !updateIDs.isEmpty, !testRunStarted {
            testRunStarted = true
            for id in updateIDs where state.rows.contains(where: { $0.id == id }) {
                state.update(ids: [id], force: false)
            }
            ready = false
        } else if ready, testRunStarted, state.lastSummary == nil || !state.queued.isEmpty {
            ready = false
        }
        guard ready || attempts > 400 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.snapshotWhenReady(state: state, to: path, updateIDs: updateIDs, attempts: attempts + 1) }
            return
        }
        let view = NSHostingView(rootView: MainPopoverView(appState: state))
        let frame = NSRect(x: 0, y: 0, width: MUKTheme.popoverWidth, height: MUKTheme.popoverHeight)
        view.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        let tap = Self.tapPoint(height: frame.height)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if let tap { Self.click(at: tap, in: view) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            Self.write(view: view, to: path)
            NSApp.terminate(nil)
        }
    }

    // MARK: - Test-hook helpers

    private static func argument(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag), index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    /// `--tap x,y` in points from the top-left of the popover, converted to AppKit's bottom-left origin.
    private static func tapPoint(height: CGFloat) -> NSPoint? {
        guard let raw = argument(after: "--tap") else { return nil }
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return NSPoint(x: parts[0], y: Double(height) - parts[1])
    }

    /// `point` is in the view's coordinate space with a bottom-left origin (tapPoint already flipped it).
    /// The popover window is larger than its content (arrow + margins), so convert through the view.
    private static func click(at point: NSPoint, in view: NSView) {
        guard let window = view.window else { AppLog.write("tap: view has no window"); return }
        let local = view.isFlipped ? NSPoint(x: point.x, y: view.bounds.height - point.y) : point
        let inWindow = view.convert(local, to: nil)
        let hit = view.hitTest(view.convert(inWindow, from: nil)).map { String(describing: type(of: $0)) } ?? "nil"
        AppLog.write("tap at \(inWindow) (view \(local)) window=\(window.windowNumber) key=\(window.isKeyWindow) active=\(NSApp.isActive) hit=\(hit)")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            // Queue the events: a SwiftUI button press runs a tracking loop that pulls the mouse-up
            // from the event queue, so sending both directly would deadlock the app.
            if let event = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    private static func write(view: NSView, to path: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.stop()
    }
}
