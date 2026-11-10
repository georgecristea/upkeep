import AppKit
import MacUtilityKit
import SwiftUI

struct TargetRowView: View {
    let row: TargetRow
    let runState: AppState.RowRunState
    let update: () -> Void
    let quitAndUpdate: () -> Void
    let dequeue: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            icon

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.displayName)
                        .font(.callout)
                        .lineLimit(1)
                    if let secondary = row.secondaryName {
                        Text(secondary)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                versionLine
                if let note = row.displayNote {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(row.status == .failed ? MUKTheme.danger : .secondary)
                        .lineLimit(1)
                        .help(note)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        if let image = row.appIcon {
            Image(nsImage: image)
                .resizable()
                .frame(width: 28, height: 28)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
                Image(systemName: row.kind.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 28, height: 28)
        }
    }

    private var versionLine: some View {
        HStack(spacing: 4) {
            Text(row.installed)
            if row.status == .outdated, row.latest != "-", row.latest != row.installed {
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                Text(row.latest)
                    .foregroundStyle(MUKTheme.accent)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder private var trailing: some View {
        switch runState {
        case .active:
            ProgressView()
                .controlSize(.small)
                .frame(width: 24, height: 24)
        case .waiting:
            MUKBadge("Waiting", tone: .neutral)
        case .queued:
            MUKBadge("Queued", tone: .warning)
            Button(action: dequeue) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Remove from queue")
        case .idle:
            if row.isRunningSkip {
                Button("Quit & update", action: quitAndUpdate)
                    .controlSize(.small)
                    .help("Quit \(row.displayName), update it, and reopen it. Queues if a run is in progress.")
            } else {
                statusBadge
                if row.canUpdate {
                    Button(action: update) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(MUKTheme.accent)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .help(row.kind == .native ? "Run its updater" : "Update \(row.displayName). Queues if a run is in progress.")
                }
            }
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch row.status {
        case .current: MUKBadge("Up to date", tone: .success)
        case .outdated: MUKBadge("Update", tone: .warning)
        case .updated: MUKBadge("Updated", tone: .success)
        case .skipped: MUKBadge("Skipped", tone: .neutral)
        case .failed: MUKBadge("Failed", tone: .error)
        case .selfManaged: MUKBadge("Self-updating", tone: .neutral)
        }
    }
}
