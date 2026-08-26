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
        HStack(spacing: 10) {
            ThemePreview(candidate: candidate)
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.name)
                    .font(theme.sans.font(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(theme.ink.color)
                Text(candidate.isDark ? "escuro" : "claro")
                    .font(theme.mono.font(size: 9))
                    .foregroundStyle(theme.ink4.color)
            }
            Spacer()
            if isCurrent {
                Circle().fill(theme.accent.color).frame(width: 6, height: 6)
            }
        }
        .padding(6)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .fill(isCurrent ? theme.accentSoft.color : .clear)
        }
    }
}

/// Miniatura da janela no tema candidato.
struct ThemePreview: View {
    let candidate: Theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Circle().fill(candidate.ink4.color).frame(width: 3, height: 3)
                Circle().fill(candidate.ink4.color).frame(width: 3, height: 3)
                Spacer()
            }
            .padding(.horizontal, 4)
            .frame(height: 9)
            .background(candidate.surface2.color)

            HStack(spacing: 0) {
                candidate.surface3.color.frame(width: 12)
                VStack(alignment: .leading, spacing: 3) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(candidate.accent.color)
                        .frame(width: 22, height: 3)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(candidate.ink4.color)
                        .frame(width: 30, height: 2)
                }
                .padding(.leading, 5)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            .background(candidate.surface.color)
        }
        .frame(width: 54, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(candidate.line.color, lineWidth: 0.5)
        }
    }
}
