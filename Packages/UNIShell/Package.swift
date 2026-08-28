// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UNIShell",
    platforms: [.macOS(.v26)],
    products: [.library(name: "UNIShell", targets: ["UNIShell"])],
    dependencies: [
        .package(path: "../UNIDesign"),
        .package(path: "../UNICore"),
        .package(path: "../UNISync"),
    ],
    targets: [
        .target(name: "UNIShell", dependencies: ["UNIDesign", "UNICore", "UNISync"]),
        .testTarget(name: "UNIShellTests", dependencies: ["UNIShell"]),
    ]
)
