import MacUtilityKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    // Observe settings directly: a change one level down on appState.settings doesn't re-render.
    @ObservedObject var settings: AppSettings
    let onShowAbout: () -> Void
    let onShowLog: () -> Void

    @State private var launchAtLogin: Bool

    init(appState: AppState, onShowAbout: @escaping () -> Void, onShowLog: @escaping () -> Void) {
        self.appState = appState
        self._settings = ObservedObject(wrappedValue: appState.settings)
        self.onShowAbout = onShowAbout
        self.onShowLog = onShowLog
        _launchAtLogin = State(initialValue: appState.launchAtLoginManager.isEnabled)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                MUKSettingsRow(
                    title: "Check automatically",
                    detail: "Read-only check for new versions. Nothing is installed until you click update.",
                    systemImage: "clock.arrow.2.circlepath")
                {
                    Picker("", selection: intervalBinding) {
                        ForEach(AppSettings.intervalChoices, id: \.self) { hours in
                            Text(AppSettings.intervalLabel(hours)).tag(hours)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                MUKSettingsRow(
                    title: "Notify about updates",
                    detail: "A notification when new versions appear, with an Update all button",
                    systemImage: "bell")
                {
                    Toggle("", isOn: Binding(get: { settings.notifyOnUpdates }, set: { settings.setNotifyOnUpdates($0) }))
                        .labelsHidden()
                }

                MUKSettingsRow(
                    title: "Notify when a run finishes",
                    detail: "Summary of what was updated, skipped, or failed",
                    systemImage: "checkmark.message")
                {
                    Toggle("", isOn: Binding(get: { settings.notifyOnCompletion }, set: { settings.setNotifyOnCompletion($0) }))
                        .labelsHidden()
                }

                MUKSettingsRow(
                    title: "Launch at login",
                    detail: "Open Upkeep automatically when you log in",
                    systemImage: "power")
                {
                    Toggle("", isOn: launchBinding).labelsHidden()
                }

                Button(action: appState.openManifest) {
                    MUKSettingsRow(
                        title: "Edit target list",
                        detail: "Opens upkeep.json. One line per program; or use `upkeep add <id>`.",
                        systemImage: "list.bullet.rectangle")
                    {
                        Image(systemName: "arrow.up.forward.square").foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(appState.cli == nil)

                Button(action: onShowLog) {
                    MUKSettingsRow(
                        title: "Latest run log",
                        detail: "Every command, version, and verification from the last update",
                        systemImage: "doc.text.magnifyingglass")
                    {
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)

                MUKSettingsRow(
                    title: "Command-line tool",
                    detail: appState.cli?.executable.path ?? "Not found",
                    systemImage: "terminal")
                {
                    MUKBadge(appState.cli == nil ? "Missing" : "Found", tone: appState.cli == nil ? .error : .success)
                }

                Button(action: onShowAbout) {
                    MUKSettingsRow(
                        title: "About Upkeep",
                        detail: "Version, license, acknowledgements",
                        systemImage: "info.circle")
                    {
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(MUKTheme.edgePadding)
        }
    }

    private var intervalBinding: Binding<Int> {
        Binding(get: { settings.checkIntervalHours }, set: { settings.setCheckInterval(hours: $0) })
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                try? appState.launchAtLoginManager.setEnabled(newValue)
                launchAtLogin = appState.launchAtLoginManager.isEnabled
            })
    }
}
