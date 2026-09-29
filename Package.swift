// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuarantineClear",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuarantineCore", targets: ["QuarantineCore"]),
        .executable(name: "quarantine-clear", targets: ["QuarantineCLI"]),
        .executable(name: "QuarantineClear", targets: ["QuarantineClearApp"]),
    ],
    targets: [
        .target(name: "QuarantineCore"),
        .executableTarget(name: "QuarantineCLI", dependencies: ["QuarantineCore"]),
        .executableTarget(name: "QuarantineClearApp", dependencies: ["QuarantineCore"]),
        .testTarget(name: "QuarantineCoreTests", dependencies: ["QuarantineCore"]),
    ]
)
