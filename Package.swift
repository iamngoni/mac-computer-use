// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MacComputerUse",
    platforms: [
        .macOS(.v14),
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
        // Kokoro, the free on-device neural voice. FluidAudio's default
        // traits are kept: Swift before 6.2 (CI's Xcode 16) can't select them.
        .package(
            url: "https://github.com/FluidInference/FluidAudio",
            exact: "0.18.3"
        ),
    ],
    targets: [
        .target(
            name: "MacComputerUseCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
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
    ],
    swiftLanguageModes: [.v5]
)
