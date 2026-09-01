import Foundation
import UNICore
import UNISync

/// O que a barra de busca mostra da sincronização da caixa.
///
/// Valor puro, fora da `View`: a regra "carregando, atualizada ou falhou"
/// precisa de teste sem renderizar a janela, e a barra só desenha o que isto
/// devolve.
public enum MailboxChromeStatus: Equatable, Sendable {
    /// Sem conta. A barra existe mas o botão de recarregar não tem o que fazer.
    case empty
    /// Carga inicial ou ciclo incremental em curso. `fraction` nulo é o caso
    /// honesto sem total conhecido — a barra respira em vez de fingir 0%.
    case loading(fraction: Double?)
    /// Todas as contas ativas, sem ciclo no ar.
    case ready
    /// Pelo menos uma conta falhou, e nenhuma está carregando.
    case failed(String)

    public var isBusy: Bool {
        if case .loading = self { return true }
        return false
    }

    public var canReload: Bool {
        if case .empty = self { return false }
        return true
    }

    public var label: String {
        switch self {
        case .empty:
            return "Nenhuma conta para sincronizar"
        case .loading(let fraction):
            if let fraction {
                let porcento = Int((fraction * 100).rounded())
                return "Carregando a caixa… \(porcento)%"
            }
            return "Sincronizando a caixa…"
        case .ready:
            return "Caixa atualizada"
        case .failed(let mensagem):
            return mensagem
        }
    }

    /// Recorte da lista publicada. Carregar ganha de falhar: uma conta ainda
    /// baixando não pode esconder o andamento atrás do erro de outra.
    public static func from(_ statuses: [AccountStatus]) -> MailboxChromeStatus {
        guard !statuses.isEmpty else { return .empty }

        let loading = statuses.filter { $0.state == .carregando || $0.isSyncing }
        if !loading.isEmpty {
            let progresses = loading.compactMap(\.progress)
            let allHaveTotal = progresses.count == loading.count
                && progresses.allSatisfy { $0.total > 0 }
            if allHaveTotal {
                let done = progresses.reduce(0) { $0 + $1.done }
                let total = progresses.reduce(0) { $0 + $1.total }
                let fraction = total > 0 ? min(1, Double(done) / Double(total)) : 1
                return .loading(fraction: fraction)
            }
            return .loading(fraction: nil)
        }

        if let quebrada = statuses.first(where: {
            $0.error != nil || $0.state == .erroDeAutenticacao
        }) {
            return .failed(quebrada.error?.mensagem ?? SyncError.autenticacao.mensagem)
        }

        return .ready
    }

    /// "há 4 min", "às 14:32". Nulo quando nenhuma conta sincronizou.
    public static func lastSyncedCaption(
        from statuses: [AccountStatus], now: Date = Date()
    ) -> String? {
        guard let latest = statuses.compactMap(\.lastSyncedAt).max() else { return nil }
        return relativeSync(latest, now: now)
    }

    /// Relógio relativo, em português curto.
    public static func relativeSync(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return "agora" }
        if seconds < 3_600 {
            let minutos = max(1, Int((seconds / 60).rounded()))
            return "há \(minutos) min"
        }
        let calendar = Calendar.current
        let hora: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "pt_BR")
            f.dateFormat = "HH:mm"
            return f
        }()
        if calendar.isDate(date, inSameDayAs: now) {
            return "às \(hora.string(from: date))"
        }
        let dia = DateFormatter()
        dia.locale = Locale(identifier: "pt_BR")
        dia.dateFormat = "d/M"
        return "em \(dia.string(from: date)) \(hora.string(from: date))"
    }
}

/// Retrato honesto da caixa: o que o Gmail diz vs o que está neste Mac.
public struct MailboxPortrait: Equatable, Sendable {
    public let remoteLabel: String
    public let remoteCount: Int?
    public let localCount: Int
    public let lastSyncedAt: Date?
    public let hasMore: Bool

    public init(
        remoteLabel: String,
        remoteCount: Int?,
        localCount: Int,
        lastSyncedAt: Date?,
        hasMore: Bool
    ) {
        self.remoteLabel = remoteLabel
        self.remoteCount = remoteCount
        self.localCount = localCount
        self.lastSyncedAt = lastSyncedAt
        self.hasMore = hasMore
    }

    public var countCaption: String {
        if let remoteCount {
            return "\(remoteLabel) \(Self.numero(remoteCount)) · aqui \(Self.numero(localCount))"
        }
        return MessageList.messageCountLabel(localCount, hasMore: hasMore)
    }

    /// Só quando o provedor tem mais do que o app. Clicável para puxar.
    public var gapCaption: String? {
        guard let remoteCount, remoteCount > localCount else { return nil }
        let falta = remoteCount - localCount
        return falta == 1 ? "1 não está no app" : "\(Self.numero(falta)) não estão no app"
    }

    public func lastSyncedCaption(now: Date = Date()) -> String? {
        guard let lastSyncedAt else { return nil }
        return MailboxChromeStatus.relativeSync(lastSyncedAt, now: now)
    }

    public static func from(
        account: Account?,
        status: AccountStatus?,
        localCount: Int,
        hasMore: Bool
    ) -> MailboxPortrait {
        let google = account?.provider == .gmail
        return MailboxPortrait(
            remoteLabel: google ? "Gmail Entrada" : "Entrada",
            remoteCount: google ? status?.remoteInboxCount : nil,
            localCount: localCount,
            lastSyncedAt: status?.lastSyncedAt,
            hasMore: hasMore
        )
    }

    public static func numero(_ valor: Int) -> String {
        let formatador = NumberFormatter()
        formatador.locale = Locale(identifier: "pt_BR")
        formatador.numberStyle = .decimal
        return formatador.string(from: NSNumber(value: valor)) ?? "\(valor)"
    }
}
