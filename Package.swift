// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Upkeep",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Upkeep", targets: ["Upkeep"])
    ],
    dependencies: [
        .package(url: "https://github.com/georgecristea/MacUtilityKit.git", from: "0.1.0")
    ],
    targets: [
        .executableTarget(
            name: "Upkeep",
            dependencies: [
                "MacUtilityKit"
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
