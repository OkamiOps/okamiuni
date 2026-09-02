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
    private var didChangeHandlers: [@Sendable (AssistantSettings) -> Void] = []

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
        do {
            try Self.persist(normalized, defaults: defaults, key: key)
        } catch {
            lock.unlock()
            throw error
        }
        cached = normalized
        lock.unlock()
        publishDidChange(normalized)
        return normalized
    }

    /// Quem observa é avisado **fora** do lock: um handler que voltasse a
    /// chamar `snapshot()` travaria o cofre contra si mesmo.
    public func addDidChangeHandler(_ handler: @escaping @Sendable (AssistantSettings) -> Void) {
        lock.lock()
        didChangeHandlers.append(handler)
        lock.unlock()
    }

    private func publishDidChange(_ settings: AssistantSettings) {
        lock.lock()
        let handlers = didChangeHandlers
        lock.unlock()
        for handler in handlers { handler(settings) }
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
        // Comparar o documento inteiro, e não só a versão do esquema: o
        // carimbo do opt-in nasce dentro de `migrated()` e precisa ser gravado
        // na mesma abertura. Sem isto ele seria recalculado a cada lançamento
        // e as mensagens chegadas entre dois deles ficariam de fora da rota
        // que a pessoa ligou.
        return .init(settings: migrated, needsMigration: decoded != migrated)
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
