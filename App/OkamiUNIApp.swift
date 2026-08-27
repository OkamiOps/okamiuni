import SwiftUI
import UNIDesign
import UNIShell
import UNICore

@main
struct OkamiUNIApp: App {
    @State private var themes = ThemeStore()
    @State private var mailStore = MailStore(source: InMemoryMailSource.fixtures)

    init() {
        FontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup("OkamiUNI") {
            InboxScreen(store: mailStore)
                .environment(themes)
                .theme(themes.theme)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 916)
    }
}
