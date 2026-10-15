import Foundation
import Observation

/// Quanto antes o compromisso avisa. O valor é em **minutos antes do começo**;
/// `nil` é "sem aviso".
///
/// O app guarda o aviso como texto em `EventDetail.notice` — é a coluna que o
/// banco já tem e o que o cartão do evento lê. Este enum é a tradução nos dois
/// sentidos, para a preferência não virar um número que ninguém mostra.
public enum CalendarAlert: Sendable, Hashable, CaseIterable {
    case none
    case atStart
    case minutes(Int)

    public static let allCases: [CalendarAlert] = [
        .none, .atStart, .minutes(5), .minutes(10), .minutes(15),
        .minutes(30), .minutes(60), .minutes(1_440),
    ]

    /// Minutos antes do começo. `nil` quando não há aviso nenhum.
    public var minutesBefore: Int? {
        switch self {
        case .none: nil
        case .atStart: 0
        case .minutes(let value): value
        }
    }

    public var label: String {
        switch self {
        case .none: L10n.tr("Sem aviso")
        case .atStart: L10n.tr("Na hora")
        case .minutes(let value):
            switch value {
            case 60: L10n.tr("1 hora antes")
            case 1_440: L10n.tr("1 dia antes")
            default: L10n.tr("\(value) min antes")
            }
        }
    }

    /// O texto que vai para `EventDetail.notice`.
    public var notice: String {
        switch self {
        case .none: L10n.tr("Sem aviso")
        case .atStart: L10n.tr("Alerta na hora")
        case .minutes(let value): L10n.tr("Alerta \(value) min antes")
        }
    }

    /// A volta: lê o `notice` de um compromisso **que o OkamiUNI escreveu**.
    ///
    /// Devolve `nil` para qualquer outra frase, e isso é o ponto. O EventKit
    /// devolve "Consulte o Calendário para alertas" nos eventos importados, e
    /// um palpite em cima dessa frase apagaria ou inventaria alarme num
    /// compromisso que não é nosso a cada regravação. Só o que saiu de
    /// `notice` volta por aqui.
    public static func fromNotice(_ notice: String?) -> CalendarAlert? {
        guard let notice else { return nil }
        let trimmed = notice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return allCases.first { $0.notice.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// A forma guardada no `UserDefaults`: `-1` sem aviso, senão os minutos.
    var storage: Int {
        minutesBefore ?? -1
    }

    static func fromStorage(_ value: Int) -> CalendarAlert {
        if value < 0 { return .none }
        if value == 0 { return .atStart }
        return .minutes(value)
    }
}

/// Em que dia a grade da semana começa. O número é o `firstWeekday` do
/// `Calendar` (1 = domingo), para a conversão não precisar de tabela.
public enum CalendarWeekStart: Int, Sendable, Hashable, CaseIterable {
    case sunday = 1
    case monday = 2
    case saturday = 7

    public var label: String {
        switch self {
        case .sunday: L10n.tr("domingo")
        case .monday: L10n.tr("segunda-feira")
        case .saturday: L10n.tr("sábado")
        }
    }

    /// O índice 0…6 que o dia `weekday` ocupa numa semana que começa aqui.
    public func index(ofWeekday weekday: Int) -> Int {
        (weekday - rawValue + 7) % 7
    }
}

/// A faixa de trabalho que a grade da semana realça. `nil` desliga o realce.
public struct WorkingHours: Sendable, Hashable {
    public let startMinute: Int
    public let endMinute: Int

    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    public static let options: [WorkingHours] = [
        WorkingHours(startMinute: 7 * 60, endMinute: 16 * 60),
        WorkingHours(startMinute: 8 * 60, endMinute: 17 * 60),
        WorkingHours(startMinute: 9 * 60, endMinute: 18 * 60),
        WorkingHours(startMinute: 10 * 60, endMinute: 19 * 60),
    ]

    public var label: String {
        "\(Self.clock(startMinute)) \(L10n.tr("às")) \(Self.clock(endMinute))"
    }

    private static func clock(_ minute: Int) -> String {
        String(format: "%d:%02d", minute / 60, minute % 60)
    }

    /// `"540-1080"`. Guardar como texto evita duas chaves que podem divergir.
    var storage: String { "\(startMinute)-\(endMinute)" }

    static func fromStorage(_ raw: String?) -> WorkingHours? {
        guard let raw else { return nil }
        if raw.isEmpty { return nil }
        let parts = raw.split(separator: "-")
        guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]),
              (0..<1_440).contains(start), (1...1_440).contains(end), end > start
        else { return nil }
        return WorkingHours(startMinute: start, endMinute: end)
    }
}

/// Os padrões da Agenda: com o que um evento novo nasce, e como a grade da
/// semana é desenhada.
///
/// Tudo aqui **vale de verdade**. A agenda, a duração e o aviso entram no
/// editor de compromisso novo; o início da semana move as colunas da grade; o
/// horário de trabalho pinta a faixa. Nenhuma preferência fica só guardada —
/// um controle que não muda nada é pior do que controle nenhum, porque ensina
/// a pessoa a desconfiar do resto da janela.
///
/// **Fuso não está aqui.** O app inteiro lê `Calendar.current`, e trocar o
/// fuso só nesta tela mentiria sobre o que a grade mostra. A linha do desenho
/// ficou de fora até o app ter fuso de verdade.
@MainActor
@Observable
public final class CalendarPreferences {
    private enum Key {
        static let defaultCalendar = "okamiuni.calendar.defaultCalendarID"
        static let duration = "okamiuni.calendar.defaultDurationMinutes"
        static let alert = "okamiuni.calendar.defaultAlertMinutes"
        static let weekStart = "okamiuni.calendar.weekStart"
        static let workingHours = "okamiuni.calendar.workingHours"
        static let room = "okamiuni.calendar.defaultRoom"
        static let roomMigrated = "okamiuni.calendar.defaultRoomMigrated"
    }

    public static let durationOptions = [15, 30, 45, 60, 90, 120]

    private let defaults: UserDefaults

    /// O calendário em que um compromisso novo nasce. `nil` = o que o sistema
    /// ou a conta decidirem, que é o comportamento de sempre.
    public var defaultCalendarID: String? {
        didSet { write(defaultCalendarID, Key.defaultCalendar) }
    }

    public var durationMinutes: Int {
        didSet { defaults.set(durationMinutes, forKey: Key.duration) }
    }

    public var alert: CalendarAlert {
        didSet { defaults.set(alert.storage, forKey: Key.alert) }
    }

    public var weekStart: CalendarWeekStart {
        didSet { defaults.set(weekStart.rawValue, forKey: Key.weekStart) }
    }

    /// `nil` = sem realce na grade.
    public var workingHours: WorkingHours? {
        didSet { write(workingHours?.storage, Key.workingHours) }
    }

    /// A sala que entra em todo evento novo, agora **global**.
    ///
    /// Era por conta (`MeetingRoomProfile.defaultService`), e ninguém tem uma
    /// sala por caixa de correio: a pessoa tem uma conta de Zoom. O perfil por
    /// conta vira só a migração inicial — ver `migrateRoom(from:)`.
    public var defaultRoom: MeetingService? {
        didSet { write(defaultRoom?.rawValue, Key.room) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaultCalendarID = defaults.string(forKey: Key.defaultCalendar)
        let storedDuration = defaults.integer(forKey: Key.duration)
        durationMinutes = Self.durationOptions.contains(storedDuration) ? storedDuration : 30
        alert = defaults.object(forKey: Key.alert) == nil
            ? .minutes(10)
            : CalendarAlert.fromStorage(defaults.integer(forKey: Key.alert))
        weekStart = CalendarWeekStart(rawValue: defaults.integer(forKey: Key.weekStart)) ?? .monday
        workingHours = defaults.object(forKey: Key.workingHours) == nil
            ? WorkingHours(startMinute: 9 * 60, endMinute: 18 * 60)
            : WorkingHours.fromStorage(defaults.string(forKey: Key.workingHours))
        defaultRoom = defaults.string(forKey: Key.room).flatMap(MeetingService.init(rawValue:))
    }

    /// Sobe o perfil por conta para a preferência global, **uma vez**.
    ///
    /// Quem já tinha Meet escolhido numa caixa continua com Meet; depois disso
    /// a escolha é só a global, e o perfil por conta deixa de ser lido.
    public func migrateRoom(from rooms: MeetingRoomSettingsStore, accountIDs: [String]) {
        guard !defaults.bool(forKey: Key.roomMigrated) else { return }
        defaults.set(true, forKey: Key.roomMigrated)
        guard defaultRoom == nil else { return }
        for id in accountIDs {
            if let service = rooms.profile(for: id).defaultService {
                defaultRoom = service
                return
            }
        }
    }

    /// Quantos minutos a mais o fim do compromisso recebe, dado o começo.
    public var duration: TimeInterval { TimeInterval(durationMinutes * 60) }

    /// Um `Calendar` com o início de semana da preferência. É o que a grade
    /// usa — `Calendar.current` continua valendo para tudo o mais.
    public var gridCalendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = weekStart.rawValue
        return calendar
    }

    private func write(_ value: String?, _ key: String) {
        if let value, !value.isEmpty {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
