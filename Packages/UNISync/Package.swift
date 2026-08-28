// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UNISync",
    platforms: [.macOS(.v26)],
    products: [.library(name: "UNISync", targets: ["UNISync"])],
    dependencies: [
        .package(path: "../UNICore"),
        // As duas únicas dependências novas do marco.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-nio-imap.git", .upToNextMinor(from: "0.4.0")),
        // O SwiftNIO que o swift-nio-imap já traz. Declarado aqui só para o
        // alvo de teste poder nomear NIOCore/NIOPosix/NIOEmbedded ao montar o
        // servidor IMAP falso — não é uma terceira dependência, é a mesma
        // árvore com um nome à mão.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
    ],
    targets: [
        .target(
            name: "UNISync",
            dependencies: [
                "UNICore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .testTarget(
            name: "UNISyncTests",
            dependencies: [
                "UNISync",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
