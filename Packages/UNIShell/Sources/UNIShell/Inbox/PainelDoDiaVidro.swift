import SwiftUI
import UNICore
import UNIDesign

/// As peças do **Painel do dia** no shell Vidro — `design/Painel-Vidro.dc.html`.
///
/// O painel de vidro é **um** painel: um cabeçalho, um cartão elevado ("Comece
/// por aqui"), a linha do tempo, uma hairline e três azulejos translúcidos.
/// Não há mais os chips de negócio no topo (eles moram na coluna de contexto),
/// nem o "Perguntar ⌘J" (o trilho e o atalho já cobrem o assistente), nem a
/// barra de estado do pé.
///
/// Estas `View`s não leem `MailStore` nem relógio: a `PainelDoDia` monta os
/// modelos abaixo com o que o `PainelDoDiaModelo` já decidiu, e passa as ações
/// que já existiam. É a mesma divisão de sempre — regra fora da `View`.

// MARK: - Cabeçalho

/// A data em cima, a saudação grande embaixo, e o progresso do dia à direita.
struct PainelVidroCabecalho: View {

    @Environment(\.theme) private var theme

    let data: String
    let saudacao: String
    let progresso: Double
    let progressoEscrito: String
    /// Presente só com a coluna de contexto recolhida: o `sidebar.left` que a
    /// traz de volta, antes da data e da saudação.
    var onExpandSidebar: (() -> Void)?

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            if let onExpandSidebar {
                SidebarToggleButton(collapse: false, action: onExpandSidebar)
                    // Alinhado à saudação, não ao rodapé do bloco de duas
                    // linhas: no `.bottom` ele descia para a base do 30pt.
                    .padding(.bottom, 6)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(data)
                    .font(theme.sans.font(size: 13, weight: .medium))
                    .foregroundStyle(theme.ink3.color)
                Text(saudacao)
                    .font(theme.sans.font(size: 30, weight: .bold))
                    .tracking(-0.75)
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Text(L10n.tr("\(progressoEscrito) feitas"))
                    .font(theme.sans.font(size: 13))
                    .foregroundStyle(theme.ink2.color)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                anel
            }
            .fixedSize()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("\(saudacao). \(progressoEscrito) feitas"))
    }

    /// O anel de 40pt do protótipo: a trilha em `line`, o arco em `accent`.
    private var anel: some View {
        ZStack {
            Circle()
                .strokeBorder(theme.line.color, lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progresso)))
                .stroke(
                    theme.accent.color,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .padding(2)
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }
}

// MARK: - "Comece por aqui"

/// O **único** cartão elevado do painel claro. No escuro é um cartão
/// levemente levantado — ver `Theme.glassCard`.
struct PainelVidroDestaque: View {

    @Environment(\.theme) private var theme

    let iniciais: String
    let tint: Color
    let rotulo: String
    let titulo: String
    let porque: String
    /// "8h" — em mono, o número que sobra até o prazo. Vazio esconde a coluna.
    let numero: String
    let legenda: String
    /// `nil` quando não há o que fazer: o cartão é só leitura.
    let acao: String?
    let executar: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            Text(iniciais)
                .font(theme.sans.font(size: 19, weight: .semibold))
                .foregroundStyle(theme.onAccent.color)
                .frame(width: 52, height: 52)
                .background(Circle().fill(tint))

            VStack(alignment: .leading, spacing: 3) {
                Text(rotulo)
                    .font(theme.sans.font(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accentInk.color)
                Text(titulo)
                    .font(theme.sans.font(size: 18, weight: .semibold))
                    .tracking(-0.18)
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                if !porque.isEmpty {
                    Text(porque)
                        .font(theme.sans.font(size: 14))
                        .foregroundStyle(theme.ink3.color)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !numero.isEmpty {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(numero)
                        .font(theme.mono.font(size: 28, weight: .semibold))
                        .foregroundStyle(theme.ink.color)
                    Text(legenda)
                        .font(theme.sans.font(size: 12))
                        .foregroundStyle(theme.ink3.color)
                }
                .padding(.horizontal, 6)
                .fixedSize()
            }

            if let acao {
                Button(action: executar) {
                    Text(acao)
                        .font(theme.sans.font(size: 14, weight: .semibold))
                        .foregroundStyle(theme.onAccent.color)
                        .padding(.horizontal, 20)
                        .frame(height: 42)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(theme.accent.color)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: 11)
                .fixedSize()
                .accessibilityIdentifier("painel-vidro-comece-por-aqui")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.glassCard.color)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.glassCardEdge.color, lineWidth: 1)
        }
        .shadow(
            color: theme.isDark
                ? .black.opacity(0.35)
                : Color(.sRGB, red: 60 / 255, green: 50 / 255, blue: 160 / 255, opacity: 0.12),
            radius: 16, x: 0, y: 12
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(rotulo): \(titulo)")
    }
}

// MARK: - As três frentes

/// Uma frente de "Depois disso": o resto do dia, resumido num azulejo.
///
/// É modelo, e não `View`: quem decide o número grande, as três linhas e o
/// rótulo do botão é a `PainelDoDia`, com o que o `PainelDoDiaModelo` apurou.
struct PainelVidroFrente: Identifiable {

    struct Linha: Identifiable {
        let id: String
        /// O nome em negrito.
        let quem: String
        /// "· o quê" — vazio quando a linha não tem o que acrescentar.
        let oQue: String
        /// "hoje", "1d", "05/09" — em mono, à direita.
        let quando: String
        let urgente: Bool
    }

    struct Avatar: Identifiable {
        let id: String
        let iniciais: String
        let tint: Color
    }

    let id: String
    let titulo: String
    /// O símbolo SF ao lado do título.
    let icone: String
    /// A cor do título e do ícone.
    let cor: Color
    /// O número grande, em mono.
    let numero: String
    let unidade: String
    let avatares: [Avatar]
    let linhas: [Linha]
    /// `nil` esconde o botão — um botão que não faz nada é pior que nenhum.
    let acao: String?
    let acaoPrimaria: Bool
    let executar: () -> Void
}

/// O azulejo translúcido de uma frente.
struct PainelVidroAzulejoDaFrente: View {

    @Environment(\.theme) private var theme

    let frente: PainelVidroFrente

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: frente.icone)
                        .font(.system(size: 13, weight: .semibold))
                    Text(frente.titulo)
                        .font(theme.sans.font(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(frente.cor)
                Spacer(minLength: 6)
                avatares
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(frente.numero)
                    .font(theme.mono.font(size: 34, weight: .semibold))
                    .tracking(-1)
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                Text(frente.unidade)
                    .font(theme.sans.font(size: 13))
                    .foregroundStyle(theme.ink3.color)
                    .lineLimit(2)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(frente.linhas) { linha in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        (
                            Text(linha.quem)
                                .font(theme.sans.font(size: 13, weight: .semibold))
                                .foregroundColor(theme.ink.color)
                                + Text(linha.oQue.isEmpty ? "" : " · \(linha.oQue)")
                                .font(theme.sans.font(size: 13))
                                .foregroundColor(theme.ink3.color)
                        )
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if !linha.quando.isEmpty {
                            Text(linha.quando)
                                .font(theme.mono.font(size: 12, weight: .medium))
                                .foregroundStyle(
                                    linha.urgente ? theme.nowLine.color : theme.ink3.color
                                )
                                .fixedSize()
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            if let acao = frente.acao {
                Button(action: frente.executar) {
                    Text(acao)
                        .font(theme.sans.font(size: 13, weight: .semibold))
                        .foregroundStyle(
                            frente.acaoPrimaria ? theme.onAccent.color : theme.ink.color
                        )
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(frente.acaoPrimaria ? theme.accent.color : theme.btn.color)
                        )
                        .overlay {
                            if !frente.acaoPrimaria {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(theme.btnLine.color, lineWidth: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: 10)
                .accessibilityIdentifier("painel-vidro-frente-\(frente.id)")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.glassTile.color)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.glassTileEdge.color, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(frente.titulo), \(frente.numero) \(frente.unidade)")
    }

    /// Até três avatares sobrepostos, com o anel da cor do que está atrás.
    private var avatares: some View {
        HStack(spacing: -6) {
            ForEach(frente.avatares.prefix(3)) { avatar in
                Text(avatar.iniciais)
                    .font(theme.sans.font(size: 10, weight: .semibold))
                    .foregroundStyle(theme.onAccent.color)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(avatar.tint))
                    .overlay(Circle().strokeBorder(theme.glassRing.color, lineWidth: 2))
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}
