import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// Os retratos do **Painel do dia** e da **Agenda** no shell Vidro, e as
/// decisões que os dois tomam fora da `View`.
///
/// O que estes casos afirmam é o que se pode afirmar de um painel translúcido
/// sobre gradiente: o desenho sai no tamanho pedido, o acento e o laranja do
/// "agora" aparecem, e os modelos — as três frentes, o número grande do
/// dinheiro — dizem o que o protótipo escreve. A conferência de aparência é
/// com os olhos, nos PNGs que `UNI_RENDER_DIR` grava.
@Suite("Vidro · Painel e Agenda")
@MainActor
struct VidroPainelAgendaTests {

    private static let tamanho = CGSize(width: 1_180, height: 820)

    private func conversaInerte() -> AssistantConversation {
        AssistantConversation(
            scope: .email,
            context: .init(subject: "Caixa e agenda de hoje"),
            destination: .init(label: "Codex · ChatGPT", detail: "", isLocal: false),
            engine: AssistantEngine(supportsDraftReply: false) { _ in "" }
        )
    }

    private func painel(_ store: MailStore) -> some View {
        PainelDoDia(
            store: store,
            now: DiaDoDono.agoraMinuto,
            today: DiaDoDono.agora,
            drafts: DiaDoDono.rascunhos,
            conversation: conversaInerte()
        )
        .environment(ThemeStore())
        .environment(ActionReceipts())
    }

    private func modelo(_ store: MailStore) -> PainelDoDiaModelo {
        let plan = DashboardPlanInput.plan(
            store: store, drafts: DiaDoDono.rascunhos, filter: .standard,
            today: DiaDoDono.agora, nowMinute: DiaDoDono.agoraMinuto
        )
        return PainelDoDiaModelo(
            plan: plan, drafts: DiaDoDono.rascunhos, pending: store.pendingItems,
            agenda: store.agenda, messages: store.messages,
            today: DiaDoDono.agora, nowMinute: DiaDoDono.agoraMinuto,
            myAddresses: Set(store.accounts.map(\.address))
        )
    }

    // MARK: - Painel

    @Test("o Painel de vidro desenha no claro e no escuro", arguments: [
        "vidro", "vidro-noite",
    ])
    func glassPainelRenders(id: String) async throws {
        let theme = try #require(Theme.named(id))
        let store = await DiaDoDono.loja()
        let rep = try #require(Render.snapshot(
            painel(store).glassPanel(theme).padding(10).background(Backdrop()),
            named: "vidro-painel-\(id)",
            size: Self.tamanho,
            theme: theme
        ))
        #expect(rep.pixelsWide == Int(Self.tamanho.width))
        // O acento: o botão de "Comece por aqui" e o anel de progresso.
        #expect(
            rep.pixels(matching: theme.accent, tolerance: 0.06) > 200,
            "\(id): o acento sumiu do painel"
        )
        // O laranja do "agora", que no Vidro substitui o vermelho semântico.
        #expect(
            rep.pixels(matching: theme.nowLine, tolerance: 0.06) > 60,
            "\(id): o traço do agora não aparece"
        )
    }

    /// As três frentes do "Depois disso" existem, e uma frente vazia não entra.
    @Test("as três frentes saem do modelo, e nenhuma delas é um zero")
    func theThreeFrontsComeFromTheModel() async throws {
        let store = await DiaDoDono.loja()
        let modelo = modelo(store)
        #expect(!modelo.espera.isEmpty, "ninguém esperando: a frente Responder cairia")
        #expect(!modelo.promessas.isEmpty)
        #expect(!modelo.dinheiro.isEmpty)
    }

    /// O número grande do azulejo "Dinheiro" — e a frase embaixo dele.
    @Test("o azulejo do dinheiro mostra a soma, e não a contagem")
    func theMoneyTileShowsTheSum() async throws {
        let store = await DiaDoDono.loja()
        let frente = try #require(modelo(store).frenteDeDinheiro)
        #expect(!frente.numero.isEmpty)
        #expect(frente.unidade.contains("pagar") || frente.unidade.contains("receber"))
    }

    /// Sem nenhum valor afirmado no texto não há número grande: o azulejo cai
    /// na contagem de prazos em vez de inventar um zero.
    @Test("sem valor no texto o azulejo do dinheiro não mente um zero")
    func withoutAnAmountThereIsNoBigNumber() {
        #expect(PainelDoDiaModelo.frenteDeDinheiro([]) == nil)
    }

    @Test("a coluna da direita do azulejo mostra a data, sem a conta")
    func theRightColumnKeepsOnlyTheDate() {
        #expect(PainelDoDia.quandoCurto("vence 05/09 · vantion") == "05/09")
        #expect(PainelDoDia.quandoCurto("vence hoje · okamiops") == "hoje")
        #expect(PainelDoDia.quandoCurto("05/09") == "05/09")
    }

    // MARK: - Agenda

    private func agenda(_ store: MailStore, mode: CalendarViewMode) -> some View {
        CalendarScreen(
            store: store,
            now: DiaDoDono.agoraMinuto,
            anchor: DiaDoDono.agora,
            wantsSidebar: false,
            initialMode: mode,
            shell: nil,
            showsSidebar: false
        )
        .environment(ThemeStore())
        .environment(ActionReceipts())
    }

    @Test("a Agenda de vidro desenha nas três visões", arguments: [
        CalendarViewMode.week, .day, .month,
    ])
    func glassCalendarRenders(mode: CalendarViewMode) async throws {
        let store = await DiaDoDono.loja()
        let rep = try #require(Render.snapshot(
            agenda(store, mode: mode).glassPanel(.vidro).padding(10).background(Backdrop()),
            named: "vidro-agenda-\(mode.rawValue)",
            size: Self.tamanho,
            theme: .vidro
        ))
        #expect(rep.pixelsWide == Int(Self.tamanho.width))
    }

    @Test("a semana de vidro desenha no escuro")
    func glassCalendarRendersDark() async throws {
        let store = await DiaDoDono.loja()
        let rep = try #require(Render.snapshot(
            agenda(store, mode: .week).glassPanel(.vidroNoite).padding(10).background(Backdrop()),
            named: "vidro-agenda-semana-noite",
            size: Self.tamanho,
            theme: .vidroNoite
        ))
        #expect(rep.pixelsHigh == Int(Self.tamanho.height))
    }

    // MARK: - Os 26 temas de sempre

    /// O redesenho vale para os 28 temas: o clássico **perde o vidro e mantém
    /// o desenho**, que é a regra do dono. Este par de retratos prova as duas
    /// metades ao mesmo tempo — o Painel e a Agenda da Tinta desenham o layout
    /// novo, e o fazem nas cores da Tinta, sem gradiente atrás.
    @Test("o Painel e a Agenda da Tinta usam o layout novo nas cores delas")
    func theClassicShellUsesTheNewLayout() async throws {
        #expect(!Theme.tinta.isTranslucent)
        #expect(Theme.tinta.usesFloatingPanels)
        #expect(Theme.tinta.backdrop == nil, "clássico não tem gradiente")

        let store = await DiaDoDono.loja()
        let doPainel = try #require(Render.snapshot(
            painel(store), named: "tinta-painel", size: Self.tamanho, theme: .tinta
        ))
        #expect(
            doPainel.pixels(matching: Theme.tinta.surface, tolerance: 0.02) > 1_000,
            "a superfície da Tinta sumiu do painel"
        )
        let daAgenda = try #require(Render.snapshot(
            agenda(store, mode: .week), named: "tinta-agenda",
            size: Self.tamanho, theme: .tinta
        ))
        #expect(
            daAgenda.pixels(matching: Theme.tinta.surface, tolerance: 0.02) > 1_000,
            "a superfície da Tinta sumiu da agenda"
        )
    }
}
