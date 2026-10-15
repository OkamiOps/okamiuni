import AppKit
import SwiftUI
import UNICore
import UNIDesign

/// As medidas do desenho `Leitor5.dc.html` — o cabeçalho do leitor depois da
/// reclamação do dono: **o cabeçalho ocupava metade da janela**.
///
/// O que mudou, e por quê:
///
/// - A linha de ações (Resumir · Rascunhar · Criar evento · Mais) saiu. Tudo o
///   que a IA faz com este e-mail mora no botão "✦ IA ⌥⌘J", num menu com
///   rubricas — o dono recusou botões de IA espalhados pela barra.
/// - O assunto é **uma linha**, com reticências e o título inteiro no `help`.
/// - O remetente é um botão com chevron; o que era a linha de procedência
///   ("conta · pasta") foi para a direita da mesma linha.
/// - A linha das imagens remotas deixou de ser uma faixa separada acima do
///   corpo: virou um ícone de confiança ao lado do remetente.
///
/// Fora da `View` pelo motivo de sempre: medida é dado, e dado se lê e se
/// afirma sem montar janela.
enum Leitor5Metrics {

    /// `padding: 12px 26px 0` do bloco do cabeçalho, e `gap: 10px`.
    static let headerTop: CGFloat = 12
    static let headerSide: CGFloat = 26
    static let headerGap: CGFloat = 10

    /// `font-size: 20px; line-height: 1.3; font-weight: 700`.
    static let subjectSize: CGFloat = 20

    /// A linha do remetente: avatar 32, `gap: 11px`.
    static let avatar: CGFloat = 32
    static let rowGap: CGFloat = 11
    static let nameSize: CGFloat = 14
    static let mailSize: CGFloat = 12
    static let chevron: CGFloat = 12
    /// `padding: 4px 7px 4px 8px` do botão do remetente.
    static let senderPadH: CGFloat = 8
    static let senderPadV: CGFloat = 4
    /// A hora e a procedência, na ponta direita.
    static let stampSize: CGFloat = 11.5
    static let originDot: CGFloat = 6

    /// Os detalhes: `margin-left: 43px`, `padding-top: 9px` sob um fio.
    static let detailsIndent: CGFloat = 43
    static let detailsTop: CGFloat = 9
    static let detailsRowGap: CGFloat = 2
    static let detailsRowPadH: CGFloat = 8
    static let detailsRowPadV: CGFloat = 4
    static let detailsLabel: CGFloat = 104
    static let detailsLabelSize: CGFloat = 11.5
    static let detailsValueSize: CGFloat = 12.5
    static let copyBox: CGFloat = 23
    static let copyIcon: CGFloat = 12
    /// Os dois botões do pé dos detalhes: `padding: 6px 11px; font-size: 12px`.
    static let detailsButtonSize: CGFloat = 12
    static let detailsButtonPadH: CGFloat = 11
    static let detailsButtonPadV: CGFloat = 6
    static let detailsButtonsTop: CGFloat = 8

    /// Quanto tempo o "✓ Copiado" fica na linha.
    static let copiedLifetime: Duration = .milliseconds(1_500)

    /// O menu da IA: `width: 292px; padding: 7px`.
    static let menuWidth: CGFloat = 292
    static let menuPadding: CGFloat = 7
    static let menuRowPadH: CGFloat = 10
    static let menuRowPadV: CGFloat = 7
    static let menuRowSize: CGFloat = 13
    static let menuIcon: CGFloat = 15
    static let menuRowGap: CGFloat = 10
    static let menuShortcutSize: CGFloat = 10.5
    static let menuGroupSize: CGFloat = 9.5
    static let menuGroupTracking: CGFloat = 0.11
    static let menuFootSize: CGFloat = 11.5
    static let menuDot: CGFloat = 6

    /// O cartão do resumo, **mais justo** que o anterior:
    /// `padding: 9px 13px 10px; gap: 8px; margin-top: 10px`.
    static let cardTop: CGFloat = 9
    static let cardSide: CGFloat = 13
    static let cardBottom: CGFloat = 10
    static let cardGap: CGFloat = 8
    static let cardMarginTop: CGFloat = 10
    /// A prosa: 14/1,45/500 — era 14,5/1,5.
    static let proseSize: CGFloat = 14
    static let proseLineHeight: CGFloat = 1.45
    /// Os botões do cartão aberto: `padding: 7px 13px; font-size: 12.5px`.
    static let cardButtonPadV: CGFloat = 7
    static let cardButtonPadH: CGFloat = 13
    /// O cartão recolhido: `padding: 6px 9px 6px 13px; gap: 9px`, texto 13/500,
    /// botões `5px 10px` em 11,5.
    static let collapsedPadV: CGFloat = 6
    static let collapsedPadLeading: CGFloat = 13
    static let collapsedPadTrailing: CGFloat = 9
    static let collapsedGap: CGFloat = 9
    static let collapsedTextSize: CGFloat = 13
    static let collapsedButtonSize: CGFloat = 11.5
    static let collapsedButtonPadV: CGFloat = 5
    static let collapsedButtonPadH: CGFloat = 10
    /// O chevron dos dois estados, numa caixinha de `btn2`.
    static let toggleIcon: CGFloat = 11
    static let toggleBox: CGFloat = 19
}

// MARK: - Os grupos do menu da IA

/// Os grupos do menu "✦ IA ⌥⌘J", com as rubricas do desenho.
///
/// Dado puro, e não uma lista montada dentro da `View`: o teste afirma que
/// **nenhuma ação ficou de fora do menu** sem montar janela nenhuma — era
/// exatamente isso que a linha de ações antiga escondia no "Mais".
struct ReaderAIGroup: Identifiable {
    let id: String
    /// "NESTE E-MAIL", "TRABALHAR O TEXTO", ou vazio no grupo solto do fim.
    let title: String
    let actions: [ReaderAIAction]

    static let all: [ReaderAIGroup] = [
        ReaderAIGroup(
            id: "neste",
            title: L10n.tr("NESTE E-MAIL"),
            actions: [.resumir, .rascunhar, .evento]
        ),
        ReaderAIGroup(
            id: "texto",
            title: L10n.tr("TRABALHAR O TEXTO"),
            actions: [.tarefas, .traduzir, .tom, .termos]
        ),
        ReaderAIGroup(id: "perguntar", title: "", actions: [.perguntar]),
    ]

    /// Toda ação aparece em exatamente um grupo. A régua do teste.
    static var listed: [ReaderAIAction] { all.flatMap(\.actions) }
}

/// **O menu da IA, ancorado na pastilha** — `Leitor5`, estado `ia-menu`.
///
/// Grupos com rubrica, atalho escrito à direita de cada linha, e o provedor no
/// pé com um "Trocar" que abre Configurações › Inteligência. Nenhuma linha é
/// muda: a que não pode agir agora desenha apagada, com o motivo no `help`.
struct ReaderAIGroupedMenu: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let provider: String
    let isEnabled: (ReaderAIAction) -> Bool
    let reason: (ReaderAIAction) -> String
    let run: (ReaderAIAction) -> Void
    /// "Trocar" — abre Configurações na seção Inteligência.
    let onSwitchProvider: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(ReaderAIGroup.all.enumerated()), id: \.element.id) { indice, grupo in
                if indice > 0 { fio }
                if !grupo.title.isEmpty {
                    Text(grupo.title)
                        .font(theme.mono.font(size: Leitor5Metrics.menuGroupSize, weight: .semibold))
                        .tracking(Leitor5Metrics.menuGroupSize * Leitor5Metrics.menuGroupTracking)
                        .foregroundStyle(theme.ink4.color)
                        .padding(.horizontal, Leitor5Metrics.menuRowPadH)
                        .padding(.top, 4)
                        .padding(.bottom, 5)
                }
                ForEach(grupo.actions) { acao in
                    row(acao)
                }
            }
            fio
            foot
        }
        .padding(Leitor5Metrics.menuPadding)
        .frame(width: Leitor5Metrics.menuWidth)
        .background(theme.glassElevated.color)
        .accessibilityIdentifier("reader-ai-menu")
        .accessibilityLabel(L10n.tr("IA neste e-mail"))
    }

    private var fio: some View {
        Rectangle()
            .fill(theme.line.color)
            .frame(height: Hairline.thickness(displayScale))
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
    }

    private func row(_ acao: ReaderAIAction) -> some View {
        let habilitada = isEnabled(acao)
        return Button { run(acao) } label: {
            HStack(spacing: Leitor5Metrics.menuRowGap) {
                Image(systemName: acao.symbol)
                    .font(.system(size: Leitor5Metrics.menuIcon - 2, weight: .medium))
                    .foregroundStyle((habilitada ? theme.ink3 : theme.ink4).color)
                    .frame(width: Leitor5Metrics.menuIcon)
                Text(acao.title)
                    .font(theme.sans.font(size: Leitor5Metrics.menuRowSize, weight: .medium))
                    .foregroundStyle((habilitada ? theme.ink : theme.ink4).color)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(acao.shortcutLabel)
                    .font(theme.mono.font(size: Leitor5Metrics.menuShortcutSize))
                    .foregroundStyle(theme.ink4.color)
            }
            .padding(.horizontal, Leitor5Metrics.menuRowPadH)
            .padding(.vertical, Leitor5Metrics.menuRowPadV)
            .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .disabled(!habilitada)
        .help(habilitada ? acao.title : reason(acao))
        .accessibilityLabel(acao.title)
    }

    private var foot: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(theme.success.color)
                .frame(width: Leitor5Metrics.menuDot, height: Leitor5Metrics.menuDot)
                .accessibilityHidden(true)
            Text(provider)
                .font(theme.sans.font(size: Leitor5Metrics.menuFootSize))
                .foregroundStyle(theme.ink3.color)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onSwitchProvider) {
                Text(L10n.tr("Trocar"))
                    .font(theme.sans.font(size: Leitor5Metrics.menuFootSize, weight: .semibold))
                    .foregroundStyle(theme.accentInk.color)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: 4)
            .help(L10n.tr("Abre Configurações › Inteligência para trocar de provedor"))
            .accessibilityLabel(L10n.tr("Trocar de provedor de IA"))
        }
        .padding(.horizontal, Leitor5Metrics.menuRowPadH)
        .padding(.vertical, 3)
    }
}

// MARK: - As opções das imagens e da paleta

/// O que era a linha "Imagens carregadas · Rever · Como o tema" acima do corpo,
/// agora atrás do ícone ao lado do remetente.
///
/// A faixa separada era mais uma linha de cabeçalho entre o assunto e o e-mail,
/// e o dono contou todas elas. As quatro decisões continuam alcançáveis:
/// carregar, confiar sempre, rever a confiança, e trocar a paleta.
struct ReaderImagesPopover: View {

    @Environment(\.theme) private var theme

    /// Esta mensagem pede recurso remoto? Sem isso só resta a paleta.
    let pedeRemotas: Bool
    let confiavel: Bool
    let carregou: Bool
    let remetente: String
    let paletaEhPapel: Bool
    let onCarregar: () -> Void
    let onConfiar: () -> Void
    let onRevogar: () -> Void
    let onTrocarPaleta: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if pedeRemotas {
                if confiavel {
                    nota(ReaderHTMLSection.imagensCarregadas)
                    item(ReaderHTMLSection.rever, action: onRevogar)
                } else if carregou {
                    nota(ReaderHTMLSection.imagensCarregadas)
                    if let sempre = ReaderHTMLSection.sempreCarregar(de: remetente) {
                        item(sempre, action: onConfiar)
                    }
                } else {
                    nota(ReaderHTMLSection.imagensBloqueadas)
                    item(ReaderHTMLSection.carregar, action: onCarregar)
                    if let sempre = ReaderHTMLSection.sempreCarregar(de: remetente) {
                        item(sempre, action: onConfiar)
                    }
                }
            } else {
                nota(L10n.tr("Esta mensagem não pede imagens remotas."))
            }
            item(
                paletaEhPapel ? ReaderHTMLSection.comoOTema : ReaderHTMLSection.comoEnviado,
                help: L10n.tr("Como enviado guarda as cores do remetente. Como o tema pinta com as cores do app."),
                action: onTrocarPaleta
            )
        }
        .padding(7)
        .frame(width: 268, alignment: .leading)
        .background(theme.glassElevated.color)
        .accessibilityIdentifier("reader-images-menu")
    }

    private func nota(_ texto: String) -> some View {
        Text(texto)
            .font(theme.sans.font(size: 11.5))
            .foregroundStyle(theme.ink4.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }

    private func item(
        _ rotulo: String, help: String? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(rotulo)
                .font(theme.sans.font(size: 12.5, weight: .medium))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .help(help ?? rotulo)
        .accessibilityLabel(rotulo)
    }
}

// MARK: - Os detalhes do remetente

/// Uma linha dos detalhes: rótulo, valor, e o ícone de copiar que só aparece
/// no hover.
struct ReaderDetailField: Identifiable {
    let id: String
    let label: String
    let value: String
    /// O que vai para o `NSPasteboard`. `nil` = linha sem copiar (Data, Pasta).
    var copyable: String?
    /// Escrito em `ink2` e não em `ink` — Cc, Data, Conta, Pasta.
    var dim = false
    /// O ponto da cor da conta, na linha "Conta".
    var accountTint: Color?
}

/// **Os detalhes do e-mail, no mesmo bloco do remetente** — `Leitor5`, estado
/// `remetente-expandido`.
///
/// Sem caixa dentro de caixa: um fio em cima e as linhas recuadas até a coluna
/// do nome. O ícone de copiar nasce no hover, copia para o `NSPasteboard` e a
/// linha responde "✓ Copiado" por um segundo e meio — a mesma gramática de
/// retorno visível do resto do app.
struct ReaderSenderDetails: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let fields: [ReaderDetailField]
    let onHeaders: () -> Void
    let onAllFromSender: () -> Void

    @State private var hovered: String?
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Leitor5Metrics.detailsRowGap) {
            ForEach(fields) { campo in
                row(campo)
            }
            HStack(spacing: 8) {
                botao(
                    L10n.tr("Ver cabeçalhos originais"), symbol: "doc.text",
                    help: L10n.tr("Mostra os cabeçalhos desta mensagem"),
                    action: onHeaders
                )
                botao(
                    L10n.tr("Todos deste remetente"), symbol: "magnifyingglass",
                    help: L10n.tr("Busca todas as mensagens deste remetente"),
                    action: onAllFromSender
                )
                Spacer(minLength: 0)
            }
            .padding(.top, Leitor5Metrics.detailsButtonsTop)
        }
        .padding(.top, Leitor5Metrics.detailsTop)
        .hairline(theme.line, edges: .top)
        .padding(.leading, Leitor5Metrics.detailsIndent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Detalhes do e-mail"))
        // "✓ Copiado" é um retorno, não um estado: ele vai embora sozinho.
        .task(id: copied) {
            guard copied != nil else { return }
            try? await Task.sleep(for: Leitor5Metrics.copiedLifetime)
            guard !Task.isCancelled else { return }
            copied = nil
        }
    }

    private func row(_ campo: ReaderDetailField) -> some View {
        let noHover = hovered == campo.id
        let foiCopiado = copied == campo.id
        return HStack(spacing: 10) {
            Text(campo.label)
                .font(theme.sans.font(size: Leitor5Metrics.detailsLabelSize, weight: .medium))
                .foregroundStyle(theme.ink4.color)
                .frame(width: Leitor5Metrics.detailsLabel, alignment: .leading)
            HStack(spacing: 7) {
                if let tint = campo.accountTint {
                    Circle().fill(tint).frame(width: 7, height: 7).accessibilityHidden(true)
                }
                Text(campo.value)
                    .font(theme.sans.font(size: Leitor5Metrics.detailsValueSize))
                    .foregroundStyle((campo.dim ? theme.ink2 : theme.ink).color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if foiCopiado {
                copiedChip
            } else if noHover, let texto = campo.copyable {
                copyButton(campo, texto: texto)
            }
        }
        .padding(.horizontal, Leitor5Metrics.detailsRowPadH)
        .padding(.vertical, Leitor5Metrics.detailsRowPadV)
        .frame(height: Leitor5Metrics.copyBox + Leitor5Metrics.detailsRowPadV * 2)
        .background(
            (noHover || foiCopiado ? theme.glassSoft : TokenColor(red: 0, green: 0, blue: 0, opacity: 0)).color
        )
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall * 0.75))
        .padding(.horizontal, -Leitor5Metrics.detailsRowPadH)
        .onHover { hovered = $0 ? campo.id : (hovered == campo.id ? nil : hovered) }
        .help(campo.value)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(campo.label): \(campo.value)")
    }

    private func copyButton(_ campo: ReaderDetailField, texto: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(texto, forType: .string)
            copied = campo.id
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: Leitor5Metrics.copyIcon, weight: .medium))
                .foregroundStyle(theme.ink2.color)
                .frame(width: Leitor5Metrics.copyBox, height: Leitor5Metrics.copyBox)
                .background(theme.surface3.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall * 0.75))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall * 0.75)
                        .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
                }
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall * 0.75)
        .help(L10n.tr("Copiar \(campo.label)"))
        .accessibilityLabel(L10n.tr("Copiar \(campo.label)"))
    }

    private var copiedChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
            Text(Self.copiado)
                .font(theme.sans.font(size: 11, weight: .semibold))
        }
        .foregroundStyle(theme.success.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(theme.success.color.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall * 0.75))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall * 0.75)
                .strokeBorder(
                    theme.success.color.opacity(0.30),
                    lineWidth: Hairline.thickness(displayScale)
                )
        }
        .fixedSize()
    }

    nonisolated static var copiado: String { L10n.tr("Copiado") }

    private func botao(
        _ titulo: String, symbol: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.ink3.color)
                Text(titulo)
                    .font(theme.sans.font(size: Leitor5Metrics.detailsButtonSize, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
            }
            .padding(.horizontal, Leitor5Metrics.detailsButtonPadH)
            .padding(.vertical, Leitor5Metrics.detailsButtonPadV)
            .background(theme.surface3.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall)
                    .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
            }
            .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .fixedSize()
        .help(help)
        .accessibilityLabel(titulo)
    }
}

// MARK: - Os cabeçalhos crus

/// **Os cabeçalhos desta mensagem**, numa folha simples.
///
/// O app não guarda o bloco cru do RFC 5322 — o decodificador lê o que precisa
/// e joga o resto fora (ver `UNISync`). Então a folha mostra os cabeçalhos que
/// o banco de fato tem, escritos no formato deles, e **diz isso**: inventar um
/// `Received:` que ninguém guardou seria pior do que não ter a folha.
struct ReaderHeadersSheet: View {

    @Environment(\.theme) private var theme

    let lines: [String]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("Cabeçalhos desta mensagem"))
                .font(theme.sans.font(size: 15, weight: .semibold))
                .foregroundStyle(theme.ink.color)
            Text(Self.aviso)
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(theme.ink4.color)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(theme.mono.font(size: 11.5))
                    .foregroundStyle(theme.ink2.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: 320, alignment: .leading)
            HStack(spacing: 8) {
                ChromeButton(
                    L10n.tr("Copiar"), appearance: .outlined,
                    size: 12, height: 28, horizontalPadding: 12
                ) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
                Spacer(minLength: 8)
                ChromeButton(
                    L10n.tr("Fechar"), appearance: .outlined,
                    size: 12, height: 28, horizontalPadding: 12
                ) {
                    onClose()
                }
            }
        }
        .padding(18)
        .frame(width: 560)
        .accessibilityIdentifier("reader-headers-sheet")
    }

    nonisolated static var aviso: String {
        L10n.tr("O app guarda estes campos; o bloco cru do servidor não é armazenado.")
    }

    /// Os cabeçalhos que o banco tem, no formato do RFC 5322.
    ///
    /// `nonisolated` e `static` pelo motivo de sempre: o que a pessoa lê é
    /// comportamento, e o teste o afirma sem montar janela.
    nonisolated static func lines(
        of message: Message, accountAddress: String, folder: String
    ) -> [String] {
        func contatos(_ lista: [Contact]) -> String {
            lista.map { $0.name.isEmpty ? $0.address : "\($0.name) <\($0.address)>" }
                .joined(separator: ", ")
        }
        var out: [String] = []
        out.append("From: \(contatos([message.from]))")
        if !message.to.isEmpty { out.append("To: \(contatos(message.to))") }
        if !message.cc.isEmpty { out.append("Cc: \(contatos(message.cc))") }
        out.append("Subject: \(message.subject)")
        out.append("Date: \(message.receivedAt.formatted(.iso8601))")
        if let rfc = message.rfcMessageID { out.append("Message-ID: \(rfc)") }
        if !message.references.isEmpty {
            out.append("References: \(message.references.joined(separator: " "))")
        }
        if let thread = message.threadKey { out.append("X-Okami-Thread: \(thread)") }
        if !accountAddress.isEmpty { out.append("X-Okami-Account: \(accountAddress)") }
        if !folder.isEmpty { out.append("X-Okami-Folder: \(folder)") }
        if let server = message.serverID { out.append("X-Okami-Server-ID: \(server)") }
        return out
    }
}

// MARK: - O resumo recolhido

/// O chevron que abre e recolhe o resumo — o mesmo botãozinho nos dois
/// estados, numa caixinha de `btn2` como no desenho.
///
/// Um botão, e não um link sublinhado: o dono recusou os desenhos
/// "minimalistas" em que uma palavra sublinhada fazia o trabalho de um
/// controle. O que é clicável aqui tem moldura.
struct ReaderSummaryToggle: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let aberto: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: aberto ? "chevron.up" : "chevron.down")
                .font(.system(size: Leitor5Metrics.toggleIcon, weight: .semibold))
                .foregroundStyle(theme.ink3.color)
                .frame(width: Leitor5Metrics.toggleBox, height: Leitor5Metrics.toggleBox)
                .background(theme.surface3.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall * 0.75))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall * 0.75)
                        .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
                }
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall * 0.75)
        .help(aberto ? Self.recolher : Self.abrir)
        .accessibilityLabel(aberto ? Self.recolher : Self.abrir)
    }

    nonisolated static var recolher: String { L10n.tr("Recolher o resumo") }
    nonisolated static var abrir: String { L10n.tr("Abrir o resumo") }
}

/// **O resumo recolhido numa linha** — `Leitor5`, estado `resumo-recolhido`.
///
/// O começo da frase, os mesmos dois botões em tamanho menor, e o chevron que
/// reabre. Era isto que faltava: o cartão aberto come mais de cem pontos de
/// altura, e quem já leu o resumo não quer pagá-los de novo a cada mensagem.
struct ReaderSummaryCollapsed: View {

    @Environment(\.theme) private var theme

    let prose: String
    let steps: [ReaderAIStep]
    let onExpand: () -> Void

    var body: some View {
        HStack(spacing: Leitor5Metrics.collapsedGap) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accentInk.color)
                .accessibilityHidden(true)
            Text(prose)
                .font(theme.sans.font(size: Leitor5Metrics.collapsedTextSize, weight: .medium))
                .foregroundStyle(theme.ink2.color)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            ForEach(steps) { passo in
                ReaderSmallStepButton(
                    title: passo.title, strong: passo.strong, action: passo.run
                )
            }
            ReaderSummaryToggle(aberto: false, action: onExpand)
        }
        .padding(.leading, Leitor5Metrics.collapsedPadLeading)
        .padding(.trailing, Leitor5Metrics.collapsedPadTrailing)
        .padding(.vertical, Leitor5Metrics.collapsedPadV)
        .readerAICard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Resumo escrito pela IA, recolhido"))
    }
}

/// O botão do resumo recolhido: o mesmo par do cartão aberto, um grau menor.
struct ReaderSmallStepButton: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let title: String
    let strong: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.sans.font(
                    size: Leitor5Metrics.collapsedButtonSize,
                    weight: strong ? .semibold : .medium
                ))
                .foregroundStyle((strong ? theme.onAccent : theme.ink2).color)
                .lineLimit(1)
                .padding(.horizontal, Leitor5Metrics.collapsedButtonPadH)
                .padding(.vertical, Leitor5Metrics.collapsedButtonPadV)
                .background((strong ? theme.accent : theme.surface3).color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .strokeBorder(
                            (strong ? theme.accent : theme.line2).color,
                            lineWidth: Hairline.thickness(displayScale)
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall, tint: strong ? \.onAccent : \.focus)
        .fixedSize()
        .help(title)
        .accessibilityLabel(title)
    }
}
