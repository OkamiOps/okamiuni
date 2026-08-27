import SwiftUI
import UNIDesign

public struct ThemePicker: View {
    @Environment(\.theme) private var theme
    @Environment(ThemeStore.self) private var store
    @State private var open = false

    public init() {}

    public var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(theme.accent.color)
                    .frame(width: 8, height: 8)
                Text(theme.name)
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(theme.ink2.color)
                Text("▼")
                    .font(.system(size: 7))
                    .foregroundStyle(theme.ink3.color)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(theme.btn.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall)
                    .strokeBorder(theme.btnLine.color, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .accessibilityLabel("Escolher tema, atual \(theme.name)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            popoverBody
        }
    }

    private var popoverBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Temas · cor, tipo e densidade")
                .capsLabel()
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.all) { candidate in
                        Button { store.select(candidate); open = false } label: {
                            ThemeRow(
                                candidate: candidate,
                                isCurrent: candidate.id == theme.id
                            )
                        }
                        .buttonStyle(.plain)
                        .focusRing(cornerRadius: theme.radiusSmall)
                    }
                }
            }
            .frame(maxHeight: 420)
        }
        .padding(8)
        .frame(width: 300)
        .background(theme.surface.color)
    }
}

private struct ThemeRow: View {
    @Environment(\.theme) private var theme
    let candidate: Theme
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 11) {
            ThemePreview(candidate: candidate)
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.name)
                    .font(theme.sans.font(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(theme.ink.color)
                Text(candidate.note)
                    .font(theme.mono.font(size: 9))
                    .foregroundStyle(theme.ink4.color)
            }
            Spacer()
            if isCurrent {
                Circle().fill(theme.accent.color).frame(width: 6, height: 6)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .fill(isCurrent ? theme.accentSoft.color : .clear)
        }
    }
}

/// Miniatura da janela no tema candidato.
struct ThemePreview: View {
    @Environment(\.theme) private var activeTheme
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
                        // 22pt ≈ 70% da área útil (52 − 14 trilho − 8 padding = 30pt)
                        .frame(width: 22, height: 3)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(candidate.accent.color)
                        // 15pt ≈ 45% da área útil (52 − 14 trilho − 8 padding = 30pt)
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
            // Contorno de 0.5px preto 28% — literal do protótipo, não um token.
            // Stroke always drawn, selection ring overlay on top when active.
            RoundedRectangle(cornerRadius: max(2, candidate.radiusSmall))
                .strokeBorder(Color.black.opacity(0.28), lineWidth: 0.5)
        }
        .overlay {
            if activeTheme.id == candidate.id {
                RoundedRectangle(cornerRadius: max(2, candidate.radiusSmall))
                    .strokeBorder(activeTheme.accent.color, lineWidth: 2)
            }
        }
    }
}
