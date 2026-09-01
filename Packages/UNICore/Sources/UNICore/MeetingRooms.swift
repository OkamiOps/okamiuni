import Foundation
import Observation

/// O serviço de reunião que o OkamiUNI sabe criar por compromisso.
///
/// Meet usa o OAuth Google da caixa. Zoom, Teams e Zoho usam a API de cada
/// um — credencial de aplicativo, nunca o link de uma sala permanente. Uma
/// sala reaproveitada vira reunião eterna, com o título errado.
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

    public var extraFieldLabel: String {
        switch self {
        case .meet: ""
        case .zoom: "Account ID"
        case .teams: "Tenant ID"
        case .zoho: "Refresh token"
        }
    }

    public var needsAPIConnection: Bool {
        self != .meet
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

/// Credencial da API de Zoom, Teams ou Zoho. Não é um link de sala.
public struct MeetingServiceConnection: Sendable, Hashable, Codable {
    public var clientID: String
    public var clientSecret: String
    public var extra: String

    public init(clientID: String = "", clientSecret: String = "", extra: String = "") {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.extra = extra
    }

    public var isComplete: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !extra.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func updating(
        clientID: String? = nil, clientSecret: String? = nil, extra: String? = nil
    ) -> MeetingServiceConnection {
        MeetingServiceConnection(
            clientID: clientID ?? self.clientID,
            clientSecret: clientSecret ?? self.clientSecret,
            extra: extra ?? self.extra
        )
    }
}

/// Serviço padrão por conta e conexões de API por serviço.
@MainActor
@Observable
public final class MeetingRoomSettingsStore {
    private static let profileKey = "okamiuni.meeting.rooms"
    private static let connectionKey = "okamiuni.meeting.api"

    private var profiles: [String: MeetingRoomProfile]
    private var connections: [String: MeetingServiceConnection]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.profiles = Self.readProfiles(defaults)
        self.connections = Self.readConnections(defaults)
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

    public func connection(for service: MeetingService) -> MeetingServiceConnection {
        connections[service.rawValue] ?? MeetingServiceConnection()
    }

    public func setConnection(_ connection: MeetingServiceConnection, for service: MeetingService) {
        let cleaned = MeetingServiceConnection(
            clientID: connection.clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            clientSecret: connection.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
            extra: connection.extra.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if cleaned.clientID.isEmpty && cleaned.clientSecret.isEmpty && cleaned.extra.isEmpty {
            connections.removeValue(forKey: service.rawValue)
        } else {
            connections[service.rawValue] = cleaned
        }
        persistConnections()
    }

    public func isConnected(_ service: MeetingService) -> Bool {
        connection(for: service).isComplete
    }

    private func persistProfiles() {
        defaults.set(Self.encode(profiles), forKey: Self.profileKey)
    }

    private func persistConnections() {
        defaults.set(Self.encode(connections), forKey: Self.connectionKey)
    }

    private static func readProfiles(_ defaults: UserDefaults) -> [String: MeetingRoomProfile] {
        guard let data = defaults.data(forKey: profileKey),
              let decoded = try? JSONDecoder().decode([String: MeetingRoomProfile].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func readConnections(_ defaults: UserDefaults) -> [String: MeetingServiceConnection] {
        guard let data = defaults.data(forKey: connectionKey),
              let decoded = try? JSONDecoder().decode([String: MeetingServiceConnection].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }
}
