// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BranchBar",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "BranchBarCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "BranchBar",
            dependencies: ["BranchBarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BranchBarCoreTests",
            dependencies: ["BranchBarCore"]
        ),
    ]
)
