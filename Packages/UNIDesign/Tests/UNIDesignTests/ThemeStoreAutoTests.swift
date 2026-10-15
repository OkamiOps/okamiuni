import Foundation
import Testing
@testable import UNIDesign

/// O "Automático · segue o Mac" do cartão de Aparência.
///
/// Ele não é um tema: é a ausência de escolha entre os dois Vidros. O que estes
/// casos prendem é o contrato dessa ausência — ligar, desligar sem saltar de
/// aparência, e sair sozinho quando alguém escolhe um tema de verdade.
@MainActor
@Suite("Tema automático")
struct ThemeStoreAutoTests {

    private func loja() throws -> (store: ThemeStore, suite: String, defaults: UserDefaults) {
        let suite = "okamiuni.theme-auto.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (ThemeStore(defaults: defaults), suite, defaults)
    }

    @Test("ligado, o tema é o Vidro que combina com a aparência do sistema")
    func seguirOSistema() throws {
        let (store, suite, defaults) = try loja()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.setFollowsSystemAppearance(true)
        #expect(store.followsSystemAppearance)
        #expect(store.selectedThemeID == nil, "no automático não há tema escolhido")
        // Sem `NSApplication` a aparência observada é a clara, que é o padrão
        // do sistema e o primeiro quadro do desenho.
        #expect(store.theme.id == (store.systemIsDark ? "vidro-noite" : "vidro"))
    }

    @Test("desligar não salta de aparência: fica o tema que estava resolvido")
    func desligarPreservaOQueSeVia() throws {
        let (store, suite, defaults) = try loja()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.setFollowsSystemAppearance(true)
        let visivel = store.theme.id
        store.setFollowsSystemAppearance(false)
        #expect(!store.followsSystemAppearance)
        #expect(store.theme.id == visivel, "o tema mudou ao desligar o automático")
        #expect(store.selectedThemeID == visivel)
    }

    @Test("escolher um tema sai do automático sozinho")
    func escolherUmTemaDesligaOAutomatico() throws {
        let (store, suite, defaults) = try loja()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.setFollowsSystemAppearance(true)
        store.select(.okami)
        #expect(!store.followsSystemAppearance)
        #expect(store.theme.id == "okami")
    }

    @Test("a escolha sobrevive a reabrir o app")
    func persistencia() throws {
        let (store, suite, defaults) = try loja()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.setFollowsSystemAppearance(true)
        let outra = ThemeStore(defaults: defaults)
        #expect(outra.followsSystemAppearance)
    }
}
