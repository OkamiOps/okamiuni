import Testing
import Foundation
import UNIDesign
@testable import UNIShell

@Suite("ThemePicker")
struct ThemePickerTests {

    @Test("o seletor oferece os 26 temas")
    @MainActor
    func offersEveryTheme() {
        let store = ThemeStore(defaults: UserDefaults(suiteName: #function)!)
        #expect(store.all.count == 26)
    }

    @Test("a escolha sobrevive a uma nova instância")
    @MainActor
    func choicePersists() throws {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)

        let first = ThemeStore(defaults: suite)
        let okami = try #require(Theme.named("okami"))
        first.select(okami)

        let second = ThemeStore(defaults: suite)
        #expect(second.theme.id == "okami")
    }

    @Test("um id salvo inválido cai no tema padrão em vez de travar")
    @MainActor
    func invalidSavedIDFallsBack() {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        suite.set("tema-que-nao-existe", forKey: "okamiuni.theme")

        let store = ThemeStore(defaults: suite)
        #expect(store.theme.id == Theme.default.id)
    }
}
