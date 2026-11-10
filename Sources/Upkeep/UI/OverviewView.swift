import MacUtilityKit
import SwiftUI

struct OverviewView: View {
    @ObservedObject var appState: AppState
    let onShowLog: () -> Void

    var body: some View {
        if let problem = appState.cliProblem, appState.rows.isEmpty {
            VStack(spacing: 14) {
                MUKEmptyState(
                    title: "Upkeep can't reach its command-line tool",
                    detail: problem,
                    systemImage: "terminal")
                Button("Try again") { Task { await appState.check() } }
                    .padding(.bottom, 24)
            }
        } else {
            ScrollView {
                VStack(spacing: 14) {
                    summaryCard
                    ForEach(TargetGroup.allCases) { group in
                        let rows = appState.rows(in: group)
                        if !rows.isEmpty {
                            section(group, rows: rows)
                        }
                    }
                }
                .padding(MUKTheme.edgePadding)
            }
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        MUKCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appState.headline)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        Text(appState.lastCheckedText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    MUKPrimaryButton("Update all", systemImage: "arrow.down.circle.fill") {
                        appState.updateAll()
                    }
                    .disabled(appState.isBusy || appState.outdatedCount == 0)
                    .help("Update every outdated target. Running apps are skipped; use their own Quit & update.")
                }

                if appState.phase == .updating {
                    MUKProgressBar(value: nil)
                }

                if let summary = appState.lastSummary, appState.phase == .idle {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(MUKTheme.accent)
                        Text("Last run: \(summary)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("View log", action: onShowLog)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private func section(_ group: TargetGroup, rows: [TargetRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(group.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                let outdated = rows.filter { $0.status == .outdated }.count
                if outdated > 0 {
                    MUKBadge("\(outdated)", tone: .warning)
                }
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    TargetRowView(
                        row: row,
                        runState: appState.runState(of: row.id),
                        update: { appState.update(ids: [row.id], force: false) },
                        quitAndUpdate: { appState.update(ids: [row.id], force: true) },
                        dequeue: { appState.dequeue(row.id) })
                    if index < rows.count - 1 {
                        Divider().padding(.leading, 48).opacity(0.5)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: MUKTheme.rowRadius, style: .continuous))
        }
    }
}
