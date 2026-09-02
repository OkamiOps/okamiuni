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
        // `.listcol { padding-right: 16px }`, `.preview { padding-left: 16px }`
        // e `.rail { margin-left: 16px }`
        #expect(DashboardMetrics.mainTrailingPadding == 16)
        #expect(DashboardMetrics.previewLeadingPadding == 16)
        #expect(DashboardMetrics.railLeadingSpacing == 16)
        // `.preview { width: 380px }` e `[data-state="agenda-vazia"] { 440 }`
        #expect(DashboardMetrics.previewWidth == 380)
        #expect(DashboardMetrics.widePreviewWidth == 440)
        // `[data-state="agenda-vazia"] .rail { width: 168px }`
        #expect(DashboardMetrics.freeRailWidth == 168)
        // `.head { margin-bottom: 12px }` e `.digest { margin: 0 0 14px }`
        #expect(DashboardMetrics.headerBottomSpacing == 12)
        #expect(DashboardMetrics.todayBottomSpacing == 14)
        // `.digest { padding: 9px 14px; gap: 18px }` e o ponto de 5ø
        #expect(DashboardMetrics.todayPadding.top == 9)
        #expect(DashboardMetrics.todayPadding.leading == 14)
        #expect(DashboardMetrics.todaySpacing == 18)
        #expect(DashboardMetrics.todayTextSize == 12.5)
        #expect(DashboardMetrics.todayDotSide == 5)
        // `.pv-subj { font-size: 18px }`, `.pv-x { 13.5 }`, `.act { 28 alto }`
        #expect(DashboardMetrics.previewSubjectSize == 18)
        #expect(DashboardMetrics.previewExcerptSize == 13.5)
        #expect(DashboardMetrics.previewActionHeight == 28)
        #expect(DashboardMetrics.previewActionPadding == 12)
        // `.draft { border-left: 2px; padding: 10px 12px 12px }`, act 26 alto
        #expect(DashboardMetrics.draftBarWidth == 2)
        #expect(DashboardMetrics.draftPadding.top == 10)
        #expect(DashboardMetrics.draftPadding.bottom == 12)
        #expect(DashboardMetrics.draftActionHeight == 26)
        // `.transcript { max-height: 280px }`
        #expect(DashboardMetrics.transcriptMaxHeight == 280)
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

    /// `[data-state="assistente"] .prow:nth-of-type(n+6) { display: none }`.
    @Test("a lista corta em linha inteira, nunca no meio de uma")
    func visibleRowCount() {
        #expect(DashboardMetrics.visibleRowCount(total: 7, hasTranscript: false) == 7)
        #expect(DashboardMetrics.visibleRowCount(total: 7, hasTranscript: true) == 5)
        // Nunca inventa linha que não existe.
        #expect(DashboardMetrics.visibleRowCount(total: 2, hasTranscript: false) == 2)
        #expect(DashboardMetrics.visibleRowCount(total: 0, hasTranscript: true) == 0)
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
