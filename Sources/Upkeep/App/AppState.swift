import AppKit
import Combine
import MacUtilityKit
import SwiftUI

enum PopoverScreen {
    case overview
    case settings
    case log
    case about
}

enum Phase: Equatable {
    case idle
    case checking
    case updating
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var rows: [TargetRow] = []
    @Published private(set) var phase: Phase = .idle
    /// Targets handed to the CLI run in progress (the current batch).
    @Published private(set) var inFlight: Set<String> = []
    /// The target the CLI is working on right now.
    @Published private(set) var activeID: String?
    /// Targets clicked while a run was in progress; they run as the next batch. Cancellable.
    @Published private(set) var queued: [String] = []
    @Published private(set) var lastChecked: Date?
    @Published private(set) var lastSummary: String?
    @Published private(set) var lastLogURL: URL?
    @Published private(set) var lastMessage: MUKStatusMessage?
    /// Set when the CLI cannot be found or fails outright; the overview shows an empty state.
    @Published private(set) var cliProblem: String?
    @Published var popoverScreen: PopoverScreen = .overview

    let settings: AppSettings
    let launchAtLoginManager: MUKLaunchAtLoginManager
    let notifier = Notifier()

    /// Wired by AppDelegate to the status-bar popover.
    var requestShowPopover: (() -> Void)?

    private(set) var cli: UpkeepCLI?
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var lastNotifiedOutdated: Set<String> = []
    /// Failures from the last run, kept visible across the read-only re-check that follows it.
    private var lastFailures: [String: TargetRow] = [:]
    private var queuedForce: Set<String> = []
    private var runTotals = (updated: 0, skipped: 0, failed: 0)

    init() {
        settings = AppSettings()
        launchAtLoginManager = MUKLaunchAtLoginManager(label: "com.georgecristea.Upkeep")
    }

    // MARK: - Derived

    var outdated: [TargetRow] { rows.filter { $0.status == .outdated } }
    var outdatedCount: Int { outdated.count }
    var isBusy: Bool { phase != .idle }

    var headline: String {
        if cliProblem != nil { return "Upkeep can't run" }
        switch phase {
        case .checking: return rows.isEmpty ? "Checking…" : "Checking for updates…"
        case .updating:
            let suffix = queued.isEmpty ? "" : " · \(queued.count) queued"
            if let activeID, let row = rows.first(where: { $0.id == activeID }) {
                return "Updating \(row.displayName)…\(suffix)"
            }
            return "Updating…\(suffix)"
        case .idle:
            if rows.isEmpty { return "No targets yet" }
            if outdatedCount == 0 { return "All \(rows.count) up to date" }
            return outdatedCount == 1 ? "1 update available" : "\(outdatedCount) updates available"
        }
    }

    var lastCheckedText: String {
        guard let lastChecked else { return "Not checked yet" }
        if Date().timeIntervalSince(lastChecked) < 60 { return "Checked just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Checked \(formatter.localizedString(for: lastChecked, relativeTo: Date()))"
    }

    func rows(in group: TargetGroup) -> [TargetRow] {
        rows.filter { $0.kind.group == group }
    }

    // MARK: - Lifecycle

    func start() {
        notifier.onUpdateAll = { [weak self] in self?.updateAll() }
        notifier.onShow = { [weak self] in self?.requestShowPopover?() }
        notifier.start()

        settings.$checkIntervalHours
            .removeDuplicates()
            .sink { [weak self] hours in self?.scheduleTimer(hours: hours) }
            .store(in: &cancellables)

        locateCLI()
        Task { await check() }
    }

    func stop() {
        timer?.invalidate()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func locateCLI() {
        cli = UpkeepCLI.locate()
        cliProblem = cli == nil
            ? "The upkeep command-line tool was not found at ~/.local/bin/upkeep. From your clone of github.com/georgecristea/upkeep, run:\nln -s \"$PWD/bin/upkeep\" ~/.local/bin/upkeep"
            : nil
    }

    private func scheduleTimer(hours: Int) {
        timer?.invalidate()
        timer = nil
        guard hours > 0 else { return }
        let interval = TimeInterval(hours) * 3600
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        timer?.tolerance = 300
    }

    // MARK: - Check

    /// Read-only refresh of every target. Never changes anything on the machine.
    func check() async {
        if cli == nil { locateCLI() }
        guard let cli, phase == .idle else { return }
        phase = .checking
        defer { phase = .idle }
        do {
            rows = try await cli.check().map { row in
                guard row.status == .outdated, let failure = lastFailures[row.id] else { return row }
                var merged = row
                merged.status = .failed
                merged.note = failure.note
                return merged
            }
            lastChecked = Date()
            cliProblem = nil
            notifyIfNewUpdates()
        } catch {
            showMessage(error.localizedDescription, tone: .error)
            if rows.isEmpty { cliProblem = error.localizedDescription }
        }
    }

    /// Called when the popover opens: refresh if the last check is older than 10 minutes.
    func checkIfStale() {
        guard phase == .idle else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 600 { return }
        Task { await check() }
    }

    private func notifyIfNewUpdates() {
        let ids = Set(outdated.map(\.id))
        guard settings.notifyOnUpdates, !ids.isEmpty, ids != lastNotifiedOutdated else {
            if ids.isEmpty { lastNotifiedOutdated = [] }
            return
        }
        lastNotifiedOutdated = ids
        let names = outdated.map(\.displayName).joined(separator: ", ")
        notifier.notify(
            title: outdatedCount == 1 ? "1 update available" : "\(outdatedCount) updates available",
            body: names,
            actionable: true)
    }

    // MARK: - Update

    enum RowRunState { case idle, active, waiting, queued }

    /// What a row is doing right now, for the list to render.
    func runState(of id: String) -> RowRunState {
        if activeID == id { return .active }
        if inFlight.contains(id) { return .waiting }
        if queued.contains(id) { return .queued }
        return .idle
    }

    /// Updates everything that is outdated. Never forces: running apps are reported as skipped
    /// and get their own explicit "Quit & update" button.
    func updateAll() {
        update(ids: [], force: false)
    }

    /// Runs now when idle. While a run is in progress, the targets are queued and run as the next
    /// batch: the CLI (and Homebrew) hold a lock, so runs are sequential, but clicks need not be.
    func update(ids: [String], force: Bool) {
        guard cli != nil else { return }
        if phase != .idle {
            guard !ids.isEmpty else { return } // "Update all" mid-run is ambiguous; ignore it
            for id in ids where !inFlight.contains(id) && !queued.contains(id) {
                queued.append(id)
                if force { queuedForce.insert(id) }
                AppLog.write("queued \(id) force=\(force)")
            }
            return
        }
        runTotals = (0, 0, 0)
        startBatch(ids: ids, force: force)
    }

    func dequeue(_ id: String) {
        queued.removeAll { $0 == id }
        queuedForce.remove(id)
        AppLog.write("dequeued \(id)")
    }

    private func startBatch(ids: [String], force: Bool) {
        guard let cli else { return }
        phase = .updating
        inFlight = Set(ids)
        activeID = nil
        lastSummary = nil
        if ids.isEmpty { lastFailures = [:] } else { ids.forEach { lastFailures[$0] = nil } }
        AppLog.write("batch start \(ids.isEmpty ? "[all]" : ids.description) force=\(force)")
        Task {
            do {
                let result = try await cli.update(ids: ids, force: force) { [weak self] event, row in
                    Task { @MainActor in self?.handle(event, row: row) }
                }
                if result.status >= 2 {
                    let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    showMessage(text.isEmpty ? "Update failed" : text, tone: .error)
                }
            } catch {
                showMessage(error.localizedDescription, tone: .error)
            }
            phase = .idle
            inFlight = []
            activeID = nil
            if let first = queued.first {
                // Next batch: everything queued with the same force setting as the first item.
                let wantForce = queuedForce.contains(first)
                let next = queued.filter { queuedForce.contains($0) == wantForce }
                queued.removeAll { next.contains($0) }
                next.forEach { queuedForce.remove($0) }
                startBatch(ids: next, force: wantForce)
            } else {
                finishRun()
                await check()
            }
        }
    }

    /// Called once the queue has drained: one summary, one message, one notification for the whole run.
    private func finishRun() {
        let (updated, skipped, failed) = runTotals
        let summary = "\(updated) updated, \(skipped) skipped, \(failed) failed"
        lastSummary = summary
        showMessage("\(summary) · \(Self.timeFormatter.string(from: Date()))", tone: failed > 0 ? .error : .success)
        if settings.notifyOnCompletion, updated + failed > 0 {
            notifier.notify(title: failed > 0 ? "Upkeep: some updates failed" : "Upkeep finished", body: summary, actionable: false)
        }
    }

    private func handle(_ event: UpdateEvent, row: TargetRow?) {
        switch event.event {
        case "start":
            if inFlight.isEmpty, let ids = event.targets { inFlight = Set(ids) }
        case "updating":
            activeID = event.id
        case "result":
            guard let row else { return }
            inFlight.remove(row.id)
            if activeID == row.id { activeID = nil }
            if row.status == .failed { lastFailures[row.id] = row }
            if let index = rows.firstIndex(where: { $0.id == row.id }) {
                rows[index] = row
            }
        case "done":
            runTotals.updated += event.updated ?? 0
            runTotals.skipped += event.skipped ?? 0
            runTotals.failed += event.failed ?? 0
            if let log = event.log { lastLogURL = URL(fileURLWithPath: log) }
        case "fatal":
            showMessage(event.message ?? "Update failed", tone: .error)
            if let log = event.log { lastLogURL = URL(fileURLWithPath: log) }
        default:
            break
        }
    }

    // MARK: - Helpers

    func openManifest() {
        guard let cli else { return }
        NSWorkspace.shared.open(cli.manifestURL)
    }

    func revealLatestLog() {
        let url = lastLogURL ?? UpkeepCLI.latestLog()?.url
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func showMessage(_ text: String, tone: MUKStatusMessage.Tone) {
        lastMessage = MUKStatusMessage(text, tone: tone)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
