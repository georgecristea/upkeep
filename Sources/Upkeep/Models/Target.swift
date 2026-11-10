import AppKit
import Foundation

enum TargetKind: String, Codable {
    case cask, npm, formula, native

    var group: TargetGroup {
        switch self {
        case .cask: return .apps
        case .npm, .formula: return .cli
        case .native: return .selfManaged
        }
    }

    var symbol: String {
        switch self {
        case .cask: return "app.dashed"
        case .npm: return "shippingbox"
        case .formula: return "mug"
        case .native: return "arrow.clockwise.circle"
        }
    }
}

enum TargetGroup: String, CaseIterable, Identifiable {
    case apps = "Apps"
    case cli = "CLI tools"
    case selfManaged = "Self-updating"

    var id: String { rawValue }
}

enum TargetStatus: String, Codable {
    case current, outdated, updated, skipped, failed
    case selfManaged = "self-managed"
}

/// One row of `upkeep check --json` / one `result` event of `upkeep update --json`.
struct TargetRow: Codable, Identifiable, Equatable {
    let id: String
    let kind: TargetKind
    let installed: String
    let latest: String
    var status: TargetStatus
    var note: String
    var app: String?
    var running: Bool?

    /// Human name: "Visual Studio Code", "Codex", "Claude Code".
    var displayName: String {
        if let app { return app.replacingOccurrences(of: ".app", with: "") }
        let base = kind == .npm ? (id.split(separator: "/").last.map(String.init) ?? id) : id
        return base.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Shown under the name when it adds information (npm scope, cask token).
    var secondaryName: String? {
        displayName.lowercased() == id.lowercased() ? nil : id
    }

    /// The app is open, so updating it means quitting it first: offer "Quit & update" explicitly.
    var isRunningSkip: Bool {
        (status == .outdated && running == true) || (status == .skipped && note.lowercased().contains("running"))
    }

    /// True when a per-row action makes sense.
    var canUpdate: Bool {
        switch status {
        case .outdated, .selfManaged, .failed: return true
        case .skipped: return isRunningSkip
        case .current, .updated: return false
        }
    }

    /// Note text rewritten for people, not terminals.
    var displayNote: String? {
        if isRunningSkip { return "App is running" }
        return note.isEmpty ? nil : note
    }

    var appIcon: NSImage? {
        guard let app else { return nil }
        let path = "/Applications/\(app)"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }
}

/// One line of `upkeep update --json`.
struct UpdateEvent: Decodable {
    let event: String
    let id: String?
    let targets: [String]?
    let message: String?
    let updated: Int?
    let skipped: Int?
    let failed: Int?
    let log: String?
}
