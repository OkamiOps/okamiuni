import Foundation
import UNICore

/// O que a janela de Contas e a linha da lateral mostram de cada conta.
///
/// É um valor, e não a `Account` mais uns extras, porque a janela precisa de
/// coisas que não são da conta: quantas mensagens estão **no banco**, o erro
/// da última tentativa e o progresso da carga em curso.
public struct AccountStatus: Sendable, Hashable, Identifiable {
    public var id: String { accountID }
    public let accountID: String
    public let address: String
    public let hostMark: String
    public let state: Account.State
    public let messageCount: Int
    public let lastSyncedAt: Date?
    /// O erro da última operação desta conta. Nulo é "nada de errado".
    public let error: SyncError?
    /// Nulo quando não há carga em curso.
    public let progress: LoadProgress?

    public init(
        accountID: String, address: String, hostMark: String,
        state: Account.State, messageCount: Int, lastSyncedAt: Date?,
        error: SyncError?, progress: LoadProgress?
    ) {
        self.accountID = accountID
        self.address = address
        self.hostMark = hostMark
        self.state = state
        self.messageCount = messageCount
        self.lastSyncedAt = lastSyncedAt
        self.error = error
        self.progress = progress
    }
}
