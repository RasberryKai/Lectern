// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Lectern",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "LecternCore", targets: ["LecternCore"]),
        .executable(name: "lectern", targets: ["LecternTool"]),
        // Distinct from the `lectern` tool so both binaries can share a case-insensitive build folder.
        .executable(name: "LecternApp", targets: ["LecternApp"])
    ],
    targets: [
        .target(name: "LecternCore", resources: [.process("Resources")]),
        .executableTarget(name: "LecternTool", dependencies: ["LecternCore"]),
        .executableTarget(
            name: "LecternApp",
            dependencies: ["LecternCore"],
            resources: [.copy("Resources/MathJax")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "LecternCoreTests", dependencies: ["LecternCore"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v6]
)
