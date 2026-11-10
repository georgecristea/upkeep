import MacUtilityKit
import SwiftUI

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 8) {
                    MUKBrandIcon(symbol: "arrow.triangle.2.circlepath", size: 52)
                    Text("Upkeep")
                        .font(.title3.weight(.semibold))
                    Text("Version \(appVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Your core tools, always current")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

                MUKCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("© 2026 DeepDive Solna AB · MIT License")
                            .font(.callout.weight(.medium))
                        Text("Free and open source. Upkeep is a front end for the `upkeep` command-line tool: it runs on this Mac, installs only from Homebrew and the npm registry, and verifies every app's signature after updating.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                MUKCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Acknowledgements")
                            .font(.subheadline.weight(.semibold))
                        ForEach(acknowledgements, id: \.name) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.caption.weight(.medium))
                                Text(item.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(MUKTheme.edgePadding)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private struct Acknowledgement {
        let name: String
        let detail: String
    }

    private var acknowledgements: [Acknowledgement] {
        [
            Acknowledgement(name: "Homebrew", detail: "Package manager for macOS. BSD 2-Clause."),
            Acknowledgement(name: "Node.js", detail: "Runs the upkeep command-line tool. MIT."),
            Acknowledgement(name: "MacUtilityKit", detail: "Shared macOS UI toolkit by DeepDive Solna AB. MIT License.")
        ]
    }
}
