// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "XiwoBoard",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "XiwoBoard", targets: ["XiwoBoard"]),
        .library(name: "XiwoCore", targets: ["XiwoCore"]),
    ],
    targets: [
        .target(name: "XiwoCore"),
        .executableTarget(
            name: "XiwoBoard",
            dependencies: ["XiwoCore"]
        ),
        .testTarget(name: "XiwoCoreTests", dependencies: ["XiwoCore"]),
        .testTarget(name: "XiwoBoardTests", dependencies: ["XiwoBoard", "XiwoCore"]),
    ],
    swiftLanguageModes: [.v5]
)
