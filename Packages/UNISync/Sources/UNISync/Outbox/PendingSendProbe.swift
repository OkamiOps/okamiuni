import Foundation
import GRDB
import UNICore

/// Há mensagem esperando para sair?
///
/// Existe por causa do "Instalar e reabrir": instalar uma versão nova troca o
/// bundle e reabre o app, e se isso acontecer com um envio a meio caminho a
/// pessoa perde a mensagem que ela acabou de mandar — sem aviso, porque o
/// `OutboxExecutor` morre junto com o processo.
///
/// A fila **sobrevive** ao fechar o app (ela é uma tabela, não memória), então
/// a mensagem não se perde de verdade: ela sai na abertura seguinte. Mas
/// "acabei de apertar Enviar e o app reiniciou" é o momento em que ninguém
/// quer descobrir isso, e esperar alguns segundos custa menos do que explicar.
///
/// É uma leitura SQLite síncrona, e por isso `nonisolated`: quem chama a põe
/// fora do ator principal (ver `SparkleUpdateEngine.aguardaFilaDeEnvio`).
public struct PendingSendProbe: Sendable {
    private let database: SyncDatabase

    public init(database: SyncDatabase) {
        self.database = database
    }

    /// Verdadeiro quando existe uma operação de **envio** pendente ou em
    /// execução na fila de saída.
    ///
    /// Só envio: uma triagem pendente (`setRead`, `move`) também está na fila,
    /// e também sai na abertura seguinte — mas ela é idempotente e ninguém a
    /// está olhando. Esperar por ela atrasaria toda instalação por nada.
    ///
    /// O JSON é **decodificado**, não procurado com `LIKE`: o corpo da
    /// mensagem viaja nesse mesmo campo, e um e-mail que mencione a palavra
    /// `"send"` entre aspas faria uma busca textual mentir.
    public func hasSendInFlight() -> Bool {
        let emVoo = [OutboxState.pendente.rawValue, OutboxState.executando.rawValue]
        let operacoes = (try? database.pool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT operationJSON FROM outbox WHERE state IN (?, ?)",
                arguments: StatementArguments(emVoo)
            )
        }) ?? []

        let decodificador = JSONDecoder()
        return operacoes.contains { json in
            guard let dados = json.data(using: .utf8),
                  let operacao = try? decodificador.decode(MailOperation.self, from: dados)
            else { return false }
            if case .send = operacao { return true }
            return false
        }
    }
}
