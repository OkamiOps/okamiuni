import AppKit
import SwiftUI
import UNICore
import UNIDesign

/// O caminho para **qualquer** cor, ao lado da paleta do design.
///
/// ## O que muda e o que não muda
///
/// As seis cores de texto e os seis realces do protótipo (`swatchPanel`, linha
/// 2637 do `.dc.html`) continuam onde estavam, na mesma ordem e com o mesmo
/// desenho: são a escolha rápida, e é o que o design pede. O que se acrescenta
/// é o "Outra cor…" no fim — o dono do projeto relatou "seletor de cor está
/// muito limitado, o correto era o cara escolher a cor que ele quiser".
///
/// **Somar, não trocar.** Uma roda de cores no lugar da paleta tiraria os seis
/// atalhos que o design desenhou para deixar no lugar deles um gesto de três
/// passos.
///
/// ## Por que o painel do sistema
///
/// No macOS o seletor de cor é o `NSColorPanel`: roda, réguas, lápis, paletas e
/// o conta-gotas que pega a cor de qualquer pixel da tela. Desenhar uma roda
/// própria seria refazer, pior, o que a plataforma já faz — e sem o
/// conta-gotas, que é o que faz alguém escolher a cor exata de uma marca.
///
/// O que fica **nosso** é o gatilho: um item da paleta, com a mesma moldura e o
/// mesmo raio dos outros, em vez de um `ColorPicker` do SwiftUI, que desenharia
/// mais um controle com a cara do sistema no meio dos seis do design — que é
/// justamente o que o dono reclamou nos menus.
///
/// ## Estado global, porque o painel é global
///
/// Só existe **um** `NSColorPanel` por app. Quem estiver com ele aberto é quem
/// recebe as mudanças, e por isso o alvo da ação é um singleton: dois
/// composers abertos não podem se escutar. Trocar de gatilho reaponta o
/// destino; fechar a janela desliga.
@MainActor
final class FreeColorPanel: NSObject {
    static let shared = FreeColorPanel()

    private var deliver: ((String) -> Void)?
    /// Quem está recebendo agora. Duas janelas abertas disputam o mesmo painel,
    /// e sem isto a que fechasse desligaria a entrega da outra.
    private var owner: UUID?

    private override init() { super.init() }

    /// Abre o painel do sistema já na cor atual e entrega cada mudança em
    /// `#RRGGBB`.
    ///
    /// As mudanças chegam **enquanto** a pessoa arrasta na roda, e é assim que
    /// tem de ser: o texto selecionado muda de cor junto, e ela decide olhando
    /// para o texto em vez de para a amostra.
    @discardableResult
    func present(current hex: String, owner: UUID, deliver: @escaping (String) -> Void) -> UUID {
        self.deliver = deliver
        self.owner = owner
        let panel = NSColorPanel.shared
        // Sem alfa: `BodyStyle.colorHex` documenta que nunca é transparente —
        // texto invisível não é formatação. Deixar o controle de alfa à mostra
        // seria oferecer o que não vai ser guardado.
        panel.showsAlpha = false
        if let start = TokenColor(css: hex)?.nsColor { panel.color = start }
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
        return owner
    }

    /// Desliga a entrega sem fechar o painel.
    ///
    /// Fechar seria pior: o `NSColorPanel` é do app inteiro, e uma janela que o
    /// fecha ao sair de cena o fecharia na cara de outra que ainda o usa.
    func stop(owner: UUID) {
        guard self.owner == owner else { return }
        deliver = nil
        self.owner = nil
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        // O painel pode devolver cor em espaço mais largo que o sRGB (Display
        // P3, por exemplo). Converter antes de ler os componentes: sem isso um
        // vermelho de P3 chega com componente 1,09 e o hex sairia estourado.
        guard let srgb = sender.color.usingColorSpace(.sRGB) else { return }
        deliver?(
            ColorHex.string(
                red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent
            )
        )
    }
}

/// O item "Outra cor…" no fim da paleta.
///
/// Protótipo: não existe — é a parte pedida pelo dono do projeto. O desenho é o
/// da própria paleta, para o item ler como o sétimo de uma fileira de seis e
/// não como um controle estranho colado nela: mesma moldura, mesmo raio, e a
/// bolinha à esquerda mostrando a cor que está valendo.
struct FreeColorRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let title: String
    /// A cor de agora, para a bolinha. Nula é "sem realce".
    let current: Color?
    /// Verdadeiro quando a escolha atual **não** é nenhuma das seis: o item
    /// acende, e é assim que a pessoa vê que a cor aplicada veio daqui.
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle()
                    .fill(current ?? theme.surface.color)
                    .frame(width: 12, height: 12)
                    .overlay {
                        Circle().strokeBorder(
                            theme.line.color, lineWidth: Hairline.thickness(displayScale)
                        )
                    }
                Text(title)
                    .font(theme.sans.font(size: 11.5, weight: .medium))  // CSS 550
                    .foregroundStyle(isActive ? theme.accentInk.color : theme.ink2.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? theme.accentSoft.color : .clear)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall)
                    .strokeBorder(
                        isActive ? theme.accent.color : theme.line.color,
                        lineWidth: Hairline.thickness(displayScale)
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .help("Escolher qualquer cor no seletor do sistema")
    }
}
