import Foundation

/// Tiny append-only diagnostic log at ~/Library/Logs/upkeep/app.log: popover lifecycle, navigation,
/// and CLI runs. Cheap enough to leave on; it is the only way to see what the app did after the fact.
enum AppLog {
    private static let url = UpkeepCLI.logDirectory.appendingPathComponent("app.log")
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: UpkeepCLI.logDirectory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
