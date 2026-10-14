import SwiftUI
import UNICore
import UNIDesign

/// O cromado do compositor, copiado de `design/project/Compositor.dc.html` (e
/// do par escuro, `Compositor-Escuro.dc.html`).
///
/// **Um layout só, para os 28 temas.** Não há fork de vidro e de clássico aqui:
/// a estrutura, as medidas e os componentes são os mesmos em qualquer tema, e o
/// que `theme.isGlass` decide é apenas o **tratamento de superfície** — nos dois
/// temas Vidro a janela é translúcida sobre o gradiente; nos outros 26 ela é
/// opaca, nas cores de `surface` e `line` do próprio tema. Ver
/// `ComposerTone` e `Theme.glassWindow`.
///
/// ## O que o mock faz com o compositor, e que a janela não fazia
///
/// A janela antiga era uma pilha de caixas com borda: cada linha do cabeçalho
/// com a sua, a barra com a sua, o rodapé com a sua, mais pastilhas de host e
/// de Cc/Cco soltas. O mock troca tudo isso por **linhas separadas por um fio**
/// dentro de uma calha de 22pt — sem caixa dentro de caixa — e resolve Cc/Cco
/// como texto no fim da linha "Para", não como pastilha.
///
/// As medidas que estes componentes carregam são as do mock, literais:
/// calha de 22pt, rótulo de 56pt, linhas de 9pt em cima e embaixo, fio de
/// `line` entre elas, corpo com 28×22 de folga, rodapé de 12×18.
enum ComposerTone {

    /// `t.soft` do mock: `rgba(20,20,50,0.05)` no claro,
    /// `rgba(255,255,255,0.07)` no escuro — a calha das pastilhas, dos chips e
    /// do histórico. Fora do Vidro, `glassSoft` já cai em `surface3`, que é a
    /// mesma altura pintada **opaca** nas cores do tema.
    static func soft(_ theme: Theme) -> Color { theme.glassSoft.color }

    /// `t.on` do mock: o fundo do botão **ligado** da barra. No Vidro ele é um
    /// relevo neutro (`rgba(20,20,50,0.08)` / `rgba(255,255,255,0.12)`), como o
    /// desenho pede. Nos 26 temas opacos um relevo de 8% sobre `surface3` não
    /// se distingue da calha; lá o aceso é o `accentSoft` que a barra desses
    /// temas sempre usou, e o estado continua legível.
    static func on(_ theme: Theme) -> Color {
        guard theme.isGlass else { return theme.accentSoft.color }
        return theme.isDark
            ? Color.white.opacity(0.12)
            : Color(red: 20 / 255, green: 20 / 255, blue: 50 / 255).opacity(0.08)
    }

    /// A tinta do botão aceso: no Vidro é `ink` (relevo neutro); nos opacos
    /// acompanha o `accentSoft` que ficou atrás dele.
    static func onInk(_ theme: Theme) -> Color {
        theme.isGlass ? theme.ink.color : theme.accentInk.color
    }

    /// `t.foot` do mock: o rodapé é um tom **mais** que a janela —
    /// `rgba(255,255,255,0.03)` no escuro, `rgba(20,20,50,0.02)` no claro. Nos
    /// temas opacos é `surface2`, a mesma altura que o rodapé já tinha.
    static func foot(_ theme: Theme) -> Color {
        guard theme.isGlass else { return theme.surface2.color }
        return theme.isDark
            ? Color.white.opacity(0.03)
            : Color(red: 20 / 255, green: 20 / 255, blue: 50 / 255).opacity(0.02)
    }
}

// MARK: - Cabeçalho

/// Mock, linha 20: `padding: 12px 16px; gap: 12px; border-bottom: 1px solid
/// line`, com o assunto centrado em 13px/600 `ink2` e, à direita, o botão que
/// devolve a resposta para dentro do e-mail.
///
/// **44pt de altura, e não os ~48 que o mock soma.** É a mesma decisão da
/// `WindowTitleBar`: os semáforos nativos ficam na linha
/// `TrafficLightLayout.contentCenterFromTop`, e a barra tem de ter o dobro
/// disso para o centro dela *ser* aquela linha. Onde a medida do desenho briga
/// com a convenção do macOS, a plataforma vence.
struct ComposerHeaderBar: View {
    @Environment(\.theme) private var theme
    let title: String
    let leave: () -> Void

    static var height: CGFloat { TrafficLightLayout.contentCenterFromTop * 2 }

    var body: some View {
        ZStack {
            Text(title)
                .font(theme.sans.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.ink2.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, WindowChrome.trafficLightInset)

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ComposerIconButton(
                    symbol: "arrow.down.forward.and.arrow.up.backward",
                    size: 15,
                    help: L10n.tr("Voltar para dentro do e-mail"),
                    action: leave
                )
            }
            .padding(.horizontal, 16)
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .hairline(theme.line, edges: .bottom)
        .trafficLightsOnTheLine(barHeight: Self.height)
    }
}

// MARK: - Linhas do cabeçalho

/// Uma linha De / Para / Assunto. Mock, linha 32: `display: flex; gap: 12px;
/// padding: 9px 0; border-bottom: 1px solid line; font-size: 14px`, com o
/// rótulo numa calha de 56pt em 13px `ink3`.
struct ComposerFieldRow<Content: View, Accessory: View>: View {
    @Environment(\.theme) private var theme
    let label: String
    /// `false` na última linha: o mock fecha o bloco de campos com o fio da
    /// barra de formatação, não com dois fios encostados.
    var showsLine = true
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    var body: some View {
        if showsLine {
            row.hairline(theme.line, edges: .bottom)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(theme.sans.font(size: 13))
                .foregroundStyle(theme.ink3.color)
                .frame(width: 56, alignment: .leading)
                // O rótulo acompanha a primeira linha do conteúdo, que pode
                // ter etiquetas de 28pt.
                .padding(.top, 3)

            content

            Spacer(minLength: 8)

            accessory
                .padding(.top, 2)
        }
        .padding(.vertical, 9)
    }
}

extension ComposerFieldRow where Accessory == EmptyView {
    init(label: String, showsLine: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(label: label, showsLine: showsLine, content: content) { EmptyView() }
    }
}

/// O "trocar ▾" e o "Cc Cco" do fim das linhas: texto no acento, 13px, sem
/// moldura. Mock, linha 42.
struct ComposerRowAction: View {
    @Environment(\.theme) private var theme
    let label: String
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(theme.sans.font(size: 13))
                .foregroundStyle(theme.accentInk.color)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 6)
        .help(help.isEmpty ? label : help)
    }
}

// MARK: - Botões

/// O botão de ícone sem moldura da barra e do cabeçalho. Mock, linha 53:
/// `background: transparent|on; padding: 7px; border-radius: 8px`, ícone de
/// 17pt, `ink2` apagado e `ink` aceso.
struct ComposerIconButton: View {
    @Environment(\.theme) private var theme
    let symbol: String
    var size: CGFloat = 17
    var on = false
    var enabled = true
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(foreground)
                // Mock: `padding: 7px` em volta de um ícone de 17.
                .frame(width: size + 14, height: size + 14)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 8)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var background: Color {
        if on { return ComposerTone.on(theme) }
        return hovering && enabled ? ComposerTone.soft(theme) : .clear
    }

    private var foreground: Color {
        if !enabled { return theme.ink4.color.opacity(0.45) }
        return on ? ComposerTone.onInk(theme) : theme.ink2.color
    }
}

/// A pastilha com rótulo: "Melhorar com IA" (acento suave), "Agendar"
/// (`soft`) e "Enviar ⌘↵" (acento cheio). Mock, linhas 57, 95 e 99.
struct ComposerPillButton<Label: View>: View {
    @Environment(\.theme) private var theme

    enum Kind { case accent, accentSoft, soft }

    let kind: Kind
    var help: String = ""
    var enabled = true
    let action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button(action: action) {
            label
                .foregroundStyle(foreground)
                .padding(.horizontal, kind == .accent ? 20 : 14)
                .padding(.vertical, 10)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(
                    color: kind == .accent
                        ? theme.accent.color.opacity(0.30) : .clear,
                    radius: 7, x: 0, y: 4
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 10)
        .disabled(!enabled)
        .help(help)
        .opacity(enabled ? 1 : 0.5)
    }

    private var background: Color {
        switch kind {
        case .accent: theme.accent.color
        case .accentSoft: theme.accentSoft.color
        case .soft: ComposerTone.soft(theme)
        }
    }

    private var foreground: Color {
        switch kind {
        case .accent: theme.onAccent.color
        case .accentSoft: theme.accentInk.color
        case .soft: theme.ink.color
        }
    }
}

/// A divisória vertical entre os grupos da barra. Mock, linha 51:
/// `width: 1px; height: 20px; margin: 0 6px`.
struct ComposerToolbarSeparator: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.line.color)
            .frame(width: 1, height: 20)
            .padding(.horizontal, 6)
    }
}

// MARK: - Corpo

/// A pastilha que abre e fecha a mensagem citada. Mock, linha 74:
/// `padding: 8px 12px; border-radius: 10px; background: soft`, com `···` no
/// mono e a frase em `ink3` de 13px.
///
/// No mock ela aparece **fechada** — e é esse o estado em que a janela de vidro
/// nasce. A janela antiga abria o histórico inteiro e punha um botão "Ocultar
/// histórico" em cima dele; aqui a pastilha é o botão, e o que ela diz é de
/// quem é a mensagem e de quando.
struct ComposerHistoryPill: View {
    @Environment(\.theme) private var theme
    let label: String
    let open: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("···")
                    .font(theme.mono.font(size: 13))
                    .foregroundStyle(theme.ink3.color)
                Text(label)
                    .font(theme.sans.font(size: 13))
                    .foregroundStyle(theme.ink3.color)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(ComposerTone.soft(theme))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 10)
        .help(open ? L10n.tr("Ocultar a mensagem citada") : L10n.tr("Mostrar a mensagem citada"))
    }
}

// MARK: - Anexo

/// Mock, linha 80: `padding: 7px 12px 7px 7px; border-radius: 10px;
/// background: soft`, com a plaqueta do tipo em 26×30 e raio 5, o nome em
/// 12px/600 e o tamanho em 11px `ink3`.
struct ComposerAttachmentChip: View {
    @Environment(\.theme) private var theme
    let name: String
    let size: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(Self.badge(for: name))
                .font(theme.sans.font(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 30)
                .background(Self.badgeTint(for: name))
                .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(theme.sans.font(size: 12, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                Text(size)
                    .font(theme.sans.font(size: 11))
                    .foregroundStyle(theme.ink3.color)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.ink3.color)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(in: Rectangle())
            .padding(.leading, 6)
            .help(L10n.tr("Tirar este anexo"))
        }
        .padding(.leading, 7)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .background(ComposerTone.soft(theme))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Três letras da extensão, como o `PDF` do mock.
    static func badge(for name: String) -> String {
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "ARQ" : String(ext.prefix(3))
    }

    /// O mock pinta o PDF em `#ef4444`. Os outros tipos não estão desenhados;
    /// eles ficam no acento do tema em vez de herdarem o vermelho do PDF, que
    /// no resto do app quer dizer perigo.
    static func badgeTint(for name: String) -> Color {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "pdf"
            ? Color(red: 239 / 255, green: 68 / 255, blue: 68 / 255)
            : Color(red: 59 / 255, green: 130 / 255, blue: 246 / 255)
    }
}
