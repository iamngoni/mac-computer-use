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
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.6"
        ),
    ],
    targets: [
        .target(name: "MacComputerUseCore"),
        .executableTarget(
            name: "MacComputerUse",
            dependencies: [
                "MacComputerUseCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(
            name: "MacComputerUseCoreTests",
            dependencies: ["MacComputerUseCore"],
            path: "SwiftTests/MacComputerUseCoreTests"
        ),
    ]
)
