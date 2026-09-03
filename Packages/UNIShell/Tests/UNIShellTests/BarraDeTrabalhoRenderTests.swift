import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
import UNISync
@testable import UNIShell

/// A conferência com os olhos, e a prova que não depende deles.
///
/// A composição aqui é a do `InboxScreen`: a barra do topo (com a barra fina
/// de trabalho) por cima do dashboard. Os PNGs saem com `UNI_RENDER_DIR`;
/// as afirmações valem sem eles.
@Suite("Barra de trabalho, na tela")
@MainActor
struct BarraDeTrabalhoRenderTests {

    private static let size = CGSize(width: 1_200, height: 916)

    private let codex = AssistantDestination(
        label: "Codex · ChatGPT", detail: "Sai deste Mac para a OpenAI.", isLocal: false
    )

    private func conversation(loading: Bool = false) -> AssistantConversation {
        AssistantConversation(
            scope: .email,
            context: .init(subject: "Caixa e agenda de hoje"),
            destination: codex,
            engine: AssistantEngine(supportsDraftReply: false) { _ in "" },
            debugState: AssistantPanelDebugState(isLoading: loading)
        )
    }

    /// Uma caixa com `count` mensagens que pedem decisão, e um corpo de
    /// verdade na primeira — é dele que a prévia vive.
    private func loja(_ count: Int, corpoLongo: Bool = false) async -> MailStore {
        let corpo = corpoLongo ? Self.corpoDeVerdade : ["Uma linha só, e nada mais."]
        let mensagens = (1...count).map { i in
            Message(
                id: "m\(i)",
                accountID: Fixtures.accounts[0].id,
                from: Contact(name: "Remetente \(i)", address: "quem\(i)@exemplo.com"),
                receivedAt: Fixtures.today.addingTimeInterval(TimeInterval(-i * 600)),
                subject: "Assunto de número \(i), com o bastante para ocupar a linha",
                snippet: "trecho \(i)",
                body: i == 1 ? corpo : [],
                tags: [UNICore.Tag(name: "Precisa resposta")],
                bucket: .today,
                isRead: false,
                summary: nil,
                detectedEvent: nil
            )
        }
        let store = MailStore(source: InMemoryMailSource(
            accounts: Fixtures.accounts, messages: mensagens, agenda: []
        ))
        await store.load()
        return store
    }

    private static let corpoDeVerdade = [
        "Olá,",
        "Seguem os pontos da reunião de ontem, para ninguém depender da memória:",
        "1. O orçamento de consultoria fecha no dia 12, e precisa da assinatura "
            + "da diretoria antes disso.",
        "2. A migração do domínio foi adiada para depois do fechamento do mês, "
            + "por causa da janela de manutenção do provedor.",
        "3. O time de produto quer a lista de requisitos até sexta.",
        "4. A proposta de 40 pessoas continua de pé, com o desconto combinado.",
        "5. Falta confirmar a data da visita técnica.",
        "Qualquer coisa, é só responder aqui que eu ajusto.",
        "Abraço,",
        "Marina",
    ]

    private func tela(
        store: MailStore,
        conversation: AssistantConversation,
        workload: ChromeWorkload
    ) -> some View {
        VStack(spacing: 0) {
            WindowChrome(
                workspace: .constant(.dashboard),
                query: .constant(""),
                accountCount: 1,
                onToggleSidebar: {},
                onToggleAgenda: {},
                syncStatus: workload.status,
                statusDetail: workload.detail,
                onReloadMailbox: {}
            )
            DashboardScreen(
                store: store,
                now: Fixtures.nowMinute,
                today: Fixtures.today,
                conversation: conversation
            )
        }
        .environment(ThemeStore())
    }

    @Test("poucos itens: o campo do assistente sobe, e a barra fica quieta")
    func fewRowsHugTheList() async throws {
        let store = await loja(3, corpoLongo: true)
        let carga = ChromeWorkload.combining([.sync(.ready)])
        #expect(!carga.isBusy)
        // O sucessor de `assistantHugsList`: o campo do assistente saiu do
        // dashboard no 08 (o botão "Perguntar · ⌘J" o substitui), então o que
        // resta afirmar é que a carga quieta escreve o relógio, não "Atualizando…".
        #expect(
            DashboardMetrics.updateLabel(nowMinute: Fixtures.nowMinute, isBusy: carga.isBusy)
                .hasPrefix("Atualizado agora")
        )
        _ = try #require(Render.snapshot(
            tela(store: store, conversation: conversation(), workload: carga),
            named: "poucos", size: Self.size, theme: .okami
        ))
    }

    @Test("muitos itens: a lista enche a coluna e o campo volta para o rodapé")
    func manyRowsKeepTheMockupFlexpad() async throws {
        let store = await loja(7, corpoLongo: true)
        _ = try #require(Render.snapshot(
            tela(store: store, conversation: conversation(), workload: .combining([.sync(.ready)])),
            named: "muitos", size: Self.size, theme: .okami
        ))
    }

    @Test("a IA pensando acende a barra fina, e o rótulo diz a quem se pergunta")
    func thinkingLightsTheBar() async throws {
        let store = await loja(4, corpoLongo: true)
        let conversa = conversation(loading: true)
        let carga = ChromeWorkload.combining([
            .sync(.ready), .assistant(kind: .question, destination: codex),
        ])
        #expect(carga.isBusy)
        #expect(carga.detail == "Perguntando ao Codex · ChatGPT")

        let pensando = try #require(Render.bitmap(
            tela(store: store, conversation: conversa, workload: carga),
            size: Self.size, theme: .okami
        ))
        let parada = try #require(Render.bitmap(
            tela(store: store, conversation: conversation(), workload: .combining([.sync(.ready)])),
            size: Self.size, theme: .okami
        ))
        // Parada, a barra é **só o trilho cinza**: cor nela significa trabalho
        // acontecendo, e nada mais. Então a conta é direta — com a IA pensando
        // aparece `activity` na tela; sem ela, nenhum pixel de `activity`.
        #expect(
            parada.pixels(matching: Theme.okami.activity, tolerance: 0.02) == 0,
            "a barra parada pintou cor, e cor aqui quer dizer trabalho"
        )
        #expect(
            pensando.pixels(matching: Theme.okami.activity, tolerance: 0.02) > 0,
            "a barra não acendeu com a IA pensando"
        )
        _ = try #require(Render.snapshot(
            tela(store: store, conversation: conversa, workload: carga),
            named: "pensando", size: Self.size, theme: .okami
        ))
    }

    /// O que separa "trabalhando sem saber quanto falta" de "cheio": o cursor
    /// ocupa uma **fatia** da barra e viaja. Congelado na captura ele ainda é
    /// uma fatia, e é isso que dá para provar sem relógio de animação — uma
    /// barra cheia e uma barra com cursor não pintam a mesma quantidade de cor.
    @Test("trabalhando sem fração, o cursor é uma fatia — não a barra cheia")
    func indeterminateDrawsATravellingCursor() async throws {
        let store = await loja(4, corpoLongo: true)
        func tinta(_ carga: ChromeWorkload) throws -> Int {
            try #require(Render.bitmap(
                tela(store: store, conversation: conversation(), workload: carga),
                size: Self.size, theme: .okami
            )).pixels(matching: Theme.okami.activity, tolerance: 0.02)
        }

        let cursor = try tinta(.combining([.sync(.loading(fraction: nil))]))
        let cheia = try tinta(.combining([.backlog(done: 312, total: 312)]))
        #expect(cursor > 0, "o cursor não apareceu")
        #expect(
            cursor < cheia / 2,
            "o cursor pintou quase a barra inteira, que é a confusão que ele desfaz"
        )
    }

    /// Falha não é uma cor de trabalho: ela é `danger`, ocupa a barra inteira e
    /// não se mexe. Parada e vermelha, ela não se confunde com o cursor.
    @Test("a falha pinta a barra inteira de danger, e nada de activity")
    func failureFillsTheBarInDanger() async throws {
        let store = await loja(4, corpoLongo: true)
        let mapa = try #require(Render.bitmap(
            tela(
                store: store, conversation: conversation(),
                workload: .combining([.sync(.failed("sem rede"))])
            ),
            size: Self.size, theme: .okami
        ))
        #expect(mapa.pixels(matching: Theme.okami.danger, tolerance: 0.02) > 0)
        #expect(mapa.pixels(matching: Theme.okami.activity, tolerance: 0.02) == 0)
    }

    @Test("a análise do acervo desenha a fração de verdade")
    func backlogDrawsARealFraction() async throws {
        let store = await loja(4, corpoLongo: true)
        let carga = ChromeWorkload.combining([
            .sync(.loading(fraction: nil)), .backlog(done: 23, total: 312),
        ])
        #expect(carga.status == .loading(fraction: 23.0 / 312.0))
        #expect(carga.detail == "Analisando 23 de 312 · Sincronizando")

        let pouco = try #require(Render.bitmap(
            tela(store: store, conversation: conversation(), workload: carga),
            size: Self.size, theme: .okami
        ))
        let quase = try #require(Render.bitmap(
            tela(
                store: store, conversation: conversation(),
                workload: .combining([.sync(.ready), .backlog(done: 300, total: 312)])
            ),
            size: Self.size, theme: .okami
        ))
        // 23 de 312 pinta uma faixa curta; 300 de 312 pinta quase a barra
        // inteira. É a fração desenhando, e não um pulso.
        #expect(
            quase.pixels(matching: Theme.okami.activity, tolerance: 0.02)
                > pouco.pixels(matching: Theme.okami.activity, tolerance: 0.02),
            "a fração do acervo não chegou na barra"
        )
        _ = try #require(Render.snapshot(
            tela(store: store, conversation: conversation(), workload: carga),
            named: "acervo", size: Self.size, theme: .okami
        ))
    }
}
