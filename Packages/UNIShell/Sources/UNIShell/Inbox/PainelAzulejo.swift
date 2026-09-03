import SwiftUI
import UNIDesign

/// O azulejo do painel 11 — a peça que "Esperando você" e "Compromissos"
/// dividem.
///
/// Avatar de 28 na tinta da conta, nome, **um número grande em mono** com a
/// palavra ao lado em versalete, uma linha de porquê e um botão. Sem borda:
/// o azulejo é `surface` com raio r2, e é o fundo que o separa do papel.
///
/// A variante tracejada e sem botão é o azulejo que **não** é uma pessoa: o
/// resto que ficou de fora, ou o que esta entrega ainda não lê.
struct PainelAzulejo: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let iniciais: String
    let tint: Color
    let nome: String
    /// "7", "18", "hoje", "sex".
    let numero: String
    /// O sufixo pequeno colado no número: "d", "h" — vazio quando não há.
    let sufixo: String
    /// "esperando", "prazo hoje", "lead novo", "vence".
    let palavra: String
    /// Warn: atrasado, ou vence hoje.
    let alerta: Bool
    let porque: String
    let acaoPrimaria: String?
    /// O primeiro azulejo — e só ele — pinta a ação em accent.
    let destacada: Bool
    let acaoSecundaria: String?
    let onPrimary: () -> Void
    let onSecondary: () -> Void
    let onSelect: () -> Void
    let onOpen: () -> Void

    init(
        iniciais: String, tint: Color, nome: String, numero: String, sufixo: String = "",
        palavra: String, alerta: Bool = false, porque: String,
        acaoPrimaria: String? = nil, destacada: Bool = false,
        acaoSecundaria: String? = nil,
        onPrimary: @escaping () -> Void = {}, onSecondary: @escaping () -> Void = {},
        onSelect: @escaping () -> Void = {}, onOpen: @escaping () -> Void = {}
    ) {
        self.iniciais = iniciais
        self.tint = tint
        self.nome = nome
        self.numero = numero
        self.sufixo = sufixo
        self.palavra = palavra
        self.alerta = alerta
        self.porque = porque
        self.acaoPrimaria = acaoPrimaria
        self.destacada = destacada
        self.acaoSecundaria = acaoSecundaria
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
        self.onSelect = onSelect
        self.onOpen = onOpen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Text(iniciais)
                    .font(theme.mono.font(size: 10, weight: .semibold))
                    .foregroundStyle(theme.paper.color)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(tint))
                Text(nome)
                    .font(theme.sans.font(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(numero)
                        .font(theme.mono.font(size: 26, weight: .semibold))
                        .foregroundStyle(alerta ? theme.warning.color : theme.ink.color)
                    if !sufixo.isEmpty {
                        Text(sufixo)
                            .font(theme.mono.font(size: 12, weight: .medium))
                            .foregroundStyle(theme.ink3.color)
                    }
                }
                Text(palavra)
                    .capsLabel(size: 9.5)
                    .foregroundStyle(theme.ink3.color)
            }
            Text(porque)
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(theme.ink2.color)
                .lineLimit(1)
            if acaoPrimaria != nil || acaoSecundaria != nil {
                HStack(spacing: 6) {
                    if let acaoPrimaria {
                        PainelBotao(titulo: acaoPrimaria, primario: destacada, acao: onPrimary)
                    }
                    if let acaoSecundaria {
                        PainelBotao(titulo: acaoSecundaria, primario: false, acao: onSecondary)
                    }
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(nome), \(numero)\(sufixo) \(palavra). \(porque)")
    }
}

/// O azulejo que não é gente: tracejado, sem botão, com uma frase só.
struct PainelAzulejoVazado: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let frase: String

    var body: some View {
        Text(frase)
            .font(theme.sans.font(size: 12))
            .foregroundStyle(theme.ink4.color)
            .multilineTextAlignment(.center)
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 64)
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall)
                    .strokeBorder(
                        theme.line.color,
                        style: StrokeStyle(
                            lineWidth: Hairline.thickness(displayScale), dash: [3, 3]
                        )
                    )
            }
            .accessibilityLabel(frase)
    }
}

/// O botão do painel: 26 de altura, primário em accent, secundário com a
/// hairline do `btn` — os mesmos dois do mockup, e nada além deles.
struct PainelBotao: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let titulo: String
    let primario: Bool
    var altura: CGFloat = 26
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            Text(titulo)
                .font(theme.sans.font(size: 12, weight: .semibold))
                .foregroundStyle(primario ? theme.onAccent.color : theme.ink.color)
                .padding(.horizontal, 10)
                .frame(height: altura)
                .background(primario ? theme.accent.color : theme.btn.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .overlay {
                    if !primario {
                        RoundedRectangle(cornerRadius: theme.radiusSmall)
                            .strokeBorder(
                                theme.btnLine.color,
                                lineWidth: Hairline.thickness(displayScale)
                            )
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
    }
}
