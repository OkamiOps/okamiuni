import Foundation
import GRDB
import Observation
import UNICore

/// Os rascunhos prontos, como a tela os observa.
///
/// A fonte é o banco, via `ValueObservation`, pela mesma razão de
/// `AnalysisQueueStateModel`: quem escreve é uma fila de fundo, e uma tela que
/// só lesse na abertura mostraria "quer que eu escreva?" ao lado de uma
/// resposta que já estava pronta havia dois segundos.
///
/// O dicionário inteiro mora em memória de propósito. `ready_draft` só tem
/// linha para mensagem que espera resposta — dezenas, não milhares —, e a
/// alternativa (uma consulta por linha desenhada) seria disco a cada quadro
/// da lista.
@MainActor
@Observable
public final class ReadyDraftsModel {
    /// Todos os rascunhos guardados, por `messageID`. Os descartados não
    /// entram: a linha continua no banco para a fila não os reescrever, mas
    /// para a tela eles não existem.
    public private(set) var drafts: [String: ReadyDraft] = [:]

    private let database: SyncDatabase
    private let store: ReadyDraftStore
    private var observationTask: Task<Void, Never>?

    public init(database: SyncDatabase) {
        self.database = database
        self.store = ReadyDraftStore(database: database)
        reload()
    }

    /// Idempotente, como as outras observações do app.
    public func start() {
        guard observationTask == nil else { return }
        let pool = database.pool
        observationTask = Task { [weak self] in
            do {
                let changes = ValueObservation.tracking { db in
                    try ReadyDraftRecord.fetchAll(db)
                }
                for try await registros in changes.values(in: pool) {
                    guard let self, !Task.isCancelled else { return }
                    self.drafts = Dictionary(
                        registros.compactMap { registro in
                            registro.draft.map { (registro.messageID, $0) }
                        },
                        uniquingKeysWith: { primeiro, _ in primeiro }
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    /// Os rascunhos destas mensagens — o que a Tarefa 3 passa ao `DayPlan`.
    ///
    /// **Não confere o hash**: `DayPlan.make` já recusa o rascunho que não
    /// case com a mensagem (`ReadyDraft.matches(_:)`), e conferir aqui exigiria
    /// carregar de novo os corpos que a lista já tem na mão.
    public func readyDrafts(for messageIDs: [String]) -> [String: ReadyDraft] {
        drafts.filter { messageIDs.contains($0.key) }
    }

    /// "Descartar" da linha do dashboard.
    ///
    /// Some da tela **e** trava a fila para aquela versão da mensagem. Sem a
    /// segunda metade, a observação acordaria a fila, ela veria uma mensagem
    /// que espera resposta e sem rascunho, e escreveria o mesmo texto de novo
    /// — o botão descartaria por dois segundos.
    public func discardReadyDraft(messageID: String) {
        drafts[messageID] = nil
        try? store.discard(messageID: messageID)
    }

    /// A leitura única da montagem — o primeiro quadro não pode esperar a
    /// observação acordar.
    public func reload() {
        drafts = (try? database.pool.read { db in
            try Dictionary(
                ReadyDraftRecord.fetchAll(db).compactMap { registro in
                    registro.draft.map { (registro.messageID, $0) }
                },
                uniquingKeysWith: { primeiro, _ in primeiro }
            )
        }) ?? [:]
    }
}
