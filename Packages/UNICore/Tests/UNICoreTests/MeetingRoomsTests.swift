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

    @Test("Zoom, Teams e Zoho conectam por credencial de API, não por link")
    func storesAPIConnection() {
        let name = "okamiuni.meeting.api.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        let store = MeetingRoomSettingsStore(defaults: suite)

        #expect(store.isConnected(.zoom) == false)
        store.setConnection(
            MeetingServiceConnection(clientID: "id", clientSecret: "secret", extra: "acct"),
            for: .zoom
        )
        #expect(store.isConnected(.zoom))
        #expect(store.connection(for: .zoom).extra == "acct")

        let reopened = MeetingRoomSettingsStore(defaults: suite)
        #expect(reopened.isConnected(.zoom))
        #expect(reopened.connection(for: .zoom).clientID == "id")
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
