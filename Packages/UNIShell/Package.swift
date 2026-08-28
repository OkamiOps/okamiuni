// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UNIShell",
    platforms: [.macOS(.v26)],
    products: [.library(name: "UNIShell", targets: ["UNIShell"])],
    dependencies: [
        .package(path: "../UNIDesign"),
        .package(path: "../UNICore"),
    ],
    targets: [
        .target(name: "UNIShell", dependencies: ["UNIDesign", "UNICore"]),
        .testTarget(name: "UNIShellTests", dependencies: ["UNIShell"]),
    ]
)
