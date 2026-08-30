import Foundation
import GRDB
import UNICore

/// O estado de uma linha do `outbox`, como o executor (fora do escopo desta
/// tarefa) a encontra e a deixa.
public enum OutboxState: String, Codable, Sendable {
    case pendente
    case executando
    case falhou
    case feita
}

/// Uma operação de saída, tipada e serializável — o que a coluna
/// `operationJSON` do `outbox` carrega.
///
/// Um caso por operação do `MailCommandPort`, cada um só com os campos que
/// aquele caso precisa: `move` carrega a caixa de destino, os outros não.
/// Codable é **sintetizado**: todo campo associado (`Bool`, `String`,
/// `[String]`) já conforma, então o compilador escreve o `Codable` por nós —
/// é o que "JSON tipado" pede, sem uma segunda representação para manter em
/// dia.
public enum MailOperation: Codable, Sendable, Equatable {
    case setRead(isRead: Bool, messageIDs: [String])
    case setFlagged(isFlagged: Bool, messageIDs: [String])
    /// `bucket` é o `rawValue` de `TriageBucket`, não o tipo em si — evita
    /// dar a `TriageBucket` uma conformância `Codable` que ninguém mais no
    /// `UNICore` pede, só para este arquivo poder guardá-lo.
    case move(bucket: String, messageIDs: [String])
    /// Pasta/etiqueta escolhida no menu de contexto. `folderID` mantém a
    /// identidade local; `serverName` é o valor opaco que o provedor recebe.
    /// `mode` é o `rawValue` de `FolderPlacement` para a fila continuar
    /// autossuficiente ao reabrir o app.
    case placeInFolder(
        folderID: String, serverName: String, mode: String, messageIDs: [String]
    )
    /// Movimento entre localizações do Gmail. Caso próprio para manter
    /// compatíveis as operações `placeInFolder` que já estejam gravadas no
    /// outbox de uma instalação anterior.
    case moveGmailLabel(
        destinationLabelID: String, sourceLabelID: String, messageIDs: [String]
    )
    case delete(messageIDs: [String])
    case deletePermanently(messageIDs: [String])
    case emptyTrash
    /// Uma mensagem para sair.
    ///
    /// **O envio entra na fila como qualquer outra operação**, e não por um
    /// caminho próprio direto ao servidor. É o que lhe dá de graça as quatro
    /// coisas que a fila já tinha: funcionar sem rede (a mensagem sai quando
    /// ela volta), recuo com tremor, ordem, e a falha permanente aparecendo na
    /// janela com "tentar de novo" ao lado. Um "Enviar" que falasse com o
    /// servidor na hora perderia as quatro, e a primeira delas — apertar
    /// Enviar no avião — é a que a pessoa nota.
    ///
    /// A mensagem inteira viaja no JSON, e é por isso que `OutgoingMessage` é
    /// `Codable`: o app pode ser fechado com a mensagem ainda na fila, e o que
    /// sair depois tem de ser exatamente o que ela escreveu — inclusive o
    /// `Message-ID`, que é a identidade que torna o reenvio seguro.
    case send(message: OutgoingMessage)

    /// O rótulo do caso, para o log e para a leitura humana da fila — estável
    /// mesmo se a ordem dos casos do enum mudar, ao contrário de um índice
    /// numérico.
    var label: String {
        switch self {
        case .setRead: "setRead"
        case .setFlagged: "setFlagged"
        case .move: "move"
        case .placeInFolder: "placeInFolder"
        case .moveGmailLabel: "moveGmailLabel"
        case .delete: "delete"
        case .deletePermanently: "deletePermanently"
        case .emptyTrash: "emptyTrash"
        case .send: "send"
        }
    }

    /// Os ids que esta operação alcança. `emptyTrash` não tem ids próprios —
    /// ela é "a conta inteira" — e por isso devolve vazio.
    var messageIDs: [String] {
        switch self {
        case .setRead(_, let ids), .setFlagged(_, let ids),
             .move(_, let ids), .placeInFolder(_, _, _, let ids),
             .moveGmailLabel(_, _, let ids),
             .delete(let ids), .deletePermanently(let ids):
            ids
        // `emptyTrash` não tem ids próprios — ela é "a conta inteira". O envio
        // também não: a mensagem dele ainda não existe em lugar nenhum, e o
        // alvo dela são endereços, não linhas do banco.
        case .emptyTrash, .send:
            []
        }
    }
}

/// Uma linha do `outbox`.
public struct OutboxRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "outbox"

    public var id: String
    public var accountID: String
    public var operationJSON: String
    public var idempotencyKey: String
    public var attempts: Int
    public var nextAttemptAt: Date
    public var state: String
    public var createdAt: Date
    /// O `SyncError` que **parou** a fila nesta linha, em JSON — a coluna da
    /// v7. Nulo em tudo que não falhou.
    ///
    /// Ele existe porque a trava da fila mora no ator do executor e morre com
    /// o processo, enquanto a linha `falhou` fica no arquivo: sem a causa
    /// gravada, a abertura seguinte reencontra a fila parada e não teria o que
    /// dizer nem o que oferecer. Ver `OutboxExecutor.paradaGravada()`.
    public var lastError: String?

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }

    public init(
        id: String = UUID().uuidString, accountID: String, operation: MailOperation,
        nextAttemptAt: Date = Date(), createdAt: Date = Date()
    ) throws {
        self.id = id
        self.accountID = accountID
        let dados = try JSONEncoder().encode(operation)
        operationJSON = String(data: dados, encoding: .utf8) ?? "{}"
        idempotencyKey = Self.idempotencyKey()
        attempts = 0
        self.nextAttemptAt = nextAttemptAt
        state = OutboxState.pendente.rawValue
        self.createdAt = createdAt
        lastError = nil
    }

    public var operation: MailOperation? {
        guard let dados = operationJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MailOperation.self, from: dados)
    }

    /// **Única por operação, e não derivada do conteúdo dela.**
    ///
    /// A primeira versão desta chave era determinística — conta + tipo + ids —
    /// e o `UNIQUE` da coluna descartava, no enfileirar, toda operação com a
    /// mesma intenção de uma que já estava na fila. Isso resolvia um problema
    /// que ninguém tinha e criava dois que existiam de verdade:
    ///
    /// - **O terceiro clique sumia.** Marcar como lida, desmarcar, marcar de
    ///   novo: a terceira colidia com a primeira e era descartada em silêncio.
    ///   O servidor terminava com a mensagem **não lida** enquanto a tela
    ///   mostrava lida — divergência permanente, sem erro em lugar nenhum.
    /// - **`emptyTrash` colidia consigo mesma para sempre.** A chave dela não
    ///   tem ids (a operação é "a conta inteira"), então a segunda vez que
    ///   alguém esvaziasse a lixeira, em qualquer dia futuro, era engolida.
    ///
    /// A idempotência que importa nunca dependeu disto: ela é **por linha**
    /// (reivindicação atômica + recuperação na partida, em `OutboxExecutor`) e
    /// **por operação** (as do espelho põem ou tiram, nunca invertem; o mover
    /// do IMAP confere o `Message-ID` no destino antes de copiar). Quem tira a
    /// redundância da fila é a coalescência do `drain`, que junta o que dá
    /// para juntar sem apagar o que não dá.
    ///
    /// A coluna continua `UNIQUE` no esquema, e continua fazendo sentido: ela
    /// agora garante que duas linhas nunca compartilham identidade, que é o
    /// que um `UNIQUE` deve garantir.
    static func idempotencyKey() -> String { UUID().uuidString }
}
