import Foundation
import Testing
@testable import UNISync

/// O catálogo de modelos de um servidor **deste Mac**.
///
/// A regra que importa aqui não é o formato: é o endereço. "Neste Mac" é uma
/// promessa de privacidade, e um endpoint que não seja de loopback a quebraria
/// em silêncio — por isso ele é recusado antes de qualquer pedido sair.
@Suite("Modelos de um servidor local")
struct LocalModelCatalogTests {

    @Test("loopback é localhost, 127.0.0.1 e ::1 — e mais nada", arguments: [
        ("http://localhost:11434/v1", true),
        ("http://127.0.0.1:4000/v1", true),
        ("http://[::1]:1234/v1", true),
        ("https://api.minimax.io/v1", false),
        ("http://192.168.0.10:11434/v1", false),
        ("http://localhost.evil.example/v1", false),
    ])
    func loopback(endpoint: String, esperado: Bool) {
        #expect((LocalModelCatalog.loopbackHost(of: endpoint) != nil) == esperado)
    }

    @Test("um endereço remoto é recusado antes de qualquer pedido sair")
    func remotoRecusado() async {
        let catalogo = LocalModelCatalog(session: .shared, timeout: 1)
        await #expect(throws: LocalModelCatalogError.endpointIsNotLoopback) {
            _ = try await catalogo.models(endpoint: "https://api.openai.com/v1")
        }
    }

    /// Servidor fora do ar é um **estado**, não um erro para a pessoa ler: a
    /// página desenha "não está rodando" e oferece tentar de novo.
    @Test("servidor que não responde vira estado, não exceção")
    func foraDoArViraEstado() async {
        // Porta alta e fechada: nada escuta aqui, e o pedido falha depressa.
        let catalogo = LocalModelCatalog(session: .shared, timeout: 1)
        let estado = await catalogo.probe(endpoint: "http://127.0.0.1:49999/v1")
        #expect(estado == .notRunning)
        #expect(!estado.isRunning)
        #expect(estado.models.isEmpty)
    }

    @Test("o tamanho vira a unidade que a pessoa lê")
    func tamanhoLegivel() {
        #expect(LocalModel(id: "a", sizeBytes: 18_000_000_000).sizeLabel == "18 GB")
        #expect(LocalModel(id: "b", sizeBytes: 820_000_000).sizeLabel == "820 MB")
        // Sem tamanho informado (o `/v1/models` compatível não traz) a coluna
        // some, em vez de a tela inventar um número.
        #expect(LocalModel(id: "c").sizeLabel == nil)
        #expect(LocalModel(id: "d", sizeBytes: 0).sizeLabel == nil)
    }
}
