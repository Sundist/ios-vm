// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VMCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VMCore", targets: ["VMCore"]),
        .library(name: "QEMUShim", targets: ["QEMUShim"]),
    ],
    targets: [
        .target(name: "VMCore"),
        .target(name: "QEMUShim"),
        .testTarget(name: "VMCoreTests", dependencies: ["VMCore"]),
    ]
)
