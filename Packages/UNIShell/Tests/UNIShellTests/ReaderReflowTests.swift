import Foundation
import Testing
import UNICore
@testable import UNIShell

/// O corpo que o dono pôs na tela, do jeito que ele chega do servidor: um
/// parágrafo só, quebrado à mão no meio da frase.
private let corpoDaTela = [
    "Olá,",
    "Passando para confirmar nossa call amanhã, 16 de julho, às 15h,\nno horário\nde Brasília.",
    "O link da reunião está disponível no convite da agenda.",
    "Até lá!",
    "Hugo",
]

private func mensagem(corpo: [String]) -> Message {
    Message(
        id: "reflow", accountID: "zoho",
        from: Contact(name: "Hugo Marques", address: "hugo@exemplo.com"),
        receivedAt: Fixtures.today, subject: "Nossa call",
        snippet: "Passando para confirmar", body: corpo,
        tags: [], bucket: .today, isRead: true, summary: nil,
        detectedEvent: nil, dayOffset: 0, replyHints: []
    )
}

@Suite("O leitor refluindo o texto plano")
struct ReaderReflowTests {

    @Test("O email da tela vira cinco blocos, e a call fica inteira num só")
    func cincoBlocos() {
        let blocos = ReaderPane.paragrafos(de: mensagem(corpo: corpoDaTela))
        #expect(blocos.count == 5)
        #expect(blocos[1] == """
            Passando para confirmar nossa call amanhã, 16 de julho, às 15h, \
            no horário de Brasília.
            """)
        #expect(blocos.allSatisfy { !$0.contains("\n") })
    }

    @Test("A linha da mensagem recolhida continua sendo a primeira linha crua")
    func primeiraLinhaNaoRefluida() {
        // A pilha recolhida mostra **uma** linha, cortada no fim: o refluxo
        // não tem o que melhorar ali, e mexer nela mudaria o que a M3-10 fixou.
        #expect(ReaderPane.primeiraLinha(de: mensagem(corpo: [corpoDaTela[1]]))
            == "Passando para confirmar nossa call amanhã, 16 de julho, às 15h,")
    }

    @Test("As mensagens de exemplo do Marco 1 atravessam byte a byte")
    func fixturesIntactas() {
        for exemplo in Fixtures.messages {
            #expect(ReaderPane.paragrafos(de: exemplo) == exemplo.body)
        }
    }

    @Test("A lista dentro do corpo continua uma lista")
    func listaNoCorpo() {
        let corpo = ["Pendências:\n- renovar o certificado\n- fechar o escopo com o jurídico"]
        #expect(ReaderPane.paragrafos(de: mensagem(corpo: corpo)) == corpo)
    }
}
