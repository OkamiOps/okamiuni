import SwiftUI
import UNICore
import UNIDesign

/// As medidas e os rótulos do dashboard, copiados da tabela de medidas do
/// mockup aprovado (`design/07-dashboard.html`). O design **é** a
/// especificação: cada constante aqui tem o seletor CSS de onde saiu escrito
/// ao lado, e `DashboardMetricsTests` compara os dois lados.
///
/// **Fora da `View` de propósito.** Uma `View` do SwiftUI é `@MainActor`
/// implícito, e um `static` dentro dela estoura em tempo de execução quando um
/// teste `nonisolated` o chama — a lição registrada em
/// `docs/decisoes-de-engenharia.md`. Aqui a conta é pura e o teste chega nela
/// sem renderizar nada.
enum DashboardMetrics {

    // MARK: - Estrutura

    /// `.content { padding: 22px }` — o mesmo recuo externo das outras telas.
    static let outerPadding: CGFloat = 22
    /// `.rail { width: 300px }`.
    static let railWidth: CGFloat = 300
    /// `.main { padding-right: 18px }`.
    static let mainTrailingPadding: CGFloat = 18
    /// `.head { margin-bottom: 16px }`.
    static let headerBottomSpacing: CGFloat = 16
    /// `.briefing { margin: 0 0 16px }`.
    static let briefingBottomSpacing: CGFloat = 16

    // MARK: - Cabeçalho

    /// `.head .greet { font-size: 28px; font-weight: 600 }`.
    static let greetingSize: CGFloat = 28
    /// `.caps { font-size: 9.5px }`.
    static let capsSize: CGFloat = 9.5
    /// `.chrome-btn { height: 28px }`.
    static let headerButtonHeight: CGFloat = 28
    /// `.chrome-btn { padding: 0 14px }`.
    static let headerButtonPadding: CGFloat = 14
    /// `.provider { font-size: 11px }` e `gap: 5px` da coluna direita do
    /// cabeçalho.
    static let providerSize: CGFloat = 11
    static let providerSpacing: CGFloat = 5

    // MARK: - Faixa de briefing

    /// `.briefing { padding: 12px 16px }`.
    static let briefingPadding = EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
    /// `.briefing .text { font-size: 15px; line-height: 1.55 }`.
    static let briefingTextSize: CGFloat = 15
    /// `.mini-btn { height: 26px; padding: 0 12px }`.
    static let miniButtonHeight: CGFloat = 26
    /// `.x-btn { width: 24px; height: 24px }`.
    static let closeButtonSide: CGFloat = 24

    // MARK: - Prioridades

    /// `.prio-label { padding-bottom: 7px }`.
    static let sectionLabelBottomPadding: CGFloat = 7
    /// `.prow { padding: 10px 16px 11px }`.
    static let rowPadding = Insets(top: 10, leading: 16, bottom: 11, trailing: 16)
    /// `box-shadow: inset 3px 0 0 …` — a barra de tinta da conta, igual à da
    /// `MessageRow`.
    static let accountBarWidth: CGFloat = 3
    /// `inset 3px 0 0 color-mix(… var(--tint) 45% …)`.
    static let accountBarOpacity: Double = 0.45
    /// `.prow .from { font-size: 13px; font-weight: 650 }`.
    static let senderSize: CGFloat = 13
    /// `.prow .time { font-size: 11px }`.
    static let timeSize: CGFloat = 11
    /// `.prow .subj { margin-top: 3px }`.
    static let subjectTopSpacing: CGFloat = 3
    /// `.prow .chips { margin-top: 8px }`.
    static let chipsTopSpacing: CGFloat = 8
    /// `.row-btn { height: 24px; padding: 0 10px; font-size: 11.5px }`.
    static let rowActionHeight: CGFloat = 24
    static let rowActionPadding: CGFloat = 10
    static let rowActionSize: CGFloat = 11.5
    /// `.prow .acts { gap: 6px }`.
    static let rowActionSpacing: CGFloat = 6
    /// `.prio-foot { padding: 8px 16px; font-size: 12.5px }`.
    static let footerPadding = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
    static let footerSize: CGFloat = 12.5
    /// `.prio-empty { padding: 26px 16px }`.
    static let emptyPadding = EdgeInsets(top: 26, leading: 16, bottom: 26, trailing: 16)

    // MARK: - Assistente

    /// `.assist { padding-top: 12px }`.
    static let assistantTopPadding: CGFloat = 12
    /// `.transcript { max-height: 300px }` — ≈40% da coluna, como manda a §2.2.
    static let transcriptMaxHeight: CGFloat = 300
    /// `.transcript { padding: 12px 14px; margin-bottom: 10px }`.
    static let transcriptPadding = EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
    static let transcriptBottomSpacing: CGFloat = 10
    /// `.turn-q { padding: 7px 11px; font-size: 13px; max-width: 72% }`.
    static let questionPadding = EdgeInsets(top: 7, leading: 11, bottom: 7, trailing: 11)
    static let questionSize: CGFloat = 13
    static let questionMaxWidthFraction: CGFloat = 0.72
    /// `.turn-a { padding: 10px 12px; font-size: 14px; max-width: 88% }`.
    static let answerPadding = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    static let answerSize: CGFloat = 14
    static let answerMaxWidthFraction: CGFloat = 0.88
    /// `.ask { height: 38px; padding: 0 5px 0 14px }`.
    static let askHeight: CGFloat = 38
    static let askLeadingPadding: CGFloat = 14
    static let askTrailingPadding: CGFloat = 5
    /// `.ask .send { width: 28px; height: 28px }`.
    static let sendButtonSide: CGFloat = 28

    // MARK: - Pendências

    /// `.pend { padding: 13px 16px 15px }`.
    static let pendingPadding = EdgeInsets(top: 13, leading: 16, bottom: 15, trailing: 16)
    /// `.pend .caps { margin-bottom: 9px }`.
    static let pendingLabelBottomSpacing: CGFloat = 9
    /// `.pend-item { padding: 4px 0; gap: 8px }` e o ponto de 5ø.
    static let pendingItemVerticalPadding: CGFloat = 4
    static let pendingDotSide: CGFloat = 5
    /// `.pend-item .tx .a { font-size: 11.5px }` / `.b { font-size: 10.5px }`.
    static let pendingTextSize: CGFloat = 11.5
    static let pendingOriginSize: CGFloat = 10.5

    // MARK: - Rótulos

    /// `.prio-foot` — "+ 4 na Caixa →". `nil` quando nada ficou de fora: um
    /// rodapé escrito "+ 0" seria um ponteiro para lugar nenhum.
    static func omittedFooterLabel(_ omitted: Int) -> String? {
        omitted > 0 ? "+ \(omitted) na Caixa →" : nil
    }

    /// A leitura da linha em voz alta.
    static func rowAccessibilityLabel(
        sender: String, subject: String, reason: DashboardFocus.Reason
    ) -> String {
        "\(sender), \(reason.label), \(subject)"
    }

    // MARK: - Chips de motivo

    /// As quatro aparências que `.chip[data-reason=…]` desenha no mockup. As
    /// **seis** razões continuam com seis rótulos — o que se repete é a cor,
    /// não o texto.
    enum ChipRole: Hashable {
        /// `needsReply` e `deadline`: `--warn` sobre 14% dele, borda 32%.
        case warning
        /// `lead`: `accent-ink` sobre `accent-soft`, borda `accent-line`.
        case lead
        /// `flagged`: `accent-ink`, borda `accent-line`, fundo transparente.
        case flagged
        /// `unread` e `today`: `ink3` sobre `surface3`, borda `line`.
        case quiet
    }

    static func chipRole(for reason: DashboardFocus.Reason) -> ChipRole {
        switch reason {
        case .needsReply, .deadline: .warning
        case .lead: .lead
        case .flagged: .flagged
        case .unread, .today: .quiet
        }
    }
}

/// A decisão do CTA do cabeçalho, isolada da `View` pelo mesmo motivo que
/// `DashboardMetrics`: é regra, não desenho.
enum DashboardCTA {

    /// Rascunho **só** com email selecionado: é o mesmo predicado com que o
    /// motor resolve o contexto, e desalinhá-los deixava o botão aceso
    /// prometendo o que ia falhar.
    static func draftsReply(canDraftReply: Bool, hasSelectedMail: Bool) -> Bool {
        canDraftReply && hasSelectedMail
    }

    static func title(draftsReply: Bool) -> String {
        draftsReply ? "Gerar rascunho" : "Gerar briefing"
    }
}
