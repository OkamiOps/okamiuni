import Foundation
import GRDB
import UNICore

/// A tabela `folder` posta em dia com o que o provedor acabou de listar.
///
/// **Uma função, dois provedores, quatro chamadores.** A carga inicial e o ciclo
/// incremental do IMAP e do Gmail fazem a mesma coisa: descobrem as pastas e
/// gravam. Sem um lugar só, "a pasta apagada no webmail some do app" seria
/// escrito quatro vezes e consertado uma.
enum FolderSync {
    /// Grava o que existe e apaga o que sumiu.
    ///
    /// ## Apagar é a metade que precisa de cuidado
    ///
    /// A linha de `folder` tem `message.folderID` apontando para ela com
    /// `ON DELETE CASCADE`: apagar a pasta leva junto as mensagens dela. É o
    /// comportamento certo — uma pasta que o dono apagou no webmail não pode
    /// continuar enchendo Arquivado no app —, e é justamente por isso que ele
    /// tem duas guardas:
    ///
    /// 1. **Uma listagem vazia não apaga nada.** Um `LIST` que volta sem linha
    ///    nenhuma é muito mais provavelmente um soluço do servidor (ou uma
    ///    resposta que o nosso analisador não entendeu) do que uma conta sem
    ///    pasta alguma — e a diferença entre as duas leituras é a caixa inteira
    ///    da pessoa.
    /// 2. **O que está `preservando` nunca sai.** É por onde a pseudo-pasta do
    ///    Gmail escapa: ela não é um rótulo, nenhuma listagem a devolve, e
    ///    apagá-la levaria **todas** as mensagens da conta junto.
    @discardableResult
    static func reconcile(
        _ db: Database, accountID: String,
        discovered: [FolderRecord], preservando: Set<String> = []
    ) throws -> Int {
        for pasta in discovered {
            try pasta.save(db)
        }
        guard !discovered.isEmpty else { return 0 }

        let vivas = Set(discovered.map(\.id)).union(preservando)
        let existentes = try FolderRecord
            .filter(Column("accountID") == accountID)
            .fetchAll(db)
        let sumidas = existentes.map(\.id).filter { !vivas.contains($0) }
        guard !sumidas.isEmpty else { return 0 }

        let marcadores = sumidas.map { _ in "?" }.joined(separator: ",")
        try db.execute(
            sql: "DELETE FROM folder WHERE id IN (\(marcadores))",
            arguments: StatementArguments(sumidas)
        )
        return sumidas.count
    }
}
