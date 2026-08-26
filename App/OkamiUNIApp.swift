import SwiftUI
import UNIDesign

@main
struct OkamiUNIApp: App {
    @State private var themes = ThemeStore()

    init() {
        FontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup("OkamiUNI") {
            RootView()
                .environment(themes)
                .theme(themes.theme)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 916)
    }
}

struct RootView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.paper.color.ignoresSafeArea()
            Text("OkamiUNI")
                .font(theme.serif.font(size: 28, weight: .medium))
                .foregroundStyle(theme.ink.color)
        }
    }
}
