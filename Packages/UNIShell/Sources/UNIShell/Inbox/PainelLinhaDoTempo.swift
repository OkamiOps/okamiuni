import SwiftUI
import UNICore
import UNIDesign

/// A linha do tempo horizontal do "Plano de hoje": 09 h às 19 h, 118 de
/// altura, duas trilhas.
///
/// Em cima o que **já está marcado** (`agenda`), embaixo o que a IA propõe e o
/// que vence (`você`). A posição de cada bloco é a fração que o `PlanoDoDia`
/// calcula — a `View` não faz conta de horário, só desenha o que recebeu.
struct PainelLinhaDoTempo: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let blocos: [PlanoDoDia.Bloco]
    let nowMinute: Int
    /// Clique num bloco proposto — "Ajustar" abre o seletor de hora.
    let onTapProposto: (PlanoDoDia.Bloco) -> Void

    private let altura: CGFloat = 118
    private let alturaDoBloco: CGFloat = 28

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            rotulos
            GeometryReader { geo in
                let largura = geo.size.width
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(theme.line.color)
                        .frame(height: Hairline.thickness(displayScale))
                        .offset(y: 90)
                    horas(largura)
                    ForEach(blocos) { bloco in
                        desenha(bloco, largura: largura)
                    }
                    agora(largura)
                }
                .frame(width: largura, height: altura, alignment: .topLeading)
            }
            .frame(height: altura)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Linha do tempo de hoje")
    }

    /// Os nomes das trilhas, em versalete à esquerda do eixo.
    private var rotulos: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("agenda")
                .capsLabel(size: 9)
                .foregroundStyle(theme.ink3.color)
                .padding(.top, 17)
            Text("você")
                .capsLabel(size: 9)
                .foregroundStyle(theme.accentInk.color)
                .padding(.top, 21)
            Spacer(minLength: 0)
        }
        .frame(width: 46, height: altura, alignment: .topLeading)
    }

    private func horas(_ largura: CGFloat) -> some View {
        ForEach(Array(stride(from: PlanoDoDia.inicio, through: PlanoDoDia.fim, by: 60)), id: \.self) { minuto in
            Text(String(format: "%02d", minuto / 60))
                .font(theme.mono.font(size: 10))
                .foregroundStyle(theme.ink4.color)
                .fixedSize()
                .offset(x: PlanoDoDia.fracao(minuto) * largura - 8, y: 98)
        }
    }

    @ViewBuilder
    private func desenha(_ bloco: PlanoDoDia.Bloco, largura: CGFloat) -> some View {
        let x = PlanoDoDia.fracao(bloco.startMinute) * largura
        let fim = PlanoDoDia.fracao(bloco.startMinute + bloco.minutes) * largura
        // O mínimo é o que a palavra exige: um prazo que escreve "Prazo…" não
        // diz de quem é.
        let mínimo: CGFloat = switch bloco.tipo {
        case .prazo: 96
        case .proposto: 64
        case .compromisso: 44
        }
        let w = max(fim - x, mínimo)
        let y: CGFloat = bloco.trilha == .agenda ? 12 : 50

        HStack(spacing: 6) {
            Text(bloco.title)
                .font(theme.sans.font(size: 11.5, weight: .semibold))
                .foregroundStyle(cor(bloco))
                .lineLimit(1)
            // Bloco curto não tem largura para a duração: entre o título e o
            // "20m", quem fica é o título.
            if !bloco.duration.isEmpty, bloco.minutes >= 30 {
                Text(bloco.duration)
                    .font(theme.mono.font(size: 9.5))
                    .foregroundStyle(
                        bloco.tipo == .proposto ? theme.accentInk.color : theme.ink4.color
                    )
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .frame(width: w, height: alturaDoBloco, alignment: .leading)
        .background(fundo(bloco))
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .overlay { borda(bloco) }
        .offset(x: x, y: y)
        .contentShape(Rectangle())
        .onTapGesture { if bloco.tipo == .proposto { onTapProposto(bloco) } }
        .accessibilityLabel(rotulo(bloco))
    }

    private func cor(_ bloco: PlanoDoDia.Bloco) -> Color {
        switch bloco.tipo {
        case .compromisso: theme.ink.color
        case .proposto: theme.accentInk.color
        case .prazo: theme.warning.color
        }
    }

    private func fundo(_ bloco: PlanoDoDia.Bloco) -> Color {
        switch bloco.tipo {
        case .compromisso: theme.btn.color
        case .proposto: theme.accentSoft.color
        // O prazo é vazado: ele não ocupa tempo, ele acaba.
        case .prazo: .clear
        }
    }

    @ViewBuilder
    private func borda(_ bloco: PlanoDoDia.Bloco) -> some View {
        let forma = RoundedRectangle(cornerRadius: theme.radiusSmall)
        let espessura = Hairline.thickness(displayScale)
        switch bloco.tipo {
        case .compromisso:
            forma.strokeBorder(theme.btnLine.color, lineWidth: espessura)
        case .proposto:
            forma.strokeBorder(
                theme.accentLine.color,
                style: StrokeStyle(lineWidth: espessura, dash: [3, 3])
            )
        case .prazo:
            forma.strokeBorder(theme.warning.color.opacity(0.4), lineWidth: espessura)
        }
    }

    private func rotulo(_ bloco: PlanoDoDia.Bloco) -> String {
        let hora = MinuteFormat.clock(bloco.startMinute)
        switch bloco.tipo {
        case .compromisso: return "\(hora), \(bloco.title)"
        case .proposto: return "Proposto às \(hora), \(bloco.title)"
        case .prazo: return "Prazo às \(hora), \(bloco.title)"
        }
    }

    /// O marcador do agora: linha de 1.5 em accent com o ponto de 7 em cima.
    private func agora(_ largura: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(theme.accent.color)
                .frame(width: 1.5, height: 90)
            Circle()
                .fill(theme.accent.color)
                .frame(width: 7, height: 7)
                .offset(y: -4)
        }
        .offset(x: PlanoDoDia.fracao(nowMinute) * largura - 0.75, y: 4)
        .accessibilityLabel("Agora")
    }
}
