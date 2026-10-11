// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingNotesApp",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "MeetingNotesApp", targets: ["MeetingNotesApp"])],
    targets: [
        .executableTarget(name: "MeetingNotesApp"),
        .testTarget(name: "MeetingNotesAppTests", dependencies: ["MeetingNotesApp"]),
    ]
)
