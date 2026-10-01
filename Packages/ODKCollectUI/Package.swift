// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ODKCollectUI",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "ODKCollectUI", targets: ["ODKCollectUI"])
    ],
    dependencies: [
        .package(path: "../ODKWebEngine"),
        .package(path: "../OpenRosaKit"),
        .package(path: "../ProjectSettingsKit")
    ],
    targets: [
        .target(
            name: "ODKCollectUI",
            dependencies: ["ODKWebEngine", "OpenRosaKit", "ProjectSettingsKit"]
        ),
        .testTarget(
            name: "ODKCollectUITests",
            dependencies: ["ODKCollectUI", "OpenRosaKit", "ProjectSettingsKit"]
        )
    ]
)
