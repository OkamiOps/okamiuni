import Foundation
import Testing
@testable import UNICore

@Suite("Preferências de reunião")
@MainActor
struct MeetingRoomsTests {
    @Test("A conta guarda o serviço padrão e não uma sala permanente")
    func storesDefaultWithoutRoomURL() {
        let name = "okamiuni.meeting.test.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        let store = MeetingRoomSettingsStore(defaults: suite)

        store.setDefault(.meet, for: "conta")

        #expect(store.profile(for: "conta").defaultService == .meet)
        #expect(store.profile(for: "conta").rooms.isEmpty)
    }

    /// A credencial de servidor digitada à mão saiu, e o que ela deixou nas
    /// preferências **não pode ficar**: eram client secret do Zoom e refresh
    /// token do Zoho em texto plano num plist que qualquer processo do usuário
    /// lê. Abrir a loja apaga a chave; sem esta afirmação, o segredo antigo
    /// sobreviveria à atualização sem ninguém notar.
    @Test("Abrir a loja apaga a credencial de API em texto plano da versão antiga")
    func erasesLegacyPlaintextConnection() {
        let name = "okamiuni.meeting.api.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        let antigo = try! JSONEncoder().encode([
            "zoom": ["clientID": "id", "clientSecret": "segredo", "extra": "acct"]
        ])
        suite.set(antigo, forKey: "okamiuni.meeting.api")
        #expect(suite.object(forKey: "okamiuni.meeting.api") != nil)

        _ = MeetingRoomSettingsStore(defaults: suite)

        #expect(suite.object(forKey: "okamiuni.meeting.api") == nil)
    }

    @Test("Meet usa a conta Google mesmo quando o compromisso é de outra caixa")
    func meetResolvesAnyGmailAccount() {
        let imap = Account(
            id: "okamiops", address: "marcos@okamiops.com", displayName: "Marcos",
            provider: .imap, host: "okamiops",
            tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
        )
        let gmail = Account(
            id: "gmail", address: "msant262@gmail.com", displayName: "Marcos",
            provider: .gmail, host: "gmail",
            tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
        )
        let resolved = MeetingGoogleAccount.resolve(for: imap, among: [imap, gmail])
        #expect(resolved?.id == "gmail")
        #expect(MeetingGoogleAccount.resolve(for: imap, among: [imap]) == nil)
        #expect(MeetingGoogleAccount.resolve(for: gmail, among: [imap, gmail])?.id == "gmail")
    }

    @Test("A escolha padrão sobrevive a uma nova abertura")
    func persistsDefaultAcrossReopen() {
        let name = "okamiuni.meeting.persist.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        let first = MeetingRoomSettingsStore(defaults: suite)
        first.setDefault(.teams, for: "outlook")

        let reopened = MeetingRoomSettingsStore(defaults: suite)
        #expect(reopened.profile(for: "outlook").defaultService == .teams)
    }
}
