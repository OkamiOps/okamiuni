import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// Uma porta de corpo que existe só para existir: `loadBodyIfNeeded` sai na
/// primeira guarda sem uma, e é justamente o pedido a ela que este ensaio mede.
///
/// Ela nunca responde — a espera é o que o teste quer ver. Quando a janela do
/// ensaio fecha, o `.task` da pilha é cancelado com ela, e uma porta que
/// respondesse só correria contra esse cancelamento.
private struct PortaMuda: BodyFetching {
    func fetchBody(accountID: String, messageID: String) async throws -> FetchedBody {
        try await Task.sleep(for: .seconds(60))
        return FetchedBody(paragraphs: [])
    }
}

/// O estado da pilha, guardado fora da `View` para o teste o poder ler
/// **depois** do clique — `@State` só existe dentro de uma `View`.
///
/// `@Observable` não é detalhe: uma caixa comum guardaria o valor novo sem o
/// SwiftUI saber que algo mudou, a pilha não redesenharia, e o ensaio mediria
/// um clique que a interface nunca viu. Foi o que aconteceu ao escrever isto.
@Observable
@MainActor
private final class EstadoDaPilha {
    var opened: ConversationStack.Opened?

    var binding: Binding<ConversationStack.Opened?> {
        Binding(get: { self.opened }, set: { self.opened = $0 })
    }
}

private func msg(
    _ id: String, at segundos: TimeInterval, from: String,
    body: [String] = [], snippet: String = "trecho",
    isRead: Bool = true
) -> Message {
    Message(
        id: id, accountID: "zoho",
        from: Contact(name: from, address: "\(from.lowercased())@x.com"),
        receivedAt: Date(timeIntervalSince1970: segundos),
        subject: "Lembrete rápido: nossa call amanhã", snippet: snippet, body: body,
        tags: [], bucket: .today, isRead: isRead,
        summary: nil, detectedEvent: nil, threadKey: "t1"
    )
}

/// **O defeito da tela do dono, no clique de verdade.**
///
/// "A conversa 'Lembrete rápido' mostra as três mensagens recolhidas e clicar
/// na linha do Carlos Eduardo Favini não abre nada."
///
/// A linha abria. O que ela mostrava era vazio: o pedido de corpo era um
/// `.task` pendurado no leitor inteiro — e o leitor inteiro é **uma** mensagem,
/// a selecionada. Nenhuma outra da pilha pedia corpo nenhum, `bodyLoad` ficava
/// `nil` para ela, e `nil` é o ramo que o leitor desenha como `EmptyView` (o
/// caso legítimo das fixtures do Marco 1, que já têm corpo). Numa conta real,
/// onde a mensagem antiga da conversa está no banco sem corpo, expandir dava
/// nada.
@Suite("A pilha da conversa, no clique")
@MainActor
struct ConversationStackClickTests {

    private func store(porta: (any BodyFetching)?) async -> MailStore {
        let store = MailStore(
            source: InMemoryMailSource(
                accounts: [],
                messages: [
                    msg("c", at: 300, from: "Marina", body: ["resposta"]),
                    msg("b", at: 200, from: "Ricardo", body: ["meio"]),
                    // A de baixo, sem corpo baixado: é a do Favini.
                    msg("a", at: 100, from: "Favini", snippet: "primeira linha"),
                ],
                agenda: []
            ),
            bodyPort: porta
        )
        await store.load()
        store.select(bucket: .all)
        store.select(message: "c")
        return store
    }

    private func pilha(_ store: MailStore, estado: EstadoDaPilha) throws -> some View {
        let conversa = try #require(store.conversation(of: "c"))
        return ConversationStackView(
            store: store, conversa: conversa, opened: estado.binding
        ) { message in
            // O miolo do leitor não entra aqui: o que este ensaio mede é o
            // clique e o que ele dispara, e o corpo de verdade traria uma
            // `WKWebView` para dentro de um teste.
            Text(message.body.first ?? "")
        }
    }

    /// O clique na linha recolhida do Favini — agora a **última** da pilha,
    /// com a mais nova no topo — expande **e pede o corpo dela**.
    ///
    /// Primeiro recolhe a recente (a primeira linha, já aberta); com as três
    /// compactas, o Favini é a terceira. Sem o `.task` de
    /// `ConversationStackView`, a porta nunca é perguntada.
    @Test("Clicar na mensagem recolhida abre e busca o corpo dela")
    func oCliqueAbreEBusca() async throws {
        let store = await store(porta: PortaMuda())
        let estado = EstadoDaPilha()
        let cabeca = ConversationStackView<EmptyView>.alturaDoCabecalho
        let linha = ConversationStackView<EmptyView>.alturaDaLinha

        try CliqueDeEnsaio.em(
            pilha(store, estado: estado),
            size: CGSize(width: 700, height: 400),
            aY: cabeca + linha / 2
        )
        #expect(estado.opened?.ids.contains("c") == false)

        try CliqueDeEnsaio.em(
            pilha(store, estado: estado),
            size: CGSize(width: 700, height: 400),
            aY: cabeca + linha * 2 + linha / 2
        )

        #expect(estado.opened?.ids.contains("a") == true)
        #expect(store.bodyLoad(for: "a") == .carregando)
    }

    /// A outra metade do toggle: a mais recente agora é a **primeira** linha
    /// da pilha, já aberta. O clique no meio dela recolhe.
    @Test("Clicar na mensagem aberta recolhe")
    func oCliqueRecolhe() async throws {
        let store = await store(porta: nil)
        let estado = EstadoDaPilha()
        let altura = ConversationStackView<EmptyView>.alturaDaLinha

        try CliqueDeEnsaio.em(
            pilha(store, estado: estado),
            size: CGSize(width: 700, height: 400),
            aY: ConversationStackView<EmptyView>.alturaDoCabecalho + altura / 2
        )

        #expect(estado.opened?.ids.contains("c") == false)
    }

    /// **A faixa da contagem é rótulo, não linha.** Clicar nela não abre nem
    /// recolhe nada.
    ///
    /// É também o que prova que ela **existe**: sem o cabeçalho, este mesmo
    /// ponto cai dentro da primeira linha recolhida e a abre — e o teste vira
    /// vermelho por ter aberto o que não devia.
    @Test("Clicar na faixa da contagem não mexe na pilha")
    func oCliqueNoCabecalhoNaoAbre() async throws {
        let store = await store(porta: nil)
        let estado = EstadoDaPilha()

        try CliqueDeEnsaio.em(
            pilha(store, estado: estado),
            size: CGSize(width: 700, height: 400),
            aY: ConversationStackView<EmptyView>.alturaDoCabecalho / 2
        )

        // Nada abriu, e nada foi lido.
        #expect(estado.opened == nil)
    }

    /// A queixa do dono depois do primeiro conserto: a pilha já abre com a
    /// mais recente expandida, então o clique que marcava lida **nunca
    /// acontecia** — ele só dispara ao abrir uma recolhida. Expandir e
    /// recolher a última era o único jeito de a conversa sair de não lida.
    @Test("Mostrar a pilha com a mais recente já aberta marca a conversa inteira")
    func aparecerComAUltimaAbertaMarcaAConversa() async throws {
        let store = MailStore(
            source: InMemoryMailSource(
                accounts: [],
                messages: [
                    msg("c", at: 300, from: "Marina", isRead: false),
                    msg("a", at: 100, from: "Favini", isRead: false),
                ],
                agenda: []
            )
        )
        await store.load()
        store.select(bucket: .all)
        // A seleção padrão aponta para a última e não marca como lida — é o
        // caminho de abrir o app com a conversa já no leitor.
        #expect(store.messages.contains { !$0.isRead })

        let estado = EstadoDaPilha()
        try CliqueDeEnsaio.em(
            pilha(store, estado: estado),
            size: CGSize(width: 700, height: 400),
            aY: ConversationStackView<EmptyView>.alturaDoCabecalho / 2
        )

        #expect(store.messages.allSatisfy { $0.isRead })
        #expect(store.conversation(of: "c")?.hasUnread == false)
    }
}
