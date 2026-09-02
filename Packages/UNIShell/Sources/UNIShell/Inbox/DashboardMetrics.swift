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
    /// `[data-state="agenda-vazia"] .rail { width: 168px }` — no dia livre a
    /// coluna encolhe e a largura vai para a lista e a prévia.
    static let freeRailWidth: CGFloat = 168
    /// `.preview { width: 380px }`.
    static let previewWidth: CGFloat = 380
    /// `[data-state="agenda-vazia"] .preview { width: 440px }`.
    static let widePreviewWidth: CGFloat = 440
    /// `.listcol { padding-right: 16px }`.
    static let mainTrailingPadding: CGFloat = 16
    /// `.preview { padding-left: 16px }` e `.rail { margin-left: 16px }`.
    static let previewLeadingPadding: CGFloat = 16
    static let railLeadingSpacing: CGFloat = 16
    /// `.head { margin-bottom: 12px }`.
    static let headerBottomSpacing: CGFloat = 12
    /// `.briefing { margin: 0 0 16px }`.
    static let briefingBottomSpacing: CGFloat = 16

    // MARK: - Faixa HOJE

    /// `.digest { padding: 9px 14px }`.
    static let todayPadding = EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14)
    /// `.digest { gap: 18px }`.
    static let todaySpacing: CGFloat = 18
    /// `.digest { margin: 0 0 14px }`.
    static let todayBottomSpacing: CGFloat = 14
    /// `.dg { font-size: 12.5px; font-weight: 550; gap: 7px }` e o ponto de 5ø.
    static let todayTextSize: CGFloat = 12.5
    static let todayDotSide: CGFloat = 5
    static let todayDotSpacing: CGFloat = 7

    // MARK: - Prévia

    /// `.pv-top { padding-bottom: 7px }` e a dica em mono 9.
    static let previewTopBottomPadding: CGFloat = 7
    static let previewHintSize: CGFloat = 9
    /// `.pv-body { padding-top: 12px }`.
    static let previewBodyTopPadding: CGFloat = 12
    /// `.pv-from .n { font-size: 13px; font-weight: 650 }` / `.t { 11px mono }`.
    static let previewSenderSize: CGFloat = 13
    static let previewTimeSize: CGFloat = 11
    /// `.pv-subj { margin-top: 6px; font-size: 18px; font-weight: 500 }`.
    static let previewSubjectSize: CGFloat = 18
    static let previewSubjectTopSpacing: CGFloat = 6
    /// `.pv-meta { margin-top: 6px; gap: 5px }`.
    static let previewChipsTopSpacing: CGFloat = 6
    static let previewChipsSpacing: CGFloat = 5
    /// `.pv-x { margin-top: 12px; font-size: 13.5px; line-height: 1.6 }`.
    static let previewExcerptSize: CGFloat = 13.5
    static let previewExcerptTopSpacing: CGFloat = 12
    /// `-webkit-line-clamp` do trecho: oito linhas normalmente, três quando o
    /// rascunho está colado embaixo. **Não são mais um corte**: viraram a
    /// medida das duas alturas abaixo, porque o mockup tem um lorem que
    /// sempre preenche as oito linhas e a caixa de verdade tem email de cinco
    /// linhas e email de duzentas. Cortar em oito devolvia uma frase com 400pt
    /// de vazio embaixo — a queixa do dono.
    static let previewExcerptLines = 8
    static let previewExcerptLinesWithDraft = 3
    /// A altura de uma linha do trecho, no `line-height: 1.6` do mockup.
    static let previewExcerptLineHeight = previewExcerptSize * 1.6
    /// O teto do corpo quando o rascunho está colado embaixo: as três linhas
    /// do `-webkit-line-clamp: 3`. O rascunho é o que a pessoa pediu, e ganha
    /// o resto da coluna.
    static let previewBodyCompactHeight =
        previewExcerptLineHeight * CGFloat(previewExcerptLinesWithDraft)
    /// `.pv-acts { margin-top: 14px; gap: 6px }` e `.act { height: 28px;
    /// padding: 0 12px; font-size: 12px }`.
    static let previewActionsTopSpacing: CGFloat = 14
    static let previewActionSpacing: CGFloat = 6
    static let previewActionHeight: CGFloat = 28
    static let previewActionPadding: CGFloat = 12
    static let previewActionSize: CGFloat = 12
    /// `.pv-ctx { margin-top: 18px; padding-top: 12px }` e `.caps {
    /// margin-bottom: 8px }`.
    static let contextTopSpacing: CGFloat = 18
    static let contextTopPadding: CGFloat = 12
    static let contextLabelBottomSpacing: CGFloat = 8
    /// `.cx { gap: 8px; padding: 3px 0 }`, ponto de 5ø, texto 11.5/1.45.
    static let contextItemSpacing: CGFloat = 8
    static let contextItemVerticalPadding: CGFloat = 3
    static let contextDotSide: CGFloat = 5
    static let contextTextSize: CGFloat = 11.5

    // MARK: - Rascunho colado no email

    /// `.draft { margin-top: 14px; border-left: 2px; padding: 10px 12px 12px }`.
    static let draftTopSpacing: CGFloat = 14
    static let draftBarWidth: CGFloat = 2
    static let draftPadding = EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12)
    /// `.draft .bar { margin-bottom: 8px }` e `.tx { font-size: 13.5px }`.
    static let draftLabelBottomSpacing: CGFloat = 8
    static let draftTextSize: CGFloat = 13.5
    /// `.draft .acts { margin-top: 11px; gap: 6px }` e `.act { height: 26px;
    /// font-size: 11.5px }`.
    static let draftActionsTopSpacing: CGFloat = 11
    static let draftActionHeight: CGFloat = 26
    static let draftActionSize: CGFloat = 11.5

    // MARK: - Dia livre

    /// `.rail-free { padding: 22px 16px }`, título serif 15, texto 12.
    static let freeRailPadding = EdgeInsets(top: 22, leading: 16, bottom: 22, trailing: 16)
    static let freeRailTitleSize: CGFloat = 15
    static let freeRailTextSize: CGFloat = 12

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
    /// `.transcript { max-height: 280px }`.
    static let transcriptMaxHeight: CGFloat = 280
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

    /// A data do cabeçalho: "Terça · 1 de setembro".
    ///
    /// Locale fixo em pt-BR, como `AgendaRail.headerDateString`: o app é em
    /// português, e ler `Locale.current` faria a mesma linha sair em inglês
    /// no bundle de teste (ver a nota em `Render.bitmap`).
    ///
    /// O "-feira" cai fora: o mockup escreve "Terça · 1 de setembro", e em
    /// versalete mono o sufixo empurra a data para mais de meia coluna sem
    /// dizer nada que o dia da semana já não diga.
    static func headerDateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "EEEE '·' d 'de' MMMM"
        return formatter.string(from: date).replacingOccurrences(of: "-feira", with: "")
    }

    /// Quantas linhas de prioridade cabem, dado o que mais está na coluna.
    ///
    /// O mockup não mede nada: ele **corta em linha inteira**
    /// (`[data-state="assistente"] .prow:nth-of-type(n+6) { display: none }`).
    /// Sete sem nada por cima, cinco com o transcript aberto — a folga que
    /// sobra vai para o `.flexpad`, e o assistente continua colado no rodapé.
    /// Cortar por altura medida daria meia linha, que é justamente o que esta
    /// regra impede. A faixa HOJE não tira linha nenhuma: ela é uma tarja de
    /// 12,5, não um parágrafo.
    static func visibleRowCount(total: Int, hasTranscript: Bool) -> Int {
        let teto = hasTranscript ? 5 : DashboardFocus.mailLimit
        return min(total, teto)
    }

    /// Onde o campo do assistente fica quando a lista é curta.
    ///
    /// **Divergência deliberada do mockup**, registrada em `barra-report.md`.
    /// O `.flexpad` do mockup manda a folga toda para o meio, e o campo cola
    /// no rodapé: com sete linhas isso é o desenho aprovado. Com três, numa
    /// janela de 916, a régua não previu o caso — a coluna fica oca, com o
    /// campo lá embaixo e um buraco no meio. Abaixo do corte, a folga vai
    /// para **baixo** do campo e ele sobe para logo depois da lista.
    ///
    /// O transcript aberto não conta como lista curta: ele já é a peça que
    /// preenche a coluna, e mover o campo com ele na tela faria o rodapé
    /// pular a cada resposta.
    static func assistantHugsList(rowCount: Int, hasTranscript: Bool) -> Bool {
        !hasTranscript && rowCount < assistantHugRowCount
    }

    /// A lista cheia do mockup são sete linhas (`DashboardFocus.mailLimit`).
    /// Qualquer coisa abaixo disso não preenche a coluna, e é aí que o
    /// `.flexpad` deixa de ser folga e vira buraco.
    static let assistantHugRowCount = DashboardFocus.mailLimit

    /// Quantas pendências a coluna mostra. O mockup desenha três, e três é o
    /// que cabe sem a seção comer a trilha. O resto vira "+ N" — meia
    /// pendência não é pendência.
    static let maximumPendingRows = 3

    /// "+ 2 pendências" quando a lista não coube. `nil` quando coube.
    static func omittedPendingLabel(total: Int) -> String? {
        let resto = total - maximumPendingRows
        guard resto > 0 else { return nil }
        return resto == 1 ? "+ 1 pendência" : "+ \(resto) pendências"
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

/// As duas larguras que mudam com o estado da coluna direita — regra, não
/// desenho, e por isso fora da `View`.
enum DashboardLayout {

    /// O dia livre do mockup: nada na agenda de hoje **e** nada pendente.
    /// Só compromisso não basta — a coluna ainda teria as PENDÊNCIAS dentro.
    static func isFreeDay(_ focus: DashboardFocus) -> Bool {
        focus.meetings.isEmpty && focus.pending.isEmpty
    }

    /// `.preview { width: 380px }` e `[data-state="agenda-vazia"] .preview
    /// { width: 440px }`.
    static func previewWidth(freeDay: Bool) -> CGFloat {
        freeDay ? DashboardMetrics.widePreviewWidth : DashboardMetrics.previewWidth
    }

    /// `.rail { width: 300px }` e `[data-state="agenda-vazia"] .rail
    /// { width: 168px }`.
    static func railWidth(freeDay: Bool) -> CGFloat {
        freeDay ? DashboardMetrics.freeRailWidth : DashboardMetrics.railWidth
    }
}

/// O que a tecla sem modificador faz no dashboard.
///
/// Pura e fora da `View` pelo motivo de sempre — e também porque a metade que
/// **não** dá para provar sem app é o monitor local (`BareKeyMonitor`): num
/// processo de teste, pôr um evento na fila do `NSApp` termina o laço de
/// drenagem da `main` e o processo sai no meio do caso, como o cabeçalho do
/// `CliqueDeEnsaio` registra. A decisão, que é o que muda quando alguém mexe
/// aqui, se prova sem sintetizar tecla nenhuma.
enum DashboardKeys {

    /// Qual mensagem o ⏎ abre. `nil` quando ele não tem o que fazer — e aí a
    /// tecla segue o caminho dela em vez de ser engolida.
    static func opens(
        key: BareKey, selectedID: String?, readingID: String?, exists: Bool
    ) -> String? {
        guard key == .enter, readingID == nil, exists, let selectedID else { return nil }
        return selectedID
    }
}
