import MacUtilityKit
import SwiftUI

struct MainPopoverView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        MUKPopoverShell(message: appState.lastMessage) {
            header
        } content: {
            content
        }
    }

    @ViewBuilder private var header: some View {
        switch appState.popoverScreen {
        case .overview:
            MUKHeader(
                title: "Upkeep",
                subtitle: appState.headline,
                systemImage: "arrow.triangle.2.circlepath")
            {
                MUKIconButton(systemImage: "arrow.clockwise", help: "Check now") {
                    Task { await appState.check() }
                }
                .disabled(appState.isBusy)
                MUKIconButton(systemImage: "gearshape", help: "Settings") {
                    navigate(to: .settings)
                }
                MUKIconButton(systemImage: "power", help: "Quit Upkeep") {
                    appState.quit()
                }
            }
        case .settings:
            MUKBackHeader(title: "Settings", onBack: { navigate(to: .overview) })
        case .log:
            MUKBackHeader(title: "Latest run", onBack: { navigate(to: .overview) }) {
                MUKIconButton(systemImage: "folder", help: "Reveal in Finder") {
                    appState.revealLatestLog()
                }
            }
        case .about:
            MUKBackHeader(title: "About", onBack: { navigate(to: .settings) })
        }
    }

    @ViewBuilder private var content: some View {
        switch appState.popoverScreen {
        case .overview:
            OverviewView(appState: appState, onShowLog: { navigate(to: .log) })
        case .settings:
            SettingsView(appState: appState, onShowAbout: { navigate(to: .about) }, onShowLog: { navigate(to: .log) })
        case .log:
            LogView(appState: appState)
        case .about:
            AboutView()
        }
    }

    private func navigate(to screen: PopoverScreen) {
        AppLog.write("navigate -> \(screen)")
        withAnimation(.easeInOut(duration: 0.18)) { appState.popoverScreen = screen }
    }
}
