import SwiftUI
import UNIDesign

/// A barra de 42pt no topo das janelas 03, 05 e 06.
///
/// Protótipo: `height: 42px; padding: 0 14px; background: var(--surface2);
/// border-bottom: 0.5px solid var(--line)`, com três bolinhas à esquerda, o
/// título centrado (12px/590, `--ink2`) e um acessório à direita.
///
/// As bolinhas do protótipo são desenhadas porque lá não existe janela de
/// verdade. Aqui existe: os semáforos são os **nativos**, e a barra só reserva
/// o vão deles — a mesma decisão (e a mesma medida, `trafficLightInset`) que a
/// barra da janela principal já usa.
struct WindowTitleBar<Accessory: View>: View {
    /// **44, e não os 42 do protótipo.**
    ///
    /// A regra da casa é a dos semáforos: o conteúdo da barra e os botões do
    /// sistema caem na mesma linha, `TrafficLightLayout.contentCenterFromTop`.
    /// Com 42 o título ficava centrado em 21 e os semáforos, sem alinhador,
    /// no lugar nativo (16) — o desencontro que o dono mostrou na janela de
    /// resposta. Dois pontos de altura a mais fazem o centro da barra **ser**
    /// a linha 22, sem conta nenhuma pelo caminho.
    ///
    /// Onde a medida do protótipo briga com a convenção do macOS, a plataforma
    /// vence — é a mesma decisão que pôs os semáforos em 22 (ver
    /// `TrafficLightLayout.contentCenterFromTop`).
    static var height: CGFloat { TrafficLightLayout.contentCenterFromTop * 2 }

    @Environment(\.theme) private var theme
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        ZStack {
            Text(title)
                .font(theme.sans.font(size: 12, weight: .semibold))  // 590
                .foregroundStyle(theme.ink2.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, WindowChrome.trafficLightInset)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                accessory
            }
            .padding(.horizontal, 14)
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(theme.surface2.color)
        .hairline(theme.line, edges: .bottom)
        // E os semáforos desta janela sobem para a mesma linha. Sem isto o
        // título ia para o meio da barra e os botões do sistema ficavam onde
        // o macOS os deixa — a queixa do dono na janela de resposta.
        .trafficLightsOnTheLine(barHeight: Self.height)
    }
}

extension WindowTitleBar where Accessory == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// Rótulo mono miúdo do canto da barra — a contagem do rascunho, por exemplo.
/// Protótipo: `font-family: var(--mono); font-size: 9.5px; color: var(--ink4)`.
struct WindowBarNote: View {
    @Environment(\.theme) private var theme
    let text: String

    var body: some View {
        Text(text)
            .font(theme.mono.font(size: 9.5))
            .foregroundStyle(theme.ink4.color)
            .lineLimit(1)
    }
}
