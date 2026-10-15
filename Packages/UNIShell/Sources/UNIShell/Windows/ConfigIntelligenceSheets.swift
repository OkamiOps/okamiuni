import AppKit
import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// As folhas da Inteligência. Elas abrem sobre a **janela**, não sobre o
/// painel: o véu do desenho cobre a navegação também, e é por isso que o estado
/// mora em `AccountsWindow`.
public enum ConfigIntelligenceSheet: Hashable, Identifiable {
    case choose
    case login(AssistantProviderOAuthKind)

    public var id: String {
        switch self {
        case .choose: "choose"
        case .login(let kind): "login-\(kind.rawValue)"
        }
    }
}

// MARK: - Conectar uma IA

/// A folha "Conectar uma IA": busca no topo, categorias à esquerda, e todo
/// provedor que o app fala a **dois cliques** — um para abrir a folha, um para
/// escolher a linha.
///
/// `width: 840px; height: 566px; grid-template-columns: 236px minmax(0, 1fr)`.
struct ConfigIntelligenceChooseSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette
    @Environment(\.displayScale) private var displayScale

    /// A categoria aberta. O desenho nasce em "Chave de API"; a busca passa por
    /// cima dela, porque quem digita "grok" quer o Grok onde ele estiver.
    @State private var category: ConfigAICategory = .apiKey
    @State private var query = ""

    /// Pré-carrega a busca. Existe para o retrato poder desenhar a folha com a
    /// busca vazia e com "grok" digitado sem sintetizar teclado.
    var initialQuery = ""

    let close: () -> Void
    let choose: (ConfigAIPreset) -> Void

    var body: some View {
        HStack(spacing: 0) {
            rail
            list
        }
        .frame(width: 840, height: 566)
        .modalSurface(.sheet)
        .accessibilityLabel(L10n.tr("Conectar outra IA"))
        .onAppear { if query.isEmpty { query = initialQuery } }
    }

    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var items: [ConfigAIPreset] {
        searching ? ConfigAICatalog.search(query) : ConfigAICatalog.items(in: category, query: "")
    }

    // MARK: A esquerda

    /// `padding: 18px 12px 12px`, com a nota do Keychain presa no pé.
    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.tr("Conectar uma IA"))
                .font(theme.sans.font(size: 16, weight: .bold))
                .tracking(-0.01 * 16)
                .foregroundStyle(palette.ink.color)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            Text(L10n.tr("Tudo o que este app fala — do chip do seu Mac a um agente seu."))
                .font(theme.sans.font(size: 12.5))
                .lineSpacing(12.5 * 0.45)
                .foregroundStyle(palette.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.bottom, 14)

            ForEach(ConfigAICategory.allCases) { candidate in
                categoryButton(candidate)
            }

            Spacer(minLength: 0)

            Text(L10n.tr("Chaves e tokens vão para o Keychain deste Mac."))
                .font(theme.sans.font(size: 11.5))
                .lineSpacing(11.5 * 0.45)
                .foregroundStyle(palette.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(palette.line.color)
                        .frame(height: Hairline.thickness(displayScale))
                }
        }
        .padding(.horizontal, 12)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(width: 236, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(palette.tile.color)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(palette.line.color)
                .frame(width: Hairline.thickness(displayScale))
        }
    }

    private func categoryButton(_ candidate: ConfigAICategory) -> some View {
        let on = !searching && candidate == category
        return Button {
            query = ""
            category = candidate
        } label: {
            HStack(spacing: 10) {
                Image(systemName: candidate.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle((on ? palette.accentInk : palette.ink3).color)
                    .frame(width: 16)
                Text(candidate.label)
                    .font(theme.sans.font(size: 13.5, weight: on ? .semibold : .medium))
                    .foregroundStyle((on ? palette.ink : palette.ink2).color)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(ConfigAICatalog.count(candidate))")
                    .font(theme.mono.font(size: 11.5))
                    .foregroundStyle(palette.ink3.color)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(palette.navOn.color)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    // MARK: A direita

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBar
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    Text(searching ? L10n.tr("O QUE RESPONDE A “\(query)”") : category.listHeading)
                        .font(theme.sans.font(size: 11, weight: .semibold))
                        .tracking(0.06 * 11)
                        .foregroundStyle(palette.ink3.color)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.top, 2)
                        .padding(.bottom, 7)
                    if items.isEmpty {
                        Text(L10n.tr("Nada com esse nome. Tente o endereço, ou use “Outro endereço”."))
                            .font(theme.sans.font(size: 13))
                            .foregroundStyle(palette.ink3.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                    ForEach(items) { preset in
                        row(preset)
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .padding(.top, 12)
                .padding(.bottom, 14)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// `padding: 14px 18px`, com a lupa dentro do campo e o X ao lado.
    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.ink3.color)
                TextField(L10n.tr("Procurar por nome, modelo ou endereço"), text: $query)
                    .textFieldStyle(.plain)
                    .font(theme.sans.font(size: 13.5))
                    .foregroundStyle(palette.ink.color)
                    .accessibilityLabel(L10n.tr("Procurar uma IA"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(palette.field.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(palette.line.color, lineWidth: Hairline.thickness(displayScale))
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.ink3.color)
                    .padding(7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(L10n.tr("Fechar"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.line.color)
                .frame(height: Hairline.thickness(displayScale))
        }
    }

    /// `grid-template-columns: 28px minmax(0, 1fr) auto; padding: 8px 10px`.
    private func row(_ preset: ConfigAIPreset) -> some View {
        Button { choose(preset) } label: {
            HStack(spacing: 12) {
                ConfigAIMonogram(
                    letter: preset.monogram, hue: preset.hue,
                    side: 28, radius: 7, fontSize: 11.5
                )
                HStack(alignment: .firstTextBaseline, spacing: 11) {
                    Text(preset.name)
                        .font(theme.sans.font(size: 13.5, weight: .semibold))
                        .foregroundStyle(palette.ink.color)
                        .lineLimit(1)
                        .fixedSize()
                    Text(preset.address)
                        .font(theme.mono.font(size: 11.5))
                        .foregroundStyle(palette.ink3.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    Text(preset.note)
                        .font(theme.sans.font(size: 12))
                        .foregroundStyle(palette.ink3.color)
                        .lineLimit(1)
                        .fixedSize()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.ink3.color)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Entrar na conta do provedor

/// A folha de login por **device auth**: o código do aparelho e o endereço para
/// autorizar. Não há campo de chave de API aqui, e não há de propósito — é a
/// conexão oficial do provedor, a mesma que o app dele usa.
///
/// `width: 524px; padding: 26px 30px 22px; gap: 18px`.
struct ConfigIntelligenceLoginSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette
    @Environment(\.displayScale) private var displayScale
    @Environment(\.movimentoParado) private var movimentoParado

    let kind: AssistantProviderOAuthKind
    let status: AssistantProviderOAuthStatus
    let models: [AssistantProviderModel]
    let connect: () -> Void
    let recheck: () -> Void
    let signOut: () -> Void
    let close: () -> Void
    /// O agora, para a contagem do código. Injetável para o retrato não
    /// depender do relógio da máquina.
    var now: Date = Date()

    @State private var tick = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            steps
            if case .awaitingDeviceCode(let authorization) = status {
                codeBox(authorization)
                waitingRow(authorization)
            }
            if case .signedIn = status { signedInRow }
            if case .failed(let message) = status { failedRow(message) }
            actions
            footer
        }
        .padding(.horizontal, 30)
        .padding(.top, 26)
        .padding(.bottom, 22)
        .frame(width: 524)
        .modalSurface(.sheet)
        .accessibilityLabel(title)
        .task {
            // O código expira, e a frase diz quanto falta. Sem movimento (o
            // retrato) não há relógio: dois quadros de um cronômetro nunca são
            // iguais, e a espera "até assentar" do harness nunca assentaria.
            guard !movimentoParado, case .awaitingDeviceCode = status else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick = Date()
            }
        }
    }

    private var title: String {
        switch kind {
        case .xAI: L10n.tr("Entrar na sua conta xAI")
        case .codex: L10n.tr("Entrar na sua conta ChatGPT")
        }
    }

    private var monogram: (letter: String, hue: Double) {
        kind == .xAI ? ("G", 222) : ("C", 165)
    }

    private var host: String {
        switch kind {
        case .xAI: "grok.com/device"
        case .codex: "chatgpt.com/device"
        }
    }

    // MARK: O cabeçalho

    private var header: some View {
        HStack(spacing: 13) {
            ConfigAIMonogram(
                letter: monogram.letter, hue: monogram.hue,
                side: 40, radius: 10, fontSize: 16
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.sans.font(size: 17, weight: .bold))
                    .tracking(-0.015 * 17)
                    .foregroundStyle(palette.ink.color)
                Text(L10n.tr("Conexão oficial — a mesma que o app do provedor usa"))
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(palette.ink3.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.ink3.color)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(L10n.tr("Cancelar"))
        }
    }

    // MARK: Os passos

    private var steps: some View {
        VStack(alignment: .leading, spacing: 9) {
            step(1, L10n.tr("Abrimos o \(host) no seu navegador."))
            step(2, L10n.tr("Confira o código abaixo e autorize na sua conta."))
            step(3, L10n.tr("Os modelos da conta entram sozinhos aqui."))
        }
    }

    /// Qual passo está acontecendo: 1 antes de começar, 2 com o código na tela,
    /// 3 depois de a sessão existir.
    private var currentStep: Int {
        switch status {
        case .awaitingDeviceCode: 2
        case .signedIn: 3
        default: 1
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        let done = number < currentStep
        let now = number == currentStep
        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? palette.accentSoft.color : (now ? palette.accent.color : .clear))
                Circle()
                    .strokeBorder(
                        (now ? palette.accent : palette.line).color,
                        lineWidth: Hairline.thickness(displayScale)
                    )
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(palette.accentInk.color)
                } else {
                    Text("\(number)")
                        .font(theme.mono.font(size: 11, weight: .semibold))
                        .foregroundStyle((now ? palette.onAccent : palette.ink3).color)
                }
            }
            .frame(width: 22, height: 22)
            .padding(.top, 1)
            Text(text)
                .font(theme.sans.font(size: 13.5, weight: now ? .semibold : .regular))
                .lineSpacing(13.5 * 0.5)
                .foregroundStyle((now ? palette.ink : palette.ink3).color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: O código

    /// O código do aparelho, em dois blocos como o desenho mostra.
    ///
    /// Um código de device auth vem do provedor já com hífen às vezes
    /// (`ABCD-EFGH`) e às vezes corrido. Partir em dois é o que o torna legível
    /// em voz alta — e é só apresentação: o valor copiado é o original.
    private func codeBox(_ authorization: AssistantProviderOAuthDeviceAuthorization) -> some View {
        VStack(spacing: 10) {
            Text(L10n.tr("O CÓDIGO DESTA SESSÃO"))
                .font(theme.mono.font(size: 11, weight: .semibold))
                .tracking(0.1 * 11)
                .foregroundStyle(palette.accentInk.color)
            HStack(spacing: 10) {
                ForEach(Array(codeParts(authorization.userCode).enumerated()), id: \.offset) { _, part in
                    Text(part)
                        .font(theme.mono.font(size: 32, weight: .semibold))
                        .tracking(0.14 * 32)
                        .foregroundStyle(palette.ink.color)
                }
            }
            .textSelection(.enabled)
            .accessibilityLabel(L10n.tr("O código desta sessão é \(authorization.userCode)"))
            Text(L10n.tr("Confira que é exatamente esse o código mostrado em \(authorization.verificationURL.host() ?? host) antes de autorizar."))
                .font(theme.sans.font(size: 12.5))
                .lineSpacing(12.5 * 0.45)
                .foregroundStyle(palette.ink3.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(palette.accentSoft.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.accent.color.opacity(0.45), lineWidth: Hairline.thickness(displayScale))
        }
    }

    private func codeParts(_ code: String) -> [String] {
        if code.contains("-") {
            return code.split(separator: "-").map(String.init)
        }
        guard code.count >= 8 else { return [code] }
        let meio = code.index(code.startIndex, offsetBy: code.count / 2)
        return [String(code[code.startIndex..<meio]), String(code[meio...])]
    }

    /// A linha que diz que estamos esperando a autorização, com o tempo que o
    /// código ainda vale.
    private func waitingRow(
        _ authorization: AssistantProviderOAuthDeviceAuthorization
    ) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.accentInk.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.tr("Esperando você autorizar no navegador"))
                    .font(theme.sans.font(size: 13.5, weight: .semibold))
                    .foregroundStyle(palette.ink.color)
                Text(L10n.tr("o código vale por \(remaining(authorization.expiresAt))"))
                    .font(theme.sans.font(size: 12))
                    .foregroundStyle(palette.ink3.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.tr("Abrir de novo")) {
                NSWorkspace.shared.open(authorization.verificationURL)
            }
            .buttonStyle(.plain)
            .font(theme.sans.font(size: 12.5, weight: .medium))
            .foregroundStyle(palette.accentInk.color)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .configTile(palette, radius: 14)
    }

    /// `4:38`. O relógio parado do retrato usa o `now` injetado.
    private func remaining(_ expiresAt: Date) -> String {
        let base = movimentoParado ? now : max(tick, now)
        let seconds = max(0, Int(expiresAt.timeIntervalSince(base)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var signedInRow: some View {
        HStack(spacing: 11) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.green.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.tr("Conectada"))
                    .font(theme.sans.font(size: 13.5, weight: .semibold))
                    .foregroundStyle(palette.ink.color)
                Text(models.isEmpty
                    ? L10n.tr("os modelos da conta aparecem aqui em instantes")
                    : L10n.tr("\(models.count) modelos da sua conta já estão na lista"))
                    .font(theme.sans.font(size: 12))
                    .foregroundStyle(palette.ink3.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.tr("Desconectar"), action: signOut)
                .buttonStyle(.plain)
                .font(theme.sans.font(size: 12.5, weight: .medium))
                .foregroundStyle(palette.red.color)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .configTile(palette, radius: 14)
    }

    private func failedRow(_ message: String) -> some View {
        Text(message)
            .font(theme.sans.font(size: 12.5))
            .foregroundStyle(palette.red.color)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: As ações

    private var actions: some View {
        HStack(spacing: 10) {
            switch status {
            case .awaitingDeviceCode(let authorization):
                ModalPrimaryButton(title: L10n.tr("Já autorizei"), action: recheck)
                Button(L10n.tr("Copiar o código")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(authorization.userCode, forType: .string)
                }
                .buttonStyle(.plain)
                .configQuietButton(
                    palette, font: theme.sans.font(size: 13.5, weight: .medium),
                    radius: 10, horizontal: 15, vertical: 9
                )
            case .signedIn:
                ModalPrimaryButton(title: L10n.tr("Pronto"), action: close)
            default:
                ModalPrimaryButton(title: L10n.tr("Abrir o navegador e conectar"), action: connect)
            }
            Spacer(minLength: 0)
            Text(L10n.tr("sem chave de API"))
                .font(theme.sans.font(size: 12))
                .foregroundStyle(palette.ink3.color)
        }
    }

    private var footer: some View {
        Text(L10n.tr("Quando você autorizar, os modelos da sua conta entram sozinhos na lista e o token fica no Keychain deste Mac. Dá para desconectar a qualquer momento, aqui mesmo."))
            .font(theme.sans.font(size: 12))
            .lineSpacing(12 * 0.5)
            .foregroundStyle(palette.ink3.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(palette.line.color)
                    .frame(height: Hairline.thickness(displayScale))
            }
    }
}
