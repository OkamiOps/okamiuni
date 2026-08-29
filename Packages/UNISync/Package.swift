// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UNISync",
    platforms: [.macOS(.v26)],
    products: [.library(name: "UNISync", targets: ["UNISync"])],
    dependencies: [
        .package(path: "../UNICore"),
        // As dependências novas do marco.
        //
        // O `swift-nio-imap` esteve aqui e **saiu**. Ele entrou para juntar os
        // literais `{n}` do IMAP, e é justamente isso que ele não faz direito
        // na 0.4.0: um literal de tamanho zero prende no buffer dele o resto da
        // linha e a resposta tagueada seguinte, e o conteúdo do literal sai em
        // pedaços que partem caracteres multibyte ao meio. Os dois estão
        // reproduzidos no relatório da tarefa. O `CRLFLineDecoder` monta a
        // linha lógica, o `ImapResponseAdapter` a lê, e nenhum dos dois precisa
        // da biblioteca — que passaria a pesar na resolução sem fazer trabalho.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // SwiftNIO, agora dependência **direta** e não mais carona da árvore do
        // swift-nio-imap: é sobre ele que a sessão IMAP inteira é escrita.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
    ],
    targets: [
        .target(
            name: "UNISync",
            dependencies: [
                "UNICore",
                .product(name: "GRDB", package: "GRDB.swift"),
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
