import Foundation

/// O cofre dos testes e do ensaio: memória do processo, e nada mais.
///
/// `@unchecked Sendable` com `NSLock`, e não um ator, porque o protocolo é
/// síncrono — e o protocolo é síncrono porque o Keychain é. Trocar por ator
/// aqui obrigaria `SecretStore` inteiro a virar `async`, contaminando
/// `GoogleAuth`, `AccountDirector` e os dois `InitialLoader` por um ganho que
/// não existe: o dicionário é lido e escrito em microssegundos.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Secret] = [:]

    public init() {}

    public func store(_ secret: Secret, for accountID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[accountID] = secret
    }

    public func secret(for accountID: String) throws -> Secret? {
        lock.lock()
        defer { lock.unlock() }
        return storage[accountID]
    }

    /// As contas que têm segredo guardado agora.
    ///
    /// Existe para uma afirmação que nenhum outro acessor permite: reconectar
    /// uma conta Google guarda o token novo num rascunho antes de conferir o
    /// endereço, e o rascunho **não pode ficar para trás** no chaveiro quando a
    /// conferência recusa. Sem isto, um vazamento de credencial passaria
    /// despercebido por qualquer teste.
    public var storedAccountIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage.keys.sorted()
    }

    public func remove(for accountID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: accountID)
    }
}
