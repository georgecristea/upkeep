import MacUtilityKit
import SwiftUI

struct LogView: View {
    @ObservedObject var appState: AppState
    @State private var log: (url: URL, text: String)?

    var body: some View {
        Group {
            if let log {
                VStack(alignment: .leading, spacing: 0) {
                    Text(log.url.lastPathComponent)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, MUKTheme.edgePadding)
                        .padding(.vertical, 8)
                    ScrollView([.vertical, .horizontal]) {
                        Text(log.text)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, MUKTheme.edgePadding)
                            .padding(.bottom, 12)
                    }
                }
            } else {
                MUKEmptyState(
                    title: "No runs yet",
                    detail: "Logs appear here after the first update. Checks are read-only and don't write a log.",
                    systemImage: "doc.text")
            }
        }
        .onAppear(perform: load)
        .onChange(of: appState.lastLogURL) { _, _ in load() }
    }

    private func load() {
        if let url = appState.lastLogURL, let text = try? String(contentsOf: url, encoding: .utf8) {
            log = (url, text)
        } else {
            log = UpkeepCLI.latestLog()
        }
    }
}
