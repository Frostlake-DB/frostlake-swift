// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Frostlake",
    platforms: [
        .macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9),
    ],
    products: [
        .library(name: "Frostlake", targets: ["Frostlake"]),
    ],
    targets: [
        .target(name: "Frostlake"),
        .testTarget(name: "FrostlakeTests", dependencies: ["Frostlake"]),
    ]
)
