import Foundation
import Testing
@testable import UNICore

private func msg(_ id: String, at segundos: TimeInterval, thread: String = "t1") -> Message {
    Message(
        id: id, accountID: "zoho",
        from: Contact(name: "Marina", address: "marina@x.com"),
        receivedAt: Date(timeIntervalSince1970: segundos),
        subject: "Lembrete rápido: nossa call amanhã", snippet: "trecho", body: [],
        tags: [], bucket: .today, isRead: true,
        summary: nil, detectedEvent: nil,
        threadKey: thread
    )
}

/// A conversa de duas: a original de 15 de julho e a resposta de 16 — a mesma
/// da tela do dono.
private var conversa: Conversation {
    Conversation(key: "t1", messages: [msg("original", at: 100), msg("resposta", at: 200)])!
}

@Suite("A pilha da conversa")
struct ConversationStackTests {

    /// O defeito da tela: a pilha abria a **original** e deixava a resposta
    /// recolhida embaixo.
    @Test("Quem nasce aberta é a mais recente, não a primeira")
    func aMaisRecenteNasceAberta() {
        #expect(ConversationStack.initialExpanded(conversa) == ["resposta"])
    }

    /// E é a mais recente por `receivedAt`, não pela ordem em que a lista
    /// entregou as mensagens: uma fonte que devolva a conversa ao contrário
    /// não pode virar o leitor do avesso.
    @Test("A mais recente é a do relógio, não a do fim do array")
    func aMaisRecenteEDoRelogio() {
        let invertida = Conversation.build(from: [msg("resposta", at: 200), msg("original", at: 100)])
        #expect(ConversationStack.initialExpanded(invertida[0]) == ["resposta"])
    }

    /// Uma conversa de uma mensagem só abre essa mensagem — é o caminho de
    /// todo dia, e o que o Marco 1 já desenhava.
    @Test("Com uma mensagem só, ela é a que abre")
    func umaMensagem() {
        let sozinha = Conversation(key: "t2", messages: [msg("z", at: 1, thread: "t2")])!
        #expect(ConversationStack.initialExpanded(sozinha) == ["z"])
    }

    /// O outro defeito: clicar abria e não recolhia.
    @Test("Clicar na aberta recolhe; clicar na recolhida abre")
    func oCliqueVaiEVolta() {
        let inicial = ConversationStack.initialExpanded(conversa)
        let comAsDuas = ConversationStack.toggle("original", in: inicial)
        #expect(comAsDuas == ["original", "resposta"])

        let semAResposta = ConversationStack.toggle("resposta", in: comAsDuas)
        #expect(semAResposta == ["original"])
    }

    /// Sem trava de "ao menos uma aberta": a conversa inteira recolhida é um
    /// estado legítimo, e clicar na última aberta tem de fazer alguma coisa.
    @Test("Recolher a última aberta é permitido")
    func recolherTodas() {
        let inicial = ConversationStack.initialExpanded(conversa)
        #expect(ConversationStack.toggle("resposta", in: inicial).isEmpty)
    }
}
