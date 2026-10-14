import SwiftUI
import UNICore
import UNIDesign

/// Aparência: os três cartões grandes do Vidro, os clássicos em miniatura, e
/// as três linhas de ajuste — tamanho do texto, idioma e atualizações.
///
/// Idioma e Atualizações moram aqui porque é aqui que o desenho os põe: a
/// última linha de Aparência mostra "2.4.2 pronta · Notas · Instalar e
/// reabrir", e a anterior, "Idioma do app". Eram dois cartões de "Geral", uma
/// seção que o desenho novo não tem.
struct ConfigAppearance: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette
    @Environment(\.displayScale) private var displayScale

    let themes: ThemeStore?
    let updates: UpdateController?
    @Binding var language: String
    let languageAtOpening: String
    @State private var showingAllClassics = false

    /// Quantos clássicos a fileira mostra antes do "+N". O desenho desenha
    /// sete e um oitavo com o resto.
    private static let classicsOnFirstRow = 7

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let themes {
                    ConfigBlockTitle(text: L10n.tr("Tema"))
                        .padding(.bottom, 10)
                    glassCards(themes)
                    classics(themes)
                    textSize(themes)
                } else {
                    Text(L10n.tr("O seletor de aparência aparece quando o app fornece o armazenamento de temas."))
                        .font(theme.sans.font(size: 13))
                        .foregroundStyle(palette.ink3.color)
                        .padding(.bottom, 16)
                }
                languageRow
                updatesRow
            }
            .frame(maxWidth: ConfigMetrics.contentMaxWidth, alignment: .leading)
            .padding(.bottom, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: Os três grandes

    private func glassCards(_ themes: ThemeStore) -> some View {
        HStack(alignment: .top, spacing: 14) {
            bigCard(
                title: Theme.vidro.name, note: nil,
                preview: ConfigThemePreview(theme: .vidro),
                on: !themes.followsSystemAppearance && themes.theme.id == Theme.vidro.id
            ) { themes.select(.vidro) }
            bigCard(
                title: Theme.vidroNoite.name, note: nil,
                preview: ConfigThemePreview(theme: .vidroNoite),
                on: !themes.followsSystemAppearance && themes.theme.id == Theme.vidroNoite.id
            ) { themes.select(.vidroNoite) }
            bigCard(
                title: L10n.tr("Automático"), note: L10n.tr("segue o Mac"),
                preview: ConfigThemePreview(theme: .vidro, splitWith: .vidroNoite),
                on: themes.followsSystemAppearance
            ) { themes.setFollowsSystemAppearance(true) }
        }
    }

    private func bigCard(
        title: String, note: String?, preview: ConfigThemePreview, on: Bool, pick: @escaping () -> Void
    ) -> some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 8) {
                preview
                    .frame(height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay { selectionRing(on: on, radius: 13) }
                HStack(spacing: 7) {
                    if on {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(palette.accentInk.color)
                    }
                    Text(title)
                        .font(theme.sans.font(size: 13.5, weight: on ? .semibold : .medium))
                        .foregroundStyle((on ? palette.ink : palette.ink2).color)
                    if let note {
                        Text(note)
                            .font(theme.sans.font(size: 13.5))
                            .foregroundStyle(palette.ink3.color)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 13)
        .accessibilityLabel(note == nil ? title : "\(title), \(note!)")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    @ViewBuilder
    private func selectionRing(on: Bool, radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if on {
            // `0 0 0 2px accent, 0 0 0 5px accentSoft`: o anel fino colado na
            // borda e o halo macio por fora dele.
            shape.strokeBorder(palette.accent.color, lineWidth: 2)
                .background {
                    RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                        .strokeBorder(palette.accentSoft.color, lineWidth: 3)
                        .padding(-3)
                }
        } else {
            shape.strokeBorder(palette.line.color, lineWidth: Hairline.thickness(displayScale))
        }
    }

    // MARK: Os clássicos

    private var classicThemes: [Theme] { Theme.all.filter { !$0.isGlass } }

    private func classics(_ themes: ThemeStore) -> some View {
        let all = classicThemes
        let shown = showingAllClassics ? all : Array(all.prefix(Self.classicsOnFirstRow))
        let rest = all.count - Self.classicsOnFirstRow
        return VStack(alignment: .leading, spacing: 10) {
            ConfigBlockTitle(
                text: L10n.tr("Clássicos"),
                note: L10n.tr("painéis sólidos, sem vidro — \(all.count) ao todo")
            )
            .padding(.top, 20)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 8), spacing: 10) {
                ForEach(shown) { candidate in
                    classicCell(candidate, themes: themes)
                }
                if !showingAllClassics, rest > 0 {
                    moreCell(rest)
                }
            }
        }
    }

    private func classicCell(_ candidate: Theme, themes: ThemeStore) -> some View {
        let on = !themes.followsSystemAppearance && themes.theme.id == candidate.id
        return Button { themes.select(candidate) } label: {
            VStack(spacing: 6) {
                ConfigClassicSwatch(theme: candidate)
                    .frame(height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay { selectionRing(on: on, radius: 9) }
                Text(candidate.name)
                    .font(theme.sans.font(size: 11.5, weight: on ? .semibold : .regular))
                    .foregroundStyle((on ? palette.ink : palette.ink3).color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 9)
        .accessibilityLabel(candidate.name)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func moreCell(_ rest: Int) -> some View {
        Button { showingAllClassics = true } label: {
            VStack(spacing: 6) {
                Text("+\(rest)")
                    .font(theme.sans.font(size: 12, weight: .semibold))
                    .foregroundStyle(palette.ink2.color)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(palette.field.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay { selectionRing(on: false, radius: 9) }
                Text(L10n.tr("todos"))
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(palette.ink3.color)
            }
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 9)
        .accessibilityLabel(L10n.tr("Mostrar os outros \(rest) temas"))
    }

    // MARK: As três linhas

    private func textSize(_ themes: ThemeStore) -> some View {
        ConfigRow(
            label: L10n.tr("Tamanho do texto"),
            note: L10n.tr("vale para o app inteiro; o e-mail enviado não muda"),
            divider: .bottom,
            verticalPadding: 0
        ) {
            ConfigSegmented(
                options: TypographyPreset.allCases.map { ($0, Self.typographyLabel($0)) },
                selection: Binding(
                    get: { themes.typographyPreset },
                    set: { themes.selectTypography($0) }
                ),
                sizes: [11.5, 12.5, 14]
            )
        }
        .padding(.top, 16)
        .padding(.bottom, 13)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.line.color)
                .frame(height: Hairline.thickness(displayScale))
        }
        .padding(.top, 16)
    }

    static func typographyLabel(_ preset: TypographyPreset) -> String {
        switch preset {
        case .compact: L10n.tr("Menor")
        case .standard: L10n.tr("Padrão")
        case .enlarged: L10n.tr("Maior")
        }
    }

    private var languageRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConfigRow(
                label: L10n.tr("Idioma do app"),
                note: L10n.tr("o idioma das respostas da IA fica em Inteligência"),
                divider: .bottom
            ) {
                ConfigPicker(
                    options: AppLanguage.allCases.map {
                        ($0.rawValue, $0 == .system ? L10n.tr("Igual ao do Mac") : $0.nativeName)
                    },
                    selection: $language,
                    accessibilityTitle: L10n.tr("Idioma do app")
                )
            }
            if language != languageAtOpening {
                Text(L10n.tr("Feche e abra o OkamiUNI para aplicar o idioma em todas as janelas."))
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(palette.accentInk.color)
                    .padding(.top, 8)
            }
        }
    }

    private var updatesRow: some View {
        ConfigRow(
            label: L10n.tr("Atualizações"),
            note: L10n.tr("procura sozinha uma vez por dia; instala só quando você mandar"),
            divider: .bottom
        ) {
            HStack(spacing: 12) {
                if let updates {
                    if let ready = updates.readyVersion, updates.showsReadyButton {
                        Text(L10n.tr("\(ready) pronta"))
                            .font(theme.sans.font(size: 13, weight: .medium))
                            .foregroundStyle(palette.accentInk.color)
                        Button(L10n.tr("Notas")) { updates.showChangelog() }
                            .buttonStyle(.plain)
                            .font(theme.sans.font(size: 13))
                            .foregroundStyle(palette.ink3.color)
                        Button(L10n.tr("Instalar e reabrir")) { updates.installAndRelaunch() }
                            .buttonStyle(.plain)
                            .configPrimaryButton(
                                palette, font: theme.sans.font(size: 13, weight: .semibold),
                                radius: 9, horizontal: 13, vertical: 8
                            )
                            .accessibilityIdentifier("settings-install-update")
                    } else {
                        Text(updates.versionLine)
                            .font(theme.mono.font(size: 12))
                            .foregroundStyle(palette.ink3.color)
                        Button(L10n.tr("Procurar agora")) { updates.checkNow() }
                            .buttonStyle(.plain)
                            .configQuietButton(palette, font: theme.sans.font(size: 13, weight: .medium))
                            .disabled(updates.isChecking)
                    }
                } else {
                    // Build de desenvolvimento: o atualizador está desligado de
                    // propósito, e dizer isso é melhor do que oferecer um botão
                    // que não procura nada.
                    Text(L10n.tr("desligadas neste build"))
                        .font(theme.sans.font(size: 13))
                        .foregroundStyle(palette.ink3.color)
                }
            }
        }
    }
}

/// A miniatura de um tema de vidro: o gradiente, o trilho, o painel e três
/// barras — exatamente as cinco camadas que o mock posiciona em absoluto.
struct ConfigThemePreview: View {
    let theme: Theme
    /// Quando existe, a miniatura é dividida na diagonal entre os dois temas —
    /// é o cartão "Automático".
    var splitWith: Theme?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                backdrop
                panels(size: proxy.size)
                if let splitWith {
                    // O tema da direita entra **inteiro** — fundo e painéis —
                    // recortado na diagonal. Desenhar só o fundo dele deixava
                    // os painéis do tema claro por cima, e a metade escura
                    // saía cinza.
                    ConfigThemePreview(theme: splitWith)
                        .mask(alignment: .leading) {
                            // `linear-gradient(110deg, claro 0 50%, escuro 50% 100%)`
                            // é um corte reto, não um esmaecido.
                            Path { path in
                                let w = proxy.size.width
                                let h = proxy.size.height
                                path.move(to: CGPoint(x: w * 0.56, y: 0))
                                path.addLine(to: CGPoint(x: w, y: 0))
                                path.addLine(to: CGPoint(x: w, y: h))
                                path.addLine(to: CGPoint(x: w * 0.44, y: h))
                                path.closeSubpath()
                            }
                            .fill(Color.black)
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var backdrop: some View {
        if let backdrop = theme.backdrop {
            ZStack {
                backdrop.base.color
                if !backdrop.stops.isEmpty {
                    LinearGradient(
                        stops: backdrop.stops.map {
                            Gradient.Stop(color: $0.color.color, location: $0.location)
                        },
                        startPoint: Backdrop.unitPoint(degrees: backdrop.angle, start: true),
                        endPoint: Backdrop.unitPoint(degrees: backdrop.angle, start: false)
                    )
                }
                ForEach(Array(backdrop.glows.enumerated()), id: \.offset) { _, glow in
                    RadialGradient(
                        gradient: Gradient(colors: [glow.color.color, glow.color.color.opacity(0)]),
                        center: glow.center, startRadius: 0, endRadius: 120
                    )
                }
            }
        } else {
            theme.paper.color
        }
    }

    private func panels(size: CGSize) -> some View {
        let panel = (theme.panel?.fill ?? theme.surface).color
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(panel)
                .frame(width: 20)
                .padding(.vertical, 12)
                .padding(.leading, 12)
                .frame(width: size.width, height: size.height, alignment: .leading)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(panel)
                .padding(.vertical, 12)
                .padding(.leading, 38)
                .padding(.trailing, 12)
            Group {
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(theme.ink.color)
                    .frame(width: size.width * 0.46, height: 7)
                    .offset(x: 50, y: 26)
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(theme.ink.color.opacity(0.45))
                    .frame(width: size.width * 0.30, height: 7)
                    .offset(x: 50, y: 41)
                RoundedRectangle(cornerRadius: 5)
                    .fill(theme.accent.color)
                    .frame(width: size.width * 0.24, height: 12)
                    .offset(x: 50, y: size.height - 24 - 12)
            }
        }
    }
}

/// A miniatura de um clássico: o fundo sólido, uma barra de tinta e uma de
/// acento. Sem vidro, sem gradiente — é o que o desenho promete para os 26.
struct ConfigClassicSwatch: View {
    let theme: Theme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                theme.surface.color
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(theme.ink.color)
                    .frame(width: proxy.size.width * 0.42, height: 5)
                    .offset(x: 7, y: 7)
                RoundedRectangle(cornerRadius: 3)
                    .fill(theme.accent.color)
                    .frame(width: proxy.size.width * 0.26, height: 8)
                    .offset(x: 7, y: proxy.size.height - 8 - 8)
            }
        }
    }
}
