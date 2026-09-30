// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ODKWebEngine",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "ODKWebEngine", targets: ["ODKWebEngine"])
    ],
    targets: [
        .target(
            name: "ODKWebEngine",
            resources: [.copy("Resources/EnketoEngine")]
        ),
        .testTarget(
            name: "ODKWebEngineTests",
            dependencies: ["ODKWebEngine"]
        )
    ]
)
