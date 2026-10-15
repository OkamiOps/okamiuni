import Foundation
import Observation

/// O serviço de reunião que o OkamiUNI sabe criar por compromisso.
///
/// Os quatro nascem do **login da pessoa**: o Meet do OAuth Google da caixa
/// de correio, os outros três do OAuth que ela faz em Configurações ▸
/// Agendas. Nunca do link de uma sala permanente — uma sala reaproveitada
/// vira reunião eterna, com o título errado.
public enum MeetingService: String, CaseIterable, Identifiable, Codable, Sendable, Hashable {
    case meet
    case zoom
    case teams
    case zoho

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .meet: "Google Meet"
        case .zoom: "Zoom"
        case .teams: "Microsoft Teams"
        case .zoho: "Zoho Meeting"
        }
    }

    public var shortLabel: String {
        switch self {
        case .meet: "Meet"
        case .zoom: "Zoom"
        case .teams: "Teams"
        case .zoho: "Zoho"
        }
    }

    public var symbol: String {
        switch self {
        case .meet: "video.fill"
        case .zoom: "video"
        case .teams: "person.3.fill"
        case .zoho: "waveform"
        }
    }

}

/// A caixa Google cujo OAuth cria o Meet. O compromisso pode ser de outra
/// conta — o evento fica nela, a sala nasce no Google já conectado.
public enum MeetingGoogleAccount {
    public static func resolve(for account: Account, among accounts: [Account]) -> Account? {
        if account.provider == .gmail { return account }
        return accounts.first { $0.provider == .gmail }
    }
}

/// O serviço padrão de **uma** conta. Salas permanentes (`rooms`) ficam no
/// disco só para não quebrar preferências antigas — o editor não as usa.
public struct MeetingRoomProfile: Sendable, Hashable, Codable {
    public var defaultService: MeetingService?
    public var rooms: [String: String]

    public init(defaultService: MeetingService? = nil, rooms: [String: String] = [:]) {
        self.defaultService = defaultService
        self.rooms = rooms
    }
}

/// O serviço padrão de cada conta, e só isso.
///
/// **A credencial de API saiu daqui.** Até a versão anterior esta classe
/// também guardava client ID, segredo e um terceiro campo por serviço, em
/// `UserDefaults` — em texto plano, porque `UserDefaults` não é cofre. Agora
/// quem autoriza Zoom, Teams e Zoho é a pessoa, pelo navegador, e o token
/// mora no Keychain (`MeetingTokenVault`). A chave antiga é apagada na
/// abertura: ver `migrateLegacyConnections`.
@MainActor
@Observable
public final class MeetingRoomSettingsStore {
    private static let profileKey = "okamiuni.meeting.rooms"
    /// A chave da credencial digitada à mão. Existe só para ser apagada.
    private static let legacyConnectionKey = "okamiuni.meeting.api"

    private var profiles: [String: MeetingRoomProfile]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.profiles = Self.readProfiles(defaults)
        Self.migrateLegacyConnections(defaults)
    }

    public func profile(for accountID: String) -> MeetingRoomProfile {
        profiles[accountID] ?? MeetingRoomProfile()
    }

    public func setDefault(_ service: MeetingService?, for accountID: String) {
        var profile = profile(for: accountID)
        profile.defaultService = service
        profiles[accountID] = profile
        persistProfiles()
    }

    /// Apaga o segredo em texto plano que a versão anterior deixou.
    ///
    /// Não é limpeza cosmética: enquanto a chave existir, há client secret de
    /// Zoom e refresh token de Zoho num plist que qualquer processo do usuário
    /// lê. Apagar na abertura é o mais cedo possível.
    public static func migrateLegacyConnections(_ defaults: UserDefaults) {
        guard defaults.object(forKey: legacyConnectionKey) != nil else { return }
        defaults.removeObject(forKey: legacyConnectionKey)
    }

    private func persistProfiles() {
        defaults.set(Self.encode(profiles), forKey: Self.profileKey)
    }

    private static func readProfiles(_ defaults: UserDefaults) -> [String: MeetingRoomProfile] {
        guard let data = defaults.data(forKey: profileKey),
              let decoded = try? JSONDecoder().decode([String: MeetingRoomProfile].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }
}
