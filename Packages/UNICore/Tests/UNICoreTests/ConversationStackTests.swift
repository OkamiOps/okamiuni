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
        #expect(conversa.newestFirst.map(\.id) == ["resposta", "original"])
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

/// A outra metade da tela do dono: a conversa que **abre já recolhida
/// inteira**, sem uma linha aberta sequer.
///
/// Como se chega lá: recolher a última aberta (o que a M3-10 passou a
/// permitir, e com razão), sair para outra conversa e voltar. O estado ficava
/// guardado com a chave da conversa de origem, e voltar a ela o encontrava
/// intacto — três linhas recolhidas e nenhum corpo à vista.
@Suite("A pilha ao trocar de conversa")
struct ConversationStackResetTests {

    private var outra: Conversation {
        Conversation(key: "t2", messages: [msg("z", at: 300, thread: "t2")])!
    }

    @Test("Numa conversa, o que abre é o estado dela")
    func oEstadoDaPropriaConversa() {
        let recolhida = ConversationStack.Opened(conversationKey: "t1", ids: [])
        #expect(ConversationStack.expanded(conversa, opened: recolhida).isEmpty)
        #expect(ConversationStack.expanded(conversa, opened: nil) == ["resposta"])
    }

    @Test("O estado de outra conversa não vale nesta")
    func oEstadoDeOutraConversaNaoVale() {
        let recolhida = ConversationStack.Opened(conversationKey: "t1", ids: [])
        #expect(ConversationStack.expanded(outra, opened: recolhida) == ["z"])
    }

    /// O caminho inteiro do dono, em três passos: recolher tudo, ir para outra
    /// conversa, voltar. Voltar é abrir de novo — e abrir é a mais recente
    /// aberta.
    @Test("Ir para outra conversa e voltar abre a mais recente de novo")
    func voltarAbreDeNovo() {
        // 1. Na conversa, a pessoa recolhe a última aberta.
        var guardado: ConversationStack.Opened? = ConversationStack.Opened(
            conversationKey: conversa.key,
            ids: ConversationStack.toggle("resposta", in: ConversationStack.initialExpanded(conversa))
        )
        #expect(ConversationStack.expanded(conversa, opened: guardado).isEmpty)

        // 2. Ela vai para outra conversa. O estado da anterior não a acompanha.
        guardado = ConversationStack.carried(guardado, to: outra)
        #expect(guardado == nil)

        // 3. E volta. A pilha nasce como toda pilha nasce.
        #expect(ConversationStack.expanded(conversa, opened: guardado) == ["resposta"])
    }

    /// Trocar de mensagem **dentro** da mesma conversa não é trocar de
    /// conversa: quem abriu uma mensagem antiga da pilha e clicou noutra linha
    /// da lista da mesma conversa não pode perder o que estava lendo.
    @Test("Ficar na mesma conversa preserva o que está aberto")
    func amesmaConversaPreserva() {
        let aberto = ConversationStack.Opened(conversationKey: "t1", ids: ["original"])
        #expect(ConversationStack.carried(aberto, to: conversa) == aberto)
    }
}
