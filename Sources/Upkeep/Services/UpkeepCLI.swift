import Foundation

struct CLIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: String
}

/// Runs the `upkeep` command-line tool. The CLI is the engine; this class only spawns it, streams
/// its JSON output, and decodes it. Nothing about targets, adapters, or verification lives here.
final class UpkeepCLI: @unchecked Sendable {
    static let candidatePaths = ["~/.local/bin/upkeep", "/opt/homebrew/bin/upkeep", "/usr/local/bin/upkeep"]
    static let logDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/upkeep", isDirectory: true)

    let executable: URL

    /// Finds the first candidate that exists and is executable.
    static func locate() -> UpkeepCLI? {
        for candidate in candidatePaths {
            let path = (candidate as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: path) {
                return UpkeepCLI(executable: URL(fileURLWithPath: path))
            }
        }
        return nil
    }

    init(executable: URL) {
        self.executable = executable
    }

    /// `bin/upkeep` is a shim next to `upkeep.ts`; the manifest sits one level up.
    var manifestURL: URL {
        executable.resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("upkeep.json")
    }

    /// Read-only. Exit 1 only means "something is outdated"; 2 is a real failure.
    func check() async throws -> [TargetRow] {
        let result = try await run(["check", "--json"], onLine: nil)
        if result.status >= 2 {
            throw CLIError(message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try JSONDecoder().decode([TargetRow].self, from: result.stdout)
    }

    /// Streams NDJSON events while the update runs. `ids` empty = everything.
    func update(ids: [String], force: Bool, onEvent: @escaping @Sendable (UpdateEvent, TargetRow?) -> Void) async throws -> ProcessResult {
        var args = ["update", "--json", "--no-notify"] + ids
        if force { args.append("--force") }
        return try await run(args) { line in
            guard let data = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(UpdateEvent.self, from: data) else { return }
            let row = event.event == "result" ? try? JSONDecoder().decode(TargetRow.self, from: data) : nil
            onEvent(event, row)
        }
    }

    static func latestLog() -> (url: URL, text: String)? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: logDirectory.path) else { return nil }
        guard let latest = names.filter({ $0.first?.isNumber == true && $0.hasSuffix(".log") }).sorted().last else { return nil }
        let url = logDirectory.appendingPathComponent(latest)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return (url, text)
    }

    // MARK: - Process plumbing

    private func run(_ args: [String], onLine: (@Sendable (String) -> Void)?) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = args
            process.environment = [
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "USER": NSUserName(),
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                "LANG": "en_US.UTF-8"
            ]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = FileHandle.nullDevice

            let collector = LineCollector(onLine: onLine)
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                collector.append(handle.availableData)
            }
            let stderrCollector = LineCollector(onLine: nil)
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                stderrCollector.append(handle.availableData)
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                collector.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                stderrCollector.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                collector.finish()
                continuation.resume(returning: ProcessResult(
                    status: proc.terminationStatus,
                    stdout: collector.allData,
                    stderr: String(data: stderrCollector.allData, encoding: .utf8) ?? ""))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Accumulates pipe chunks and emits complete lines. Thread-safe: pipe handlers run off-main.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private(set) var allData = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        allData.append(data)
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty { lines.append(line) }
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    func finish() {
        lock.lock()
        let rest = buffer
        buffer.removeAll()
        lock.unlock()
        if let line = String(data: rest, encoding: .utf8), !line.isEmpty { onLine?(line) }
    }
}
