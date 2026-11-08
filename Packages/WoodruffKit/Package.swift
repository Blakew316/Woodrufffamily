// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WoodruffKit",
    platforms: [.iOS(.v17), .macOS(.v14), .macCatalyst(.v17), .tvOS(.v17)],
    products: [.library(name: "WoodruffKit", targets: ["WoodruffKit"])],
    targets: [
        .target(name: "WoodruffKit"),
        .testTarget(name: "WoodruffKitTests", dependencies: ["WoodruffKit"]),
    ]
)
