// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ProjectSettingsKit",
    platforms: [.iOS(.v16), .macOS(.v10_15)],
    products: [
        .library(name: "ProjectSettingsKit", targets: ["ProjectSettingsKit"])
    ],
    targets: [
        .target(name: "ProjectSettingsKit"),
        .testTarget(name: "ProjectSettingsKitTests", dependencies: ["ProjectSettingsKit"])
    ]
)
