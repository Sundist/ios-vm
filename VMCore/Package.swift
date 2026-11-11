// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VMCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VMCore", targets: ["VMCore"]),
    ],
    targets: [
        .target(name: "VMCore"),
        .testTarget(name: "VMCoreTests", dependencies: ["VMCore"]),
    ]
)
