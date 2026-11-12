// swift-tools-version:5.9
import PackageDescription

// The overhead sounds of Dolby TrueHD Atmos and DTS:X for the Apple TV's own film player: see README.md here for
// what comes from where and under which licence.
let package = Package(
    name: "FilmHeights",
    platforms: [.tvOS(.v18), .macOS(.v15)],
    products: [.library(name: "FilmHeights", targets: ["FilmHeights"])],
    targets: [
        // LibTrueHD: the decoder for TrueHD's Atmos presentation (MIT, with Apache-2.0 parts).
        .binaryTarget(name: "TrueHD", path: "TrueHD.xcframework"),
        .target(
            name: "FilmHeights",
            dependencies: ["TrueHD"],
            resources: [.copy("Resources/silent-atmos.mp4")],
            // AetherEngine keeps these parts behind package traits; here they are simply on.
            swiftSettings: [.define("TrueHDObjectAudio"), .define("DTSXObjectAudio")]
        ),
        .testTarget(name: "FilmHeightsTests", dependencies: ["FilmHeights"],
                    swiftSettings: [.define("TrueHDObjectAudio"), .define("DTSXObjectAudio")]),
    ]
)
