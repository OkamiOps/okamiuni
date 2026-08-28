import Foundation
import Security

/// O cofre de verdade: `kSecClassGenericPassword`, serviço
/// `com.okamiops.okamiuni`, conta = id da conta.
///
/// **Nenhum segredo passa pelo banco.** A tabela `account` guarda endereço,
/// host e porta; a senha de app e os tokens moram só aqui. É por isso que
/// remover uma conta são dois passos (banco + Keychain) e a janela de Contas
/// avisa antes.
public struct KeychainSecretStore: SecretStore, Sendable {
    private let service: String

    public init(service: String = "com.okamiops.okamiuni") {
        self.service = service
    }

    private func query(_ accountID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
        ]
    }

    public func store(_ secret: Secret, for accountID: String) throws {
        let data = try JSONEncoder().encode(secret)

        // Atualizar quando já existe, inserir quando não — em vez de apagar e
        // inserir. Apagar primeiro deixa uma janela em que a conta está sem
        // segredo nenhum, e um refresh concorrente nessa janela derrubaria a
        // conta para `erroDeAutenticacao` sem motivo.
        let update = SecUpdateItemDataStatus(data)
        let status = SecItemUpdate(query(accountID) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        if status != errSecItemNotFound { throw SyncError.keychain(status: status) }

        var insert = query(accountID)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw SyncError.keychain(status: added) }
    }

    public func secret(for accountID: String) throws -> Secret? {
        var lookup = query(accountID)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SyncError.keychain(status: status) }
        guard let data = item as? Data else {
            throw SyncError.resposta("O Keychain devolveu algo que não são dados.")
        }
        return try JSONDecoder().decode(Secret.self, from: data)
    }

    public func remove(for accountID: String) throws {
        let status = SecItemDelete(query(accountID) as CFDictionary)
        // Ausente não é erro, pelo mesmo motivo de `MailStore.removeFromAgenda`.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SyncError.keychain(status: status)
        }
    }
}

/// O dicionário de atualização, isolado para o `store` acima caber numa tela.
private func SecUpdateItemDataStatus(_ data: Data) -> [String: Any] {
    [kSecValueData as String: data]
}
