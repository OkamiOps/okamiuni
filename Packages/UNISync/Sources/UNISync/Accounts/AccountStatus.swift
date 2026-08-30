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
    /// A assinatura em texto simples que a conta usa ao escrever.
    ///
    /// Vazia significa que a conta não tem assinatura — não é um valor
    /// implícito inventado pela janela. O default mantém compatibilidade com
    /// fixtures e consumidores que só precisam do estado de sincronização.
    public let signature: String
    /// Assinatura estruturada da conta. A UI de assinatura rica trabalha neste
    /// valor; `signature` continua como sua alternativa plain-text para quem
    /// ainda está na API temporária.
    public let emailSignature: EmailSignature
    public let state: Account.State
    public let messageCount: Int
    public let lastSyncedAt: Date?
    /// O erro da última operação desta conta. Nulo é "nada de errado".
    public let error: SyncError?
    /// Nulo quando não há carga em curso.
    public let progress: LoadProgress?
    /// Quantas operações desta conta continuam na fila de saída — pendentes ou
    /// paradas por uma falha permanente. Zero é fila vazia.
    ///
    /// É o mesmo número que `OutboxExecutor.Outcome.pendentes`, e ele é honesto
    /// por construção: a tabela `outbox` só guarda trabalho por fazer (a
    /// operação concluída **sai** da tabela), então contar as linhas é contar o
    /// que falta. Aditivo (`0` no `init`) — quem monta um status sem fila não
    /// precisa saber que ela existe.
    public let pendingOperations: Int
    /// A falha que **parou** a fila de saída desta conta. Nulo é fila viva —
    /// andando, vazia, ou só esperando o recuo de uma falha transitória.
    ///
    /// Campo próprio, e não o `error` acima, porque os dois relatos são de
    /// coisas diferentes e chegam de lugares diferentes: o ciclo de
    /// sincronização passa a cada minuto e relata `nil` quando passa, e numa
    /// prateleira só esse `nil` apagava o erro que a fila tinha posto ali —
    /// o defeito que este campo desfaz. Ver `AccountDirector.reportQueue`.
    public let queueError: SyncError?

    public init(
        accountID: String, address: String, hostMark: String,
        state: Account.State, messageCount: Int, lastSyncedAt: Date?,
        error: SyncError?, progress: LoadProgress?,
        pendingOperations: Int = 0,
        queueError: SyncError? = nil,
        signature: String = "",
        emailSignature: EmailSignature? = nil
    ) {
        let resolvedSignature = emailSignature ?? EmailSignature(legacyText: signature)
        self.pendingOperations = pendingOperations
        self.queueError = queueError
        self.accountID = accountID
        self.address = address
        self.hostMark = hostMark
        self.signature = resolvedSignature.plainText
        self.emailSignature = resolvedSignature
        self.state = state
        self.messageCount = messageCount
        self.lastSyncedAt = lastSyncedAt
        self.error = error
        self.progress = progress
    }
}
