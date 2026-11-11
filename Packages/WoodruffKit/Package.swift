// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WoodruffKit",
    platforms: [.iOS(.v17), .macOS(.v14), .macCatalyst(.v17), .tvOS(.v17)],
    products: [.library(name: "WoodruffKit", targets: ["WoodruffKit"])],
    targets: [
        .target(name: "WoodruffKit"),
        // Fixtures: a few seconds of film in each layout the app's own player has to read (the Mac tests play them).
        .testTarget(name: "WoodruffKitTests", dependencies: ["WoodruffKit"], resources: [.copy("Fixtures")]),
    ]
)
