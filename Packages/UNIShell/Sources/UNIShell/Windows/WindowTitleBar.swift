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
    static var height: CGFloat { 42 }

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
