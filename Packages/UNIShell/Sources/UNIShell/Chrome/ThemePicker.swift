import UNICore
import SwiftUI
import UNIDesign

/// O botão da barra que abre o seletor de tema.
public struct ThemePicker: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @Environment(ThemeStore.self) private var store
    @State private var open = false

    public init() {}

    public var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: theme.isDark ? "moon.stars" : "sun.max")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.ink2.color)
                .frame(width: 38, height: 38)
                .background(theme.surface.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .strokeBorder(theme.btnLine.color, lineWidth: Hairline.thickness(displayScale))
                }
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .accessibilityLabel(L10n.tr("Escolher tema, atual \(theme.name)"))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ThemePickerPanel(onPick: { candidate in
                store.select(candidate)
                open = false
            })
        }
    }
}

/// O balão do tema: os dois vidros em cima, os clássicos embaixo, e a promessa
/// de que os 28 estão todos ali.
///
/// ## O desenho
///
/// Protótipo: `ModalSistema.dc.html`, bloco "TEMA". Balão de 360,
/// `padding: 16px`, cabeçalho com "Tema", "28 ao todo" e "esc fecha" em mono;
/// duas grades de três colunas com miniaturas de 44 de altura; e no pé "Ver os
/// 28 temas".
///
/// A divisão em dois grupos é a informação principal, e não arranjo: os dois
/// rótulos — **VIDRO · com desfoque** e **CLÁSSICOS · opacos, sem vidro** —
/// dizem em quatro palavras a única diferença real entre eles. O seletor antigo
/// listava os 28 numa pilha só, cada linha com uma miniatura de 52×36 e uma
/// nota em mono de 9: para escolher era preciso ler 28 notas.
///
/// "Ver os 28 temas" **abre a lista inteira aqui dentro** em vez de levar a
/// outra tela. Nenhum tema fica inalcançável por não caber nos seis em
/// destaque.
struct ThemePickerPanel: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let onPick: (Theme) -> Void

    @State private var showingAll = false

    /// Os seis clássicos que o protótipo destaca, na ordem dele.
    static let featured = ["okami", "tinta", "linho", "barro", "noite", "grafite"]

    private var glassThemes: [Theme] { Theme.all.filter(\.isTranslucent) }

    private var classicThemes: [Theme] { Theme.all.filter { !$0.isTranslucent } }

    private var shownClassics: [Theme] {
        guard !showingAll else { return classicThemes }
        let porId = Dictionary(uniqueKeysWithValues: classicThemes.map { ($0.id, $0) })
        let destaque = Self.featured.compactMap { porId[$0] }
        return destaque.isEmpty ? Array(classicThemes.prefix(6)) : destaque
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            cabecalho
            grupo(
                title: L10n.tr("Vidro · com desfoque"),
                themes: glassThemes
            )
            grupo(
                title: L10n.tr("Clássicos · opacos, sem vidro"),
                themes: shownClassics,
                scrolls: showingAll
            )
            if !showingAll {
                ModalSecondaryButton(L10n.tr("Ver os \(Theme.all.count) temas")) {
                    showingAll = true
                }
            }
        }
        .padding(16)
        .frame(width: Theme.ModalWidth.themePopover)
        .background(theme.modalSheet.color)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Escolher tema"))
    }

    private var cabecalho: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L10n.tr("Tema"))
                .font(theme.sans.font(size: 15, weight: .semibold))
                .foregroundStyle(theme.ink.color)
            Text(L10n.tr("\(Theme.all.count) ao todo"))
                .font(theme.sans.font(size: 12))
                .foregroundStyle(theme.ink3.color)
            Spacer(minLength: 0)
            Text(L10n.tr("esc fecha"))
                .font(theme.mono.font(size: 11))
                .foregroundStyle(theme.ink3.color)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func grupo(title: String, themes: [Theme], scrolls: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ModalEyebrow(text: title, size: 10.5, tracking: 0.06)
            if scrolls {
                ScrollView {
                    grade(themes)
                }
                .frame(maxHeight: 300)
            } else {
                grade(themes)
            }
        }
    }

    /// `grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 8px`.
    private func grade(_ themes: [Theme]) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
            spacing: 8
        ) {
            ForEach(themes) { candidate in
                tile(candidate)
            }
        }
    }

    private func tile(_ candidate: Theme) -> some View {
        let selected = candidate.id == theme.id
        return Button { onPick(candidate) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ThemeTile(candidate: candidate)
                HStack(spacing: 5) {
                    Text(candidate.name)
                        .font(theme.sans.font(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.ink2.color)
                        .lineLimit(1)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(theme.accentInk.color)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                RoundedRectangle(cornerRadius: theme.modalButtonRadius, style: .continuous)
                    .strokeBorder(
                        (selected ? theme.accentInk : theme.modalLine).color, lineWidth: 1.5
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: theme.modalButtonRadius))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.modalButtonRadius)
        .accessibilityLabel(candidate.name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A miniatura de 44 de altura do protótipo.
///
/// Duas formas, e a diferença entre elas **é** a informação: o tema de vidro
/// mostra o gradiente com uma barra translúcida flutuando em cima dele; o
/// clássico mostra papel opaco com duas linhas de texto e o ponto do acento.
/// Olhando a grade, dá para dizer qual é qual sem ler o rótulo.
struct ThemeTile: View {
    @Environment(\.theme) private var activeTheme
    @Environment(\.displayScale) private var displayScale
    let candidate: Theme

    /// `height: 44px`.
    static let height: CGFloat = 44

    var body: some View {
        Group {
            if candidate.isTranslucent {
                vidro
            } else {
                classico
            }
        }
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    activeTheme.modalLine.color, lineWidth: Hairline.thickness(displayScale)
                )
        }
        .accessibilityHidden(true)
    }

    /// `rXs: 7px` no Vidro, o raio pequeno do tema nos clássicos.
    private var radius: CGFloat { activeTheme.isTranslucent ? 7 : max(2, activeTheme.radiusSmall) }

    private var vidro: some View {
        ZStack {
            candidate.theme(for: .pane)
            RoundedRectangle(cornerRadius: 5)
                .fill(candidate.surface.color)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(candidate.panel?.edge.color ?? .clear, lineWidth: 1)
                }
                .frame(width: 60, height: 20)
                .padding(.horizontal, 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var classico: some View {
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(candidate.ink.color)
                .opacity(0.85)
                .frame(height: 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 30)
            HStack(spacing: 4) {
                Circle()
                    .fill(candidate.accent.color)
                    .frame(width: 8, height: 8)
                RoundedRectangle(cornerRadius: 2)
                    .fill(candidate.ink.color)
                    .opacity(0.4)
                    .frame(height: 4)
                Spacer(minLength: 0)
            }
            .padding(.trailing, 50)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(candidate.paper.color)
    }
}

private extension Theme {
    /// O fundo da miniatura de um tema de vidro: o gradiente dele, pintado
    /// direto (a `Backdrop` lê o tema do ambiente, e aqui o tema do ambiente é
    /// o **ativo**, não o candidato).
    @ViewBuilder
    func theme(for kind: GlassPanelKind) -> some View {
        if let backdrop, !backdrop.stops.isEmpty {
            LinearGradient(
                stops: backdrop.stops.map {
                    Gradient.Stop(color: $0.color.color, location: $0.location)
                },
                startPoint: Backdrop.unitPoint(degrees: backdrop.angle, start: true),
                endPoint: Backdrop.unitPoint(degrees: backdrop.angle, start: false)
            )
        } else if let backdrop {
            ZStack {
                backdrop.base.color
                ForEach(Array(backdrop.glows.enumerated()), id: \.offset) { _, glow in
                    RadialGradient(
                        gradient: Gradient(colors: [glow.color.color, glow.color.color.opacity(0)]),
                        center: glow.center, startRadius: 0, endRadius: 70
                    )
                }
            }
        } else {
            paper.color
        }
    }
}

/// Miniatura da janela no tema candidato — a antiga, de 52×36.
///
/// Fica para `ThemePickerTests.previewBoundaryUsesCandidateToken`, que afirma
/// que a borda de uma miniatura sai do token do **candidato** e não do tema
/// ativo: a garantia continua valendo, e `ThemeTile` a cumpre do mesmo jeito.
struct ThemePreview: View {
    @Environment(\.theme) private var activeTheme
    @Environment(\.displayScale) private var displayScale
    let candidate: Theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Circle().fill(candidate.accent.color).frame(width: 3, height: 3)
                Circle().fill(candidate.accent.color).frame(width: 3, height: 3)
                Spacer()
            }
            .padding(.horizontal, 3)
            .frame(height: 9)
            .background(candidate.surface2.color)
            .hairline(candidate.line, edges: .bottom)

            HStack(spacing: 0) {
                candidate.surface2.color.frame(width: 14)
                    .hairline(candidate.line, edges: .trailing)
                VStack(alignment: .leading, spacing: 3) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(candidate.ink.color)
                        .opacity(0.75)
                        .frame(width: 22, height: 3)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(candidate.accent.color)
                        .frame(width: 15, height: 3)
                }
                .padding(.leading, 4)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            .background(candidate.surface.color)
        }
        .frame(width: 52, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: max(2, candidate.radiusSmall)))
        .overlay {
            RoundedRectangle(cornerRadius: max(2, candidate.radiusSmall))
                .strokeBorder(
                    candidate.btnLine.color,
                    lineWidth: Hairline.thickness(displayScale)
                )
        }
        .overlay {
            if activeTheme.id == candidate.id {
                RoundedRectangle(cornerRadius: max(2, candidate.radiusSmall))
                    .strokeBorder(activeTheme.accent.color, lineWidth: 2)
            }
        }
    }
}
