// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lectern",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "LecternCore", targets: ["LecternCore"]),
        .executable(name: "lectern", targets: ["LecternTool"])
    ],
    targets: [
        .target(name: "LecternCore", resources: [.process("Resources")]),
        .executableTarget(name: "LecternTool", dependencies: ["LecternCore"]),
        .testTarget(name: "LecternCoreTests", dependencies: ["LecternCore"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v6]
)
