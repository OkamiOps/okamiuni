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
        // SwiftNIO entra aqui por causa de **um** arquivo:
        // `RehearsalImapServer`, o servidor IMAP falso que o `--ensaiar-contas`
        // sobe em 127.0.0.1. Ele mora no alvo de produção porque o ensaio roda
        // dentro do app de verdade — é essa a diferença entre ensaio e teste de
        // View. A versão é a mesma que o `UNISync` já resolve.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "UNIShell",
            dependencies: [
                "UNIDesign", "UNICore", "UNISync",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .testTarget(name: "UNIShellTests", dependencies: ["UNIShell"]),
    ]
)
