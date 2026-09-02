import Foundation
import Testing
import UNICore
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
}
