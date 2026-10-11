// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LautliApp",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "LautliApp", targets: ["LautliApp"])],
    targets: [
        .executableTarget(name: "LautliApp"),
        .testTarget(name: "LautliAppTests", dependencies: ["LautliApp"]),
    ]
)
