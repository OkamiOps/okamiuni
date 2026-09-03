import SwiftUI
import UNICore
import UNIDesign

/// As medidas e os rótulos do dashboard, copiados da tabela de medidas do
/// mockup aprovado (`design/08-dashboard-ia.dc.html`). O design **é** a
/// especificação: cada constante aqui tem o seletor (ou a linha da tabela) de
/// onde saiu escrito ao lado, e `Dashboard08ParityTests` lê o HTML e compara
/// os dois lados.
///
/// **Fora da `View` de propósito.** Uma `View` do SwiftUI é `@MainActor`
/// implícito, e um `static` dentro dela estoura em tempo de execução quando um
/// teste `nonisolated` o chama — a lição registrada em
/// `docs/decisoes-de-engenharia.md`. Aqui a conta é pura e o teste chega nela
/// sem renderizar nada.
enum DashboardMetrics {

    // MARK: - Estrutura

    /// `padding: 28px 32px 24px` do contêiner de conteúdo.
    static let contentPadding = EdgeInsets(top: 28, leading: 32, bottom: 24, trailing: 32)
    /// Cabeçalho: `gap: 18px` entre a saudação, a data e a coluna direita.
    static let headerGap: CGFloat = 18
    /// `.head` — saudação `font-size: 22px; font-weight: 600; ls -0.01em`.
    static let greetingSize: CGFloat = 22
    /// "Atualizado agora · próximo em N min" e o provedor: `font-size: 11.5px`.
    static let statusSize: CGFloat = 11.5

    // MARK: - Herói

    /// Herói `margin-top: 22px`.
    static let heroTopSpacing: CGFloat = 22
    /// Herói `padding: 22px 26px`.
    static let heroPadding = EdgeInsets(top: 22, leading: 26, bottom: 22, trailing: 26)
    /// Herói `gap: 28px` entre a frase e os botões.
    static let heroGap: CGFloat = 28
    /// Frase do herói `font-size: 20px; font-weight: 500; line-height: 1.35`.
    static let heroSentenceSize: CGFloat = 20
    /// Botão primário do herói: `height: 34px; padding: 0 18px`.
    static let heroButtonHeight: CGFloat = 34
    static let heroButtonPadding: CGFloat = 18

    // MARK: - Colunas

    /// As colunas (e as hairlines) começam 22 abaixo do herói:
    /// `.preview { padding-top: 22px }`, hairlines `margin-top: 22px`.
    static let columnsTopSpacing: CGFloat = 22
    /// Lista `padding-right: 32px`.
    static let listTrailingPadding: CGFloat = 32
    /// `.preview` — `width: 360px; padding-left: 32px`.
    static let previewWidth: CGFloat = 360
    static let previewLeadingPadding: CGFloat = 32
    /// Dia — `width: 248px; padding-left: 32px`, hairline `margin-left: 32px`.
    static let dayWidth: CGFloat = 248
    static let dayLeadingPadding: CGFloat = 32
    static let dayDividerLeadingSpacing: CGFloat = 32

    // MARK: - Filtro (texto, não pílula)

    /// `.flt { font-size: 13px; gap: 22px }`, fila `padding: 22px 0 10px`.
    static let filterTextSize: CGFloat = 13
    static let filterGap: CGFloat = 22
    static let filterRowPadding = EdgeInsets(top: 22, leading: 0, bottom: 10, trailing: 0)
    /// Contagem `.flt em { font-size: 10.5px; margin-left: 6px }` em mono.
    static let filterCountSize: CGFloat = 10.5
    static let filterCountSpacing: CGFloat = 6
    /// Ativo: `border-bottom: 1.5px solid accent`.
    static let filterUnderlineThickness: CGFloat = 1.5
    /// Contas à direita: ponto `width: 7px`, nome `font-size: 11.5px`, `gap: 14px`.
    static let accountDotSide: CGFloat = 7
    static let accountNameSize: CGFloat = 11.5
    static let accountGap: CGFloat = 14
    static let accountDotSpacing: CGFloat = 6

    // MARK: - Seções e linhas

    /// `.sec { padding: 26px 0 6px }`; a primeira, `padding-top: 18px`.
    static let sectionTopPadding: CGFloat = 26
    static let firstSectionTopPadding: CGFloat = 18
    static let sectionBottomPadding: CGFloat = 6
    /// Contagem da seção `.sec .n { font-size: 10px }` mono.
    static let sectionCountSize: CGFloat = 10
    /// `.row { grid-template-columns: 18px 1fr; column-gap: 12px;
    /// padding: 14px 0 15px }`.
    static let rowLeadingWidth: CGFloat = 18
    static let rowColumnGap: CGFloat = 12
    static let rowTopPadding: CGFloat = 14
    static let rowBottomPadding: CGFloat = 15
    /// Ponto da conta `.row .dot { width: 8px; margin-top: 6px }`.
    static let rowDotSide: CGFloat = 8
    static let rowDotTopSpacing: CGFloat = 6
    /// `.row .from { font-size: 13px; font-weight: 600 }`.
    static let rowSenderSize: CGFloat = 13
    /// `.row .acct { font-size: 10px; letter-spacing: 0.08em }` mono caps.
    static let rowAccountSize: CGFloat = 10
    /// `.row .time { font-size: 11px }` mono.
    static let rowTimeSize: CGFloat = 11
    /// `.row .subj { margin-top: 3px; font-size: 15px; font-weight: 500 }`.
    static let rowSubjectSize: CGFloat = 15
    static let rowSubjectTopSpacing: CGFloat = 3
    /// A linha `↳`: `.row .ai { margin-top: 8px; font-size: 13px; gap: 10px }`.
    static let proposalTopSpacing: CGFloat = 8
    static let proposalTextSize: CGFloat = 13
    static let proposalGap: CGFloat = 10
    /// Ações da proposta `.row .ai .acts { font-size: 12.5px; gap: 14px }`.
    static let proposalActionSize: CGFloat = 12.5
    static let proposalActionGap: CGFloat = 14
    /// Selecionada: `margin: 0 -22px; padding: 0 22px` — o fundo sangra 22
    /// para cada lado.
    static let selectionBleed: CGFloat = 22

    // MARK: - Rodapé da lista

    /// "Tirei da lista hoje" — `padding-top: 14px; font-size: 12.5px; lh 1.5`.
    static let listFooterTopPadding: CGFloat = 14
    static let listFooterSize: CGFloat = 12.5

    // MARK: - Prévia

    /// Cabeçalho da prévia: remetente 13/600, conta mono 10, hora mono 11.
    static let previewSenderSize: CGFloat = 13
    static let previewAccountSize: CGFloat = 10
    static let previewTimeSize: CGFloat = 11
    /// Assunto `margin-top: 6px; font-size: 17px; font-weight: 500`.
    static let previewSubjectSize: CGFloat = 17
    static let previewSubjectTopSpacing: CGFloat = 6
    /// Cartão do rascunho: `margin-top: 22px; padding: 16px 18px`.
    static let draftCardTopSpacing: CGFloat = 22
    static let draftCardPadding = EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)
    /// Corpo do rascunho `margin-top: 12px; font-size: 14px; lh 1.65`.
    static let draftBodySize: CGFloat = 14
    static let draftBodyTopSpacing: CGFloat = 12
    /// Ações do cartão: `margin-top: 16px; gap: 18px`; Enviar `height: 30px`.
    static let draftActionsTopSpacing: CGFloat = 16
    static let draftActionsGap: CGFloat = 18
    static let sendButtonHeight: CGFloat = 30
    /// `.btn { padding: 0 14px; font-size: 12.5px; font-weight: 600 }`.
    static let buttonPadding: CGFloat = 14
    static let actionTextSize: CGFloat = 12.5
    /// "O que ele escreveu": bloco `margin-top: 22px`, resumo `margin-top: 8px;
    /// font-size: 13.5px; lh 1.6`, "Ler o email inteiro" `margin-top: 10px`.
    static let wroteTopSpacing: CGFloat = 22
    static let wroteSummarySize: CGFloat = 13.5
    static let wroteSummaryTopSpacing: CGFloat = 8
    static let readWholeTopSpacing: CGFloat = 10
    /// Rodapé da prévia: `padding-top: 14px; gap: 18px`.
    static let previewFooterTopPadding: CGFloat = 14
    static let previewFooterGap: CGFloat = 18

    // MARK: - Dia (248)

    /// "Seu dia" `font-size: 13px; font-weight: 600`; lista `margin-top: 14px`.
    static let dayTitleSize: CGFloat = 13
    static let dayListTopSpacing: CGFloat = 14
    /// Evento `.ev { grid-template-columns: 44px 1fr; column-gap: 12px;
    /// padding: 10px 0 }`.
    static let eventHourWidth: CGFloat = 44
    static let eventColumnGap: CGFloat = 12
    static let eventVerticalPadding: CGFloat = 10
    /// Hora `font-size: 11.5px; font-weight: 500` mono; título 13/500;
    /// sub 11.5.
    static let eventHourSize: CGFloat = 11.5
    static let eventTitleSize: CGFloat = 13
    static let eventSubSize: CGFloat = 11.5
    /// "Agora": `padding: 8px 0`, hairline em accent a 50%.
    static let nowVerticalPadding: CGFloat = 8
    static let nowLineOpacity: Double = 0.5
    /// Bloco sugerido `.ev.plan { margin: 6px -12px; padding: 12px;
    /// border: dashed }`; ações `font-size: 12px`.
    static let planBlockVerticalMargin: CGFloat = 6
    static let planBlockBleed: CGFloat = 12
    static let planBlockPadding: CGFloat = 12
    static let planActionSize: CGFloat = 12
    static let planActionsTopSpacing: CGFloat = 8
    static let planActionsGap: CGFloat = 14

    // MARK: - Botão "Perguntar · ⌘J"

    /// `position: absolute; right: 24px; bottom: 20px; height: 36px;
    /// border-radius: 18px; padding: 0 14px 0 12px; gap: 9px`.
    static let askButtonTrailing: CGFloat = 24
    static let askButtonBottom: CGFloat = 20
    static let askButtonHeight: CGFloat = 36
    static let askButtonRadius: CGFloat = 18
    static let askButtonLeadingPadding: CGFloat = 12
    static let askButtonTrailingPadding: CGFloat = 14
    static let askButtonGap: CGFloat = 9
    /// Ícone 15 em accent, "Perguntar" 12.5/600, "⌘J" mono 10.
    static let askIconSize: CGFloat = 15
    static let askLabelSize: CGFloat = 12.5
    static let askShortcutSize: CGFloat = 10
    /// A faixa que a coluna do dia **reserva** para o botão flutuante.
    ///
    /// O botão é `overlay(alignment: .bottomTrailing)` da tela inteira: ele
    /// não empurra nada, e por isso a coluna do dia precisa se afastar dele
    /// por conta própria. Sem esta reserva, "O que você prometeu" — o rodapé
    /// da coluna — ficava debaixo do botão, que é a única coisa nesta tela
    /// que se sobrepõe a conteúdo.
    ///
    /// A conta é a distância do botão até a aresta (`bottom` + altura), mais
    /// um respiro do tamanho do `gap` do próprio botão, menos o que o
    /// preenchimento da tela já afasta.
    static let askButtonReserve: CGFloat =
        askButtonBottom + askButtonHeight + askButtonGap - contentPadding.bottom
    /// `box-shadow: 0 10px 30px rgba(0,0,0,.55)` — a única sombra da tela.
    static let askShadowRadius: CGFloat = 15
    static let askShadowY: CGFloat = 10
    static let askShadowOpacity: Double = 0.55

    // MARK: - Compartilhado com o corpo legível

    /// `.caps { font-size: 9.5px }` — a mesma legenda de todo o app.
    static let capsSize: CGFloat = 9.5
    /// O corpo da prévia (13.5) — `CorpoLegivelView` e `CorpoRolavel` leem
    /// daqui, e "O que ele escreveu" usa o mesmo número.
    static let previewExcerptSize: CGFloat = 13.5
    /// A calha e o véu do corpo rolável — ver `CorpoRolavel`.
    static let previewBodyGutter: CGFloat = 14
    static let previewBodyFade: CGFloat = 44

    // MARK: - Relógio da tela

    /// O dashboard recalcula a cada mudança do store e num relógio de cinco
    /// minutos. O rótulo diz onde o relógio está.
    static let refreshCadenceMinutes = 5

    /// "Atualizado agora · próximo em N min" — ou "Atualizando…" enquanto a
    /// barra fina do chrome trabalha.
    static func updateLabel(nowMinute: Int, isBusy: Bool) -> String {
        if isBusy { return "Atualizando…" }
        let resto = refreshCadenceMinutes - (nowMinute % refreshCadenceMinutes)
        return "Atualizado agora · próximo em \(resto) min"
    }

    // MARK: - Rótulos

    /// O botão primário do herói: com rascunho pronto ele promete o envio;
    /// sem, só leva até a mensagem.
    static func heroButtonLabel(hasReadyDraft: Bool) -> String {
        hasReadyDraft ? "Enviar a resposta" : "Ver"
    }

    /// A confirmação de uma linha antes de enviar da lista: a pessoa não viu
    /// o rascunho inteiro ali, então o clique só arma a pergunta.
    static func sendConfirmationLabel(address: String) -> String {
        "Enviar para \(address)?"
    }

    /// A ação primária do `.later`. **Neutra, e por decisão**: o clique move
    /// para a caixa Depois e o app não tem adiamento com volta — nada devolve
    /// a mensagem para Hoje numa hora marcada. "Sexta 9h" era a tela
    /// prometendo o que ela não cumpre (I1 da revisão final). Quando o
    /// adiamento existir, o rótulo volta a dizer a hora que o comando carrega.
    static let laterActionLabel = "Depois"

    /// "Tirei da lista hoje: Carol da Zoho (campanha, não lead), Resend e
    /// mais 10 disparos." `nil` quando nada saiu — um rodapé sobre o vazio é
    /// pior do que nenhum rodapé.
    ///
    /// A primeira leva o porquê; as demais só o nome; o que não coube vira
    /// "e mais N disparos" (o excedente que nem chegou a ranquear entra em
    /// `extraCount`).
    static func removedFooterLabel(
        _ removed: [(name: String, why: String)], extraCount: Int = 0
    ) -> String? {
        guard !removed.isEmpty || extraCount > 0 else { return nil }
        let visiveis = removed.prefix(3)
        var partes: [String] = []
        for (indice, item) in visiveis.enumerated() {
            if indice == 0, !item.why.isEmpty {
                partes.append("\(item.name) (\(item.why))")
            } else {
                partes.append(item.name)
            }
        }
        let resto = extraCount + max(0, removed.count - visiveis.count)
        var frase = "Tirei da lista hoje: " + partes.joined(separator: ", ")
        if partes.isEmpty {
            frase = "Tirei da lista hoje: \(resto) \(resto == 1 ? "disparo" : "disparos")."
            return frase
        }
        if resto > 0 {
            frase += " e mais \(resto) \(resto == 1 ? "disparo" : "disparos")"
        }
        return frase + "."
    }

    /// "Responder Jack, Jayden e Maria" — o título do bloco sugerido.
    static func replyBlockTitle(names: [String]) -> String {
        guard !names.isEmpty else { return "Responder emails" }
        if names.count == 1 { return "Responder \(names[0])" }
        let corpo = names.dropLast().joined(separator: ", ")
        return "Responder \(corpo) e \(names.last ?? "")"
    }

    /// "20 min · as três já prontas" — o subtítulo do bloco sugerido.
    static func replyBlockSub(count: Int, minutes: Int) -> String {
        let prontas: String
        switch count {
        case 1: prontas = "a resposta já pronta"
        case 2: prontas = "as duas já prontas"
        case 3: prontas = "as três já prontas"
        case 4: prontas = "as quatro já prontas"
        default: prontas = "as \(count) já prontas"
        }
        return "\(minutes) min · \(prontas)"
    }

    /// Quantas linhas o corpo inteiro tem — o "· N linhas" de "Ler o email
    /// inteiro". Linha em branco não conta: ela é respiro, não leitura.
    static func bodyLineCount(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    /// "Ler o email inteiro · 4 linhas".
    static func readWholeLabel(lineCount: Int) -> String {
        "Ler o email inteiro · \(lineCount) \(lineCount == 1 ? "linha" : "linhas")"
    }

    /// A data do cabeçalho: "Quinta · 3 de setembro".
    ///
    /// Locale fixo em pt-BR, como `AgendaRail.headerDateString`: o app é em
    /// português, e ler `Locale.current` faria a mesma linha sair em inglês
    /// no bundle de teste (ver a nota em `Render.bitmap`).
    static func headerDateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "EEEE '·' d 'de' MMMM"
        return formatter.string(from: date).replacingOccurrences(of: "-feira", with: "")
    }

    /// A leitura da linha em voz alta — remetente, conta, motivo, assunto.
    static func rowAccessibilityLabel(
        sender: String, subject: String, reason: DashboardFocus.Reason,
        account: String = ""
    ) -> String {
        let partes = [sender, account, reason.label, subject].filter { !$0.isEmpty }
        return partes.joined(separator: ", ")
    }

    /// A marca da conta que a linha escreve, em versalete.
    ///
    /// A marca do host quando ela existe; o domínio do endereço quando não —
    /// o que não vale é a linha ficar muda ("eu não sei qual a caixa").
    static let accountMarkLimit = 10

    static func accountMark(host: String, address: String) -> String {
        let marca = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let bruta = marca.isEmpty
            ? String(address.split(separator: "@").last?.split(separator: ".").first ?? "")
            : marca
        return String(bruta.prefix(accountMarkLimit)).uppercased()
    }

    // MARK: - A frase da proposta, fatiada

    /// Um trecho da linha `↳`, com o peso que o mockup dá a ele.
    enum ProposalSegment: Hashable {
        /// 500, `ink` — "Resposta pronta."
        case strong(String)
        /// Normal, `ink2`.
        case plain(String)
        /// Itálico, `ink3` — a pergunta da sugestão, ou a nota da agenda.
        case note(String)
    }

    /// Fatia o texto da proposta como o mockup o pinta: "Resposta pronta."
    /// em negrito; a última frase terminada em "?" (quando não é rascunho)
    /// em itálico; e a nota de agenda em itálico depois de tudo.
    static func proposalSegments(
        text: String, isReadyDraft: Bool, usedAgenda: Bool = false
    ) -> [ProposalSegment] {
        var segments: [ProposalSegment] = []
        var resto = text
        let prefixo = "Resposta pronta."
        if isReadyDraft, resto.hasPrefix(prefixo) {
            segments.append(.strong(prefixo))
            resto = String(resto.dropFirst(prefixo.count)).trimmingCharacters(in: .whitespaces)
        }
        if !isReadyDraft, resto.hasSuffix("?"),
           let corte = ultimaFrase(de: resto) {
            let cabeca = String(resto[..<corte.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if !cabeca.isEmpty { segments.append(.plain(cabeca)) }
            segments.append(.note(String(resto[corte])))
        } else if !resto.isEmpty {
            segments.append(.plain(resto))
        }
        if isReadyDraft, usedAgenda {
            segments.append(.note("Olhei sua agenda antes de propor."))
        }
        return segments
    }

    /// O intervalo da última frase de um texto terminado em "?". `nil` quando
    /// o texto inteiro é a pergunta — aí ele sai como uma nota só.
    private static func ultimaFrase(de texto: String) -> Range<String.Index>? {
        // Procura o último ponto final ou exclamação antes da pergunta.
        var corte: String.Index?
        var indice = texto.startIndex
        let fim = texto.index(before: texto.endIndex)
        while indice < fim {
            if texto[indice] == "." || texto[indice] == "!" {
                corte = texto.index(after: indice)
            }
            indice = texto.index(after: indice)
        }
        guard let corte else { return texto.startIndex..<texto.endIndex }
        var inicio = corte
        while inicio < texto.endIndex, texto[inicio] == " " {
            inicio = texto.index(after: inicio)
        }
        return inicio..<texto.endIndex
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
