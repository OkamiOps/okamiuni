// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UNIDesign",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "UNIDesign", targets: ["UNIDesign"])
    ],
    targets: [
        .target(name: "UNIDesign"),
        .testTarget(name: "UNIDesignTests", dependencies: ["UNIDesign"]),
    ]
)
