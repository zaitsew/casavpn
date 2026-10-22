// swift-tools-version: 6.0
import PackageDescription

// CasaKit: everything in the app that has no UI. It builds and tests on macOS
// (`swift test`) as well as on iOS, so the logic is checked without a simulator.
let package = Package(
    name: "CasaKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CasaKit", targets: ["CasaKit"]),
    ],
    targets: [
        .target(name: "CasaKit"),
        .testTarget(name: "CasaKitTests", dependencies: ["CasaKit"]),
    ]
)
