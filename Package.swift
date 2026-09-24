// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sugarnote",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SugarNoteCore", targets: ["SugarNoteCore"]),
        .executable(name: "sugarnote-cli", targets: ["SugarNoteCLI"]),
        .executable(name: "sugarnote", targets: ["SugarNoteApp"]),
    ],
    targets: [
        .target(
            name: "SugarNoteCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "SugarNoteCLI",
            dependencies: ["SugarNoteCore"]
        ),
        .executableTarget(
            name: "SugarNoteApp",
            dependencies: ["SugarNoteCore"]
        ),
        .testTarget(
            name: "SugarNoteCoreTests",
            dependencies: ["SugarNoteCore"]
        ),
    ]
)
