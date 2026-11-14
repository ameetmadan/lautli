// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LautliApp",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "LautliApp", targets: ["LautliApp"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.0"),
    ],
    targets: [
        .executableTarget(name: "LautliApp", dependencies: [.product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "LautliAppTests", dependencies: ["LautliApp"]),
    ]
)
