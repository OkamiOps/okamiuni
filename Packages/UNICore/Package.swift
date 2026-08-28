// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UNICore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "UNICore", targets: ["UNICore"])],
    targets: [
        .target(name: "UNICore"),
        .testTarget(name: "UNICoreTests", dependencies: ["UNICore"]),
    ]
)
