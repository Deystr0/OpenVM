// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenVM",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "OpenVM", path: "Sources/OpenVM")
    ]
)
