// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UNICore",
    defaultLocalization: "pt-BR",
    platforms: [.macOS(.v26)],
    products: [.library(name: "UNICore", targets: ["UNICore"])],
    targets: [
        .target(
            name: "UNICore",
            resources: [.process("Resources")]
        ),
        .testTarget(name: "UNICoreTests", dependencies: ["UNICore"]),
    ]
)
