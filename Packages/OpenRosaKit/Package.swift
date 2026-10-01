// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OpenRosaKit",
    platforms: [.iOS(.v16), .macOS(.v10_15)],
    products: [
        .library(name: "OpenRosaKit", targets: ["OpenRosaKit"])
    ],
    targets: [
        .target(name: "OpenRosaKit"),
        .testTarget(name: "OpenRosaKitTests", dependencies: ["OpenRosaKit"])
    ]
)
