import Testing
@testable import UNISync

@Suite("Cofre de credenciais do assistente")
struct AssistantCredentialStoreTests {
    @Test("guarda, substitui e remove a chave apenas no cofre em memória")
    func memoryCredentialLifecycle() throws {
        let store = InMemoryAssistantCredentialStore()
        #expect(try store.credentialPresence(for: "equipe-a") == .absent)
        #expect(try !store.containsAPIKey(for: "equipe-a"))
        try store.storeAPIKey(" chave-a ", for: " equipe-a ")
        #expect(try store.apiKey(for: "equipe-a") == "chave-a")
        #expect(try store.credentialPresence(for: "equipe-a") == .present)
        #expect(try store.containsAPIKey(for: "equipe-a"))

        try store.storeAPIKey("chave-b", for: "equipe-a")
        #expect(try store.apiKey(for: "equipe-a") == "chave-b")

        try store.removeAPIKey(for: "equipe-a")
        #expect(try store.apiKey(for: "equipe-a") == nil)
        #expect(try store.credentialPresence(for: "equipe-a") == .absent)
    }

    @Test("não aceita chave que poderia injetar um cabeçalho HTTP")
    func rejectsHeaderInjection() {
        let store = InMemoryAssistantCredentialStore()
        #expect(throws: AssistantCredentialStoreError.invalidAPIKey) {
            try store.storeAPIKey("abc\r\nX-Injected: true", for: "primary")
        }
        #expect(throws: AssistantCredentialStoreError.invalidCredentialID) {
            try store.storeAPIKey("abc", for: " \n ")
        }
    }
}
