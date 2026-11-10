import AppKit
import Combine
import MacUtilityKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let appState: AppState
    private var outsideClickMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var previousApp: NSRunningApplication?
    private var cancellable: AnyCancellable?

    init(appState: AppState) {
        self.appState = appState
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()

        // Dismissal is managed here (outside click + app resign). `.transient` dismissed the
        // popover on in-popover navigation in ClipVault; same lesson applies.
        popover.behavior = .applicationDefined
        popover.contentSize = NSSize(width: MUKTheme.popoverWidth, height: MUKTheme.popoverHeight)
        popover.contentViewController = NSHostingController(rootView: MainPopoverView(appState: appState))
        popover.delegate = self

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        refreshButton()

        // objectWillChange fires before the change; hopping through the run loop reads the new values.
        cancellable = appState.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshButton() }
    }

    /// Menu bar glyph + count badge reflect the app state at a glance.
    private func refreshButton() {
        guard let button = statusItem.button else { return }
        let mode: MenuBarIcon.Mode = appState.cliProblem != nil ? .problem : appState.phase == .updating ? .updating : .idle
        button.image = MenuBarIcon.image(mode: mode, count: appState.outdatedCount)
        button.title = ""
    }

    @objc func togglePopover(_ sender: AnyObject? = nil) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func closePopover() {
        guard popover.isShown else { return }
        AppLog.write("popover close requested")
        popover.performClose(nil)
    }

    /// The popover's window / hosting view while shown (used by the --show --tap test hook).
    var popoverWindow: NSWindow? {
        popover.isShown ? popover.contentViewController?.view.window : nil
    }
    var popoverContentView: NSView? {
        popover.isShown ? popover.contentViewController?.view : nil
    }

    func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        appState.popoverScreen = .overview
        appState.checkIfStale()

        // An LSUIElement app must activate to receive key events and outside clicks. The status-item
        // click counts as user interaction, so cooperative activation (macOS 14+) lets this succeed.
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        let popoverWindow = popover.contentViewController?.view.window
        popoverWindow?.makeKeyAndOrderFront(nil)
        // Clear the initial first responder so the first click on a header button isn't eaten.
        popoverWindow?.makeFirstResponder(nil)
        AppLog.write("popover shown; app active=\(NSApp.isActive) key=\(popoverWindow?.isKeyWindow ?? false)")

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main)
        { [weak self] _ in
            AppLog.write("app resigned active")
            Task { @MainActor in self?.closePopover() }
        }
    }

    private func teardownMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }
}

extension StatusBarController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        AppLog.write("popover closed")
        teardownMonitor()
        previousApp?.activate()
    }
}
