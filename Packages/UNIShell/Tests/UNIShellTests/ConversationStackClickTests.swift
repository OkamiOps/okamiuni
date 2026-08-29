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
    body: [String] = [], snippet: String = "trecho"
) -> Message {
    Message(
        id: id, accountID: "zoho",
        from: Contact(name: from, address: "\(from.lowercased())@x.com"),
        receivedAt: Date(timeIntervalSince1970: segundos),
        subject: "Lembrete rápido: nossa call amanhã", snippet: snippet, body: body,
        tags: [], bucket: .today, isRead: true,
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

    /// O clique na linha recolhida do Favini — a primeira da pilha, dentro dos
    /// 38pt da primeira linha — expande **e pede o corpo dela**.
    ///
    /// A pilha passou a abrir com o cabeçalho da contagem (M3-21), então toda
    /// linha desce `alturaDoCabecalho`. O deslocamento entra pela constante, e
    /// não por um número novo: quem mudar a altura do cabeçalho não precisa
    /// vir consertar dois cliques aqui.
    ///
    /// Cai por mutação: sem o `.task` de `ConversationStackView`, a porta nunca
    /// é perguntada, `bodyLoad` fica `nil` e a linha expande para o vazio — que
    /// é exatamente o app que o dono usou.
    @Test("Clicar na mensagem recolhida abre e busca o corpo dela")
    func oCliqueAbreEBusca() async throws {
        let store = await store(porta: PortaMuda())
        let estado = EstadoDaPilha()

        try CliqueDeEnsaio.em(
            pilha(store, estado: estado),
            size: CGSize(width: 700, height: 400),
            aY: ConversationStackView<EmptyView>.alturaDoCabecalho
                + ConversationStackView<EmptyView>.alturaDaLinha / 2
        )

        // Abriu: o estado da pilha passou a ter a mensagem de baixo.
        #expect(estado.opened?.ids.contains("a") == true)
        // E abrir **pediu o corpo dela** — o defeito era este pedido não
        // existir. `carregando` é posto por `loadBodyIfNeeded` depois de todas
        // as guardas e imediatamente antes de chamar a porta: vê-lo aqui é ver
        // o pedido sair. Sem o `.task`, `bodyLoad` fica `nil` e a linha expande
        // para o vazio, que é o app que o dono usou.
        #expect(store.bodyLoad(for: "a") == .carregando)
    }

    /// A outra metade do toggle, pelo mesmo cano: clicar na **aberta** recolhe.
    /// A mais recente é a última linha da pilha — três linhas de 38pt, e o
    /// clique cai no meio da terceira.
    @Test("Clicar na mensagem aberta recolhe")
    func oCliqueRecolhe() async throws {
        let store = await store(porta: nil)
        let estado = EstadoDaPilha()
        let altura = ConversationStackView<EmptyView>.alturaDaLinha

        try CliqueDeEnsaio.em(
            pilha(store, estado: estado),
            size: CGSize(width: 700, height: 400),
            aY: ConversationStackView<EmptyView>.alturaDoCabecalho + altura * 2 + altura / 2
        )

        #expect(estado.opened?.ids.contains("c") == false)
    }
}
