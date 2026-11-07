// swift-tools-version:5.9
import PackageDescription

// Google's WebRTC library (the cameras' native player), prebuilt by github.com/stasel/WebRTC (BSD licence).
// scripts/fetch_webrtc.sh downloads it here before every build: Xcode's own download of it hung, with no error.
let package = Package(
    name: "WebRTC",
    platforms: [.iOS(.v13), .macOS(.v11)],
    products: [.library(name: "WebRTC", targets: ["WebRTC"])],
    targets: [.binaryTarget(name: "WebRTC", path: "WebRTC.xcframework")]
)
