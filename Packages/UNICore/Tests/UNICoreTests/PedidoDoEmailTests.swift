import Foundation
import Testing
@testable import UNICore

@Suite("O que o email pede")
struct PedidoDoEmailTests {

    private let agora = Date(timeIntervalSince1970: 1_756_120_860)  // 25/08/2026

    @Test("sem análise não há pedido — nada é inventado")
    func semAnaliseNaoInventa() {
        #expect(PedidoDoEmail.de(triagem: nil, agora: agora) == nil)
    }

    @Test("precisa de resposta vira um pedido visível")
    func precisaDeResposta() throws {
        let pedido = try #require(
            PedidoDoEmail.de(
                triagem: MessageTriage(needsReply: true, intent: .request, urgency: .normal),
                agora: agora
            )
        )
        #expect(pedido.chamada == "Pede resposta")
        #expect(pedido.prazo == nil)
    }

    @Test("o prazo entra no pedido, com a data por extenso")
    func prazoEntra() throws {
        let pedido = try #require(
            PedidoDoEmail.de(
                triagem: MessageTriage(
                    needsReply: true, intent: .request, urgency: .high,
                    deadline: DetectedDeadline(
                        date: Date(timeIntervalSince1970: 1_756_380_060),
                        evidence: "preciso até sexta"
                    )
                ),
                agora: agora
            )
        )
        #expect(pedido.prazo == "até 28/08")
        #expect(pedido.urgente)
    }

    @Test("uma newsletter que não pede nada não desenha pedido")
    func newsletterNaoPede() {
        #expect(
            PedidoDoEmail.de(
                triagem: MessageTriage(needsReply: false, intent: .newsletter, urgency: .low),
                agora: agora
            ) == nil
        )
    }
}

@Suite("Tem mais coisa abaixo?")
struct RolagemDoCorpoTests {

    @Test("cabe inteiro: não há nada abaixo")
    func cabeInteiro() {
        #expect(!RolagemDoCorpo.temMaisAbaixo(conteudo: 120, visivel: 200, deslocamento: 0))
    }

    @Test("mais longo que a janela: há mais abaixo")
    func sobraTexto() {
        #expect(RolagemDoCorpo.temMaisAbaixo(conteudo: 900, visivel: 200, deslocamento: 0))
    }

    @Test("no fim da rolagem o aviso some")
    func noFimSome() {
        #expect(!RolagemDoCorpo.temMaisAbaixo(conteudo: 900, visivel: 200, deslocamento: 700))
    }

    @Test("meio pixel de sobra não é aviso")
    func meioPixelNaoConta() {
        #expect(!RolagemDoCorpo.temMaisAbaixo(conteudo: 202, visivel: 200, deslocamento: 0))
    }
}
