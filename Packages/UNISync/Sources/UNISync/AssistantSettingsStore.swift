import Foundation

/// Persistência pequena e independente do banco de e-mail. Preferências de IA
/// continuam disponíveis mesmo se o SQLite das mensagens não puder abrir, e um
/// documento único evita que uma leitura veja endpoint novo com modelo antigo.
///
/// O `UserDefaults` não é `Sendable`. O lock guarda tanto a cópia em memória
/// quanto sua escrita para que o cofre possa ser compartilhado entre a UI e o
/// router sem transferir um `UserDefaults` não isolado para um ator.
public final class AssistantSettingsStore: @unchecked Sendable {
    public static let defaultKey = "com.okamiops.okamiuni.assistant-settings"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let key: String
    private var cached: AssistantSettings

    public init(defaults: UserDefaults = .standard, key: String = AssistantSettingsStore.defaultKey) {
        self.defaults = defaults
        self.key = key

        let loaded = Self.load(defaults: defaults, key: key)
        cached = loaded.settings

        // A migração é gravada já na abertura. O `try?` mantém o pior caso
        // honesto: se o UserDefaults estiver indisponível, a sessão ainda usa a
        // cópia válida em memória em vez de impedir o app de abrir.
        if loaded.needsMigration {
            try? Self.persist(loaded.settings, defaults: defaults, key: key)
        }
    }

    public func snapshot() -> AssistantSettings {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// Substitui o documento inteiro depois de validar e normalizar seus dados.
    /// A UI deve manter rascunhos localmente e chamar isto ao salvar, nunca a
    /// cada tecla digitada no campo de prompt.
    @discardableResult
    public func save(_ settings: AssistantSettings) throws -> AssistantSettings {
        let normalized = try settings.migrated()
        lock.lock()
        defer { lock.unlock() }
        try Self.persist(normalized, defaults: defaults, key: key)
        cached = normalized
        return normalized
    }

    @discardableResult
    public func reset() throws -> AssistantSettings {
        try save(.default)
    }

    private static func load(defaults: UserDefaults, key: String) -> LoadedSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(AssistantSettings.self, from: data),
              let migrated = try? decoded.migrated()
        else {
            // Um documento corrompido ou criado por um binário futuro não é
            // apagado no boot. A sessão cai com segurança no padrão, mas só
            // uma ação explícita de salvar/resetar pode substituir os bytes
            // que outra versão do app ainda sabe interpretar.
            return .init(settings: .default, needsMigration: false)
        }
        return .init(
            settings: migrated,
            needsMigration: decoded.schemaVersion != migrated.schemaVersion
        )
    }

    private static func persist(
        _ settings: AssistantSettings,
        defaults: UserDefaults,
        key: String
    ) throws {
        let data = try JSONEncoder().encode(settings)
        defaults.set(data, forKey: key)
    }

    private struct LoadedSettings {
        let settings: AssistantSettings
        let needsMigration: Bool
    }
}
