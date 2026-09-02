import Foundation
import Testing
import UNICore
import UNISync
@testable import UNIShell

/// As medidas do mockup `design/07-dashboard.html`, com o número dos dois
/// lados — o princípio 1 do README. Esta suíte é **nonisolated** de
/// propósito: se um dia alguém mover estas contas para dentro de uma `View`
/// (que é `@MainActor` implícito), o caso quebra na hora, e é essa a lição
/// registrada em `docs/decisoes-de-engenharia.md`.
@Suite("Dashboard · medidas do mockup")
struct DashboardMetricsTests {

    @Test("os números do mockup estão escritos uma vez só")
    func mockupNumbers() {
        // `.content { padding: 22px }`
        #expect(DashboardMetrics.outerPadding == 22)
        // `.rail { width: 300px }`
        #expect(DashboardMetrics.railWidth == 300)
        // `.main { padding-right: 18px }`
        #expect(DashboardMetrics.mainTrailingPadding == 18)
        // `.head { margin-bottom: 16px }` e `.briefing { margin: 0 0 16px }`
        #expect(DashboardMetrics.headerBottomSpacing == 16)
        #expect(DashboardMetrics.briefingBottomSpacing == 16)
        // `.transcript { max-height: 300px }`
        #expect(DashboardMetrics.transcriptMaxHeight == 300)
        // `.chrome-btn { height: 28px; padding: 0 14px }`
        #expect(DashboardMetrics.headerButtonHeight == 28)
        // `.ask { height: 38px }` e `.ask .send { 28×28 }`
        #expect(DashboardMetrics.askHeight == 38)
        #expect(DashboardMetrics.sendButtonSide == 28)
        // `.prow { padding: 10px 16px 11px }` e `inset 3px` da barra da conta
        #expect(DashboardMetrics.rowPadding.top == 10)
        #expect(DashboardMetrics.rowPadding.leading == 16)
        #expect(DashboardMetrics.rowPadding.bottom == 11)
        #expect(DashboardMetrics.rowPadding.trailing == 16)
        #expect(DashboardMetrics.accountBarWidth == 3)
        // `.prio-label { padding-bottom: 7px }`
        #expect(DashboardMetrics.sectionLabelBottomPadding == 7)
        // `.row-btn { height: 24px; padding: 0 10px }`
        #expect(DashboardMetrics.rowActionHeight == 24)
    }

    @Test("o rodapé só existe quando sobrou mensagem na Caixa")
    func footerLabel() {
        #expect(DashboardMetrics.omittedFooterLabel(4) == "+ 4 na Caixa →")
        #expect(DashboardMetrics.omittedFooterLabel(1) == "+ 1 na Caixa →")
        #expect(DashboardMetrics.omittedFooterLabel(0) == nil)
        #expect(DashboardMetrics.omittedFooterLabel(-3) == nil)
    }

    /// As seis razões, seis rótulos — e **quatro** aparências de chip, como o
    /// mockup escreve em `.chip[data-reason=…]`. O defeito que isto fecha é o
    /// `rankPill`, que colapsava as seis em "Alta"/"Média".
    @Test("cada razão tem rótulo próprio e a aparência do mockup")
    func reasonChips() {
        let reasons: [DashboardFocus.Reason] = [
            .needsReply, .lead, .deadline, .flagged, .unread, .today,
        ]
        let labels = reasons.map(\.label)
        #expect(Set(labels).count == 6)
        #expect(labels == ["Precisa resposta", "Lead", "Prazo", "Sinalizado", "Não lido", "Hoje"])

        #expect(DashboardMetrics.chipRole(for: .needsReply) == .warning)
        #expect(DashboardMetrics.chipRole(for: .deadline) == .warning)
        #expect(DashboardMetrics.chipRole(for: .lead) == .lead)
        #expect(DashboardMetrics.chipRole(for: .flagged) == .flagged)
        #expect(DashboardMetrics.chipRole(for: .unread) == .quiet)
        #expect(DashboardMetrics.chipRole(for: .today) == .quiet)
    }

    /// `[data-state="briefing"] .prow:nth-of-type(n+6)` e `n+5` no transcript.
    @Test("a lista corta em linha inteira, nunca no meio de uma")
    func visibleRowCount() {
        #expect(DashboardMetrics.visibleRowCount(total: 7, hasBriefing: false, hasTranscript: false) == 7)
        #expect(DashboardMetrics.visibleRowCount(total: 7, hasBriefing: true, hasTranscript: false) == 5)
        #expect(DashboardMetrics.visibleRowCount(total: 7, hasBriefing: false, hasTranscript: true) == 4)
        // Transcript manda mesmo com briefing: é ele que come a coluna.
        #expect(DashboardMetrics.visibleRowCount(total: 7, hasBriefing: true, hasTranscript: true) == 4)
        // Nunca inventa linha que não existe.
        #expect(DashboardMetrics.visibleRowCount(total: 2, hasBriefing: false, hasTranscript: false) == 2)
        #expect(DashboardMetrics.visibleRowCount(total: 0, hasBriefing: true, hasTranscript: true) == 0)
    }

    @Test("a data do cabeçalho é a do mockup, em pt-BR")
    func headerDate() {
        var componentes = DateComponents()
        componentes.year = 2026
        componentes.month = 9
        componentes.day = 1
        var calendario = Calendar(identifier: .gregorian)
        calendario.locale = Locale(identifier: "pt_BR")
        let data = calendario.date(from: componentes)!
        #expect(DashboardMetrics.headerDateLabel(data) == "terça · 1 de setembro")
    }

    @Test("o rótulo do CTA segue a seleção, e não o topo da lista")
    func ctaLabel() {
        #expect(DashboardCTA.draftsReply(canDraftReply: true, hasSelectedMail: true))
        #expect(!DashboardCTA.draftsReply(canDraftReply: true, hasSelectedMail: false))
        #expect(!DashboardCTA.draftsReply(canDraftReply: false, hasSelectedMail: true))
        #expect(DashboardCTA.title(draftsReply: true) == "Gerar rascunho")
        #expect(DashboardCTA.title(draftsReply: false) == "Gerar briefing")
    }

    /// A leitura da linha em voz alta: remetente, razão, assunto. Existe fora
    /// da `View` para o teste chegar nela sem renderizar.
    @Test("a linha se anuncia com a razão de verdade")
    func rowAccessibilityText() {
        for reason in [DashboardFocus.Reason.needsReply, .lead, .deadline, .flagged, .unread, .today] {
            let text = DashboardMetrics.rowAccessibilityLabel(
                sender: "Marina Duarte", subject: "Revisão do contrato", reason: reason
            )
            #expect(text == "Marina Duarte, \(reason.label), Revisão do contrato")
        }
    }

    /// O rótulo do destino que o dashboard escreve debaixo do campo. Sem
    /// provedor ele diz que **não há** provedor; com um, o nome da rota.
    @Test("o destino sem provedor não se anuncia como configurado")
    @MainActor
    func unconfiguredDestinationSaysSo() {
        #expect(AssistantDestination.unconfigured.label == "Sem provedor")
        #expect(AssistantDestination.unconfigured.detail == "Escolha o provedor nos Ajustes.")
        #expect(!AssistantDestination.unconfigured.isLocal)
        // Com provedor de verdade, o rótulo é o da rota — o caminho que
        // `InboxScreen.assistantDestination` usa quando há Ajustes.
        let grok = AssistantDestination(
            label: "Codex · ChatGPT",
            detail: "Sai deste Mac pelo Codex instalado.",
            isLocal: false
        )
        #expect(grok.label == "Codex · ChatGPT")
    }
}
