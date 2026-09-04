// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacComputerUse",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "MacComputerUseCore", targets: ["MacComputerUseCore"]),
        .executable(name: "mac-computer-use", targets: ["MacComputerUse"]),
    ],
    targets: [
        .target(name: "MacComputerUseCore"),
        .executableTarget(
            name: "MacComputerUse",
            dependencies: ["MacComputerUseCore"]
        ),
        .testTarget(
            name: "MacComputerUseCoreTests",
            dependencies: ["MacComputerUseCore"],
            path: "SwiftTests/MacComputerUseCoreTests"
        ),
    ]
)
