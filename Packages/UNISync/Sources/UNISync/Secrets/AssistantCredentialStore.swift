import UNICore
import Foundation
import Security

/// Segredos de provedores de IA ficam separados dos tokens e senhas das
/// contas de e-mail. A configuração persistida guarda apenas o identificador
/// desta entrada, nunca a chave em si.
public protocol AssistantCredentialStore: Sendable {
    func storeAPIKey(_ apiKey: String, for credentialID: String) throws
    func apiKey(for credentialID: String) throws -> String?
    /// Consulta apenas a presença da entrada. Implementações de produção não
    /// retornam nem materializam o segredo para atualizar a interface.
    func credentialPresence(for credentialID: String) throws -> AssistantCredentialPresence
    func removeAPIKey(for credentialID: String) throws
}

public enum AssistantCredentialPresence: Sendable, Hashable {
    case absent
    case present
}

public extension AssistantCredentialStore {
    /// Compatibilidade para um cofre de terceiros que ainda só exponha a API
    /// de leitura. O Keychain do app substitui esta implementação por uma
    /// consulta de atributos sem `kSecReturnData`.
    func credentialPresence(for credentialID: String) throws -> AssistantCredentialPresence {
        try apiKey(for: credentialID) == nil ? .absent : .present
    }

    /// Atalho semântico para telas que só precisam decidir se exibem
    /// "substituir" ou "adicionar". Nunca devolve a chave.
    func containsAPIKey(for credentialID: String) throws -> Bool {
        try credentialPresence(for: credentialID) == .present
    }
}

public enum AssistantCredentialStoreError: Error, Sendable, Equatable, LocalizedError {
    case invalidCredentialID
    case invalidAPIKey
    case unreadableKeychainValue
    case keychain(status: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentialID:
            L10n.tr("A referência da credencial de IA é inválida.")
        case .invalidAPIKey:
            L10n.tr("A chave de API da IA está vazia ou contém caracteres inválidos.")
        case .unreadableKeychainValue:
            L10n.tr("O Keychain devolveu uma chave de API de IA inválida.")
        case let .keychain(status):
            L10n.tr("Não foi possível acessar a chave de API de IA no Keychain (código \(status)).")
        }
    }
}

/// Implementação de produção, em um serviço de Keychain diferente do cofre
/// das contas. Assim remover uma conta não apaga acidentalmente uma chave de
/// LiteLLM, OpenAI ou Grok escolhida nas configurações.
public struct KeychainAssistantCredentialStore: AssistantCredentialStore, Sendable {
    private let service: String

    public init(service: String = "com.okamiops.okamiuni.assistant-credentials") {
        self.service = service
    }

    public func storeAPIKey(_ apiKey: String, for credentialID: String) throws {
        let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
        let apiKey = try AssistantCredentialValidation.apiKey(apiKey)
        let data = Data(apiKey.utf8)

        // Atualizar primeiro evita uma janela sem chave quando a pessoa troca
        // a credencial enquanto uma chamada de IA está em andamento.
        let status = SecItemUpdate(
            query(credentialID) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return }
        if status != errSecItemNotFound {
            throw AssistantCredentialStoreError.keychain(status: Int32(status))
        }

        var insert = query(credentialID)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw AssistantCredentialStoreError.keychain(status: Int32(added))
        }
    }

    public func apiKey(for credentialID: String) throws -> String? {
        let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
        var lookup = query(credentialID)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw AssistantCredentialStoreError.keychain(status: Int32(status))
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw AssistantCredentialStoreError.unreadableKeychainValue
        }

        do {
            return try AssistantCredentialValidation.apiKey(value)
        } catch {
            throw AssistantCredentialStoreError.unreadableKeychainValue
        }
    }

    public func credentialPresence(for credentialID: String) throws -> AssistantCredentialPresence {
        let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
        var lookup = query(credentialID)
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        let status = SecItemCopyMatching(lookup as CFDictionary, nil)
        if status == errSecItemNotFound { return .absent }
        guard status == errSecSuccess else {
            throw AssistantCredentialStoreError.keychain(status: Int32(status))
        }
        return .present
    }

    public func removeAPIKey(for credentialID: String) throws {
        let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
        let status = SecItemDelete(query(credentialID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AssistantCredentialStoreError.keychain(status: Int32(status))
        }
    }

    private func query(_ credentialID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialID,
        ]
    }
}

/// Cofre em memória para testes e prévias. Ele é deliberadamente outro tipo
/// para não dar a impressão de que o app guarda segredos persistentes fora do
/// Keychain.
public final class InMemoryAssistantCredentialStore: AssistantCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init() {}

    public func storeAPIKey(_ apiKey: String, for credentialID: String) throws {
        let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
        let apiKey = try AssistantCredentialValidation.apiKey(apiKey)
        lock.lock()
        defer { lock.unlock() }
        storage[credentialID] = apiKey
    }

    public func apiKey(for credentialID: String) throws -> String? {
        let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
        lock.lock()
        defer { lock.unlock() }
        return storage[credentialID]
    }

    public func credentialPresence(for credentialID: String) throws -> AssistantCredentialPresence {
        let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
        lock.lock()
        defer { lock.unlock() }
        return storage[credentialID] == nil ? .absent : .present
    }

    public func removeAPIKey(for credentialID: String) throws {
        let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: credentialID)
    }
}

enum AssistantCredentialValidation {
    static func credentialID(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 128 else {
            throw AssistantCredentialStoreError.invalidCredentialID
        }
        return normalized
    }

    static func apiKey(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let containsLineBreak = normalized.unicodeScalars.contains { scalar in
            scalar.value == 10 || scalar.value == 13
        }
        guard !normalized.isEmpty, normalized.count <= 16_384, !containsLineBreak else {
            throw AssistantCredentialStoreError.invalidAPIKey
        }
        return normalized
    }
}
