import Foundation
import Testing
import UNICore
@testable import UNIShell

/// O que a prévia do meio mostra é o **corpo** do email, e não a primeira
/// frase dele. A escolha do texto é decisão pura, e mora aqui.
@Suite("Corpo da prévia")
struct DashboardPreviewBodyTests {

    private func mensagem(
        body: [String] = [], bodyHTML: String? = nil, snippet: String = ""
    ) -> Message {
        Message(
            id: "m1", accountID: "a1",
            from: Contact(name: "Marina", address: "marina@x.com"),
            receivedAt: Date(timeIntervalSince1970: 0),
            subject: "Assunto", snippet: snippet, body: body,
            tags: [], bucket: .today, isRead: true,
            summary: nil, detectedEvent: nil,
            bodyHTML: bodyHTML
        )
    }

    @Test("o corpo em texto ganha de tudo, com os parágrafos preservados")
    func plainBodyWinsAndKeepsParagraphs() {
        let estado = DashboardPreviewBody.state(
            for: mensagem(body: ["Primeira linha.", "Segunda linha."], snippet: "Primeira"),
            load: nil
        )
        #expect(estado.text == "Primeira linha.\n\nSegunda linha.")
        #expect(!estado.isWaiting)
        #expect(estado.failure == nil)
    }

    @Test("HTML vira texto legível, como o leitor já faz")
    func htmlBecomesReadableText() {
        let estado = DashboardPreviewBody.state(
            for: mensagem(
                bodyHTML: "<style>p{color:red}</style><p>Olá,</p><p>Segue o contrato.</p>",
                snippet: "Olá"
            ),
            load: nil
        )
        #expect(estado.text == "Olá,\n\nSegue o contrato.")
    }

    @Test("sem corpo e buscando, o resumo segura o lugar e a espera é dita")
    func waitingShowsTheSnippet() {
        let estado = DashboardPreviewBody.state(
            for: mensagem(snippet: "Nova resposta no formulário."),
            load: .carregando
        )
        #expect(estado.text == "Nova resposta no formulário.")
        #expect(estado.isWaiting)
    }

    @Test("a busca que falhou diz a causa, sem apagar o resumo")
    func failureKeepsTheSnippetAndNamesTheCause() {
        let estado = DashboardPreviewBody.state(
            for: mensagem(snippet: "Nova resposta."),
            load: .falhou("Sem conexão")
        )
        #expect(estado.text == "Nova resposta.")
        #expect(estado.failure == "Sem conexão")
        #expect(!estado.isWaiting)
    }

    @Test("buscado e sem texto nenhum é vazio honesto, não espera eterna")
    func fetchedWithoutTextIsEmpty() {
        let estado = DashboardPreviewBody.state(for: mensagem(), load: .buscado)
        #expect(estado.text.isEmpty)
        #expect(!estado.isWaiting)
        #expect(estado.isEmpty)
    }

    @Test("o corpo que já chegou não é buscado de novo")
    func hydratedMessagesDoNotAskForABody() {
        #expect(!DashboardPreviewBody.needsBody(mensagem(body: ["Tem corpo."])))
        #expect(!DashboardPreviewBody.needsBody(mensagem(bodyHTML: "<p>Tem</p>")))
        #expect(DashboardPreviewBody.needsBody(mensagem(snippet: "Só o resumo")))
    }
}
