import Foundation
import Testing
@testable import UNISync

@Suite("SecretStore")
struct SecretStoreTests {
    private let vencido = OAuthTokens(
        accessToken: "at-velho", refreshToken: "rt",
        expiresAt: Date(timeIntervalSince1970: 1_000)
    )

    @Test("Guardar, ler e apagar, no fake em memória")
    func cicloCompleto() throws {
        let cofre = InMemorySecretStore()
        #expect(try cofre.secret(for: "conta-a") == nil)

        try cofre.store(.password("senha-de-app"), for: "conta-a")
        #expect(try cofre.secret(for: "conta-a") == .password("senha-de-app"))

        try cofre.store(.oauth(vencido), for: "conta-a")
        #expect(try cofre.secret(for: "conta-a") == .oauth(vencido))

        try cofre.remove(for: "conta-a")
        #expect(try cofre.secret(for: "conta-a") == nil)
    }

    @Test("Contas diferentes não se enxergam")
    func contasIsoladas() throws {
        let cofre = InMemorySecretStore()
        try cofre.store(.password("a"), for: "conta-a")
        try cofre.store(.password("b"), for: "conta-b")
        try cofre.remove(for: "conta-a")
        #expect(try cofre.secret(for: "conta-a") == nil)
        #expect(try cofre.secret(for: "conta-b") == .password("b"))
    }

    @Test("Apagar o que não existe não é erro — é o estado a que se queria chegar")
    func apagarAusenteNaoLanca() throws {
        let cofre = InMemorySecretStore()
        try cofre.remove(for: "nunca-existiu")
    }

    @Test("Token vencido é vencido com margem, e a margem é do chamador")
    func vencimentoComMargem() {
        let tokens = OAuthTokens(
            accessToken: "at", refreshToken: "rt",
            expiresAt: Date(timeIntervalSince1970: 2_000)
        )
        // Trinta segundos antes de vencer: com a margem padrão de 60s, já conta
        // como vencido — pedir com um token que morre no caminho é o mesmo que
        // pedir com um token morto.
        #expect(tokens.isExpired(at: Date(timeIntervalSince1970: 1_970)))
        #expect(!tokens.isExpired(at: Date(timeIntervalSince1970: 1_900)))
        #expect(!tokens.isExpired(at: Date(timeIntervalSince1970: 1_970), margin: 10))
    }

    @Test("Token antigo sem escopos ainda lê, e o Meet só conta com o escopo certo")
    func oldTokenKeepsMeetOffUntilScopeArrives() throws {
        struct Legacy: Encodable {
            let accessToken: String
            let refreshToken: String
            let expiresAt: Date
        }
        let data = try JSONEncoder().encode(
            Legacy(accessToken: "at", refreshToken: "rt", expiresAt: Date(timeIntervalSince1970: 2_000))
        )
        let decoded = try JSONDecoder().decode(OAuthTokens.self, from: data)
        #expect(decoded.scopes.isEmpty)
        #expect(decoded.canCreateMeet == false)

        let comMeet = OAuthTokens(
            accessToken: "at", refreshToken: "rt",
            expiresAt: Date(timeIntervalSince1970: 2_000),
            scopes: ["https://mail.google.com/", "https://www.googleapis.com/auth/meetings.space.created"]
        )
        #expect(comMeet.canCreateMeet)
        let comCalendar = OAuthTokens(
            accessToken: "at", refreshToken: "rt",
            expiresAt: Date(timeIntervalSince1970: 2_000),
            scopes: ["https://www.googleapis.com/auth/calendar.events"]
        )
        #expect(comCalendar.canCreateMeet)
        #expect(OAuthTokens.parseScopes("mail.google.com meetings.space.created").count == 2)
    }

    /// O Keychain de verdade só roda quando alguém pede — em CI ele é hostil
    /// (pede desbloqueio, exige assinatura, deixa lixo na keychain do usuário).
    /// `OKAMIUNI_KEYCHAIN_TESTS=1 swift test --filter Keychain` liga.
    @Test(
        "O Keychain real guarda e devolve o mesmo segredo",
        .enabled(if: ProcessInfo.processInfo.environment["OKAMIUNI_KEYCHAIN_TESTS"] == "1")
    )
    func keychainReal() throws {
        let cofre = KeychainSecretStore(service: "com.okamiops.okamiuni.testes")
        let id = "teste-\(UUID().uuidString)"
        defer { try? cofre.remove(for: id) }

        try cofre.store(.password("senha-de-app"), for: id)
        #expect(try cofre.secret(for: id) == .password("senha-de-app"))

        // Guardar de novo sobrescreve em vez de duplicar a entrada.
        try cofre.store(.oauth(vencido), for: id)
        #expect(try cofre.secret(for: id) == .oauth(vencido))

        try cofre.remove(for: id)
        #expect(try cofre.secret(for: id) == nil)
    }
}
