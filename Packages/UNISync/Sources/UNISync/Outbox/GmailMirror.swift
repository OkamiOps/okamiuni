import Foundation
import UNICore

/// O espelho da triagem no Gmail — a coluna "Gmail" da tabela da spec.
///
/// | Caixa | O que vai para o servidor |
/// |---|---|
/// | Hoje | `+INBOX`, `-OkamiUNI/Depois` |
/// | Depois | `+OkamiUNI/Depois`, `-INBOX` (a INBOX sai junto para a mensagem não aparecer duas vezes no webmail) |
/// | Arquivado | `-INBOX`, `-OkamiUNI/Depois` |
/// | Lixeira | `messages.trash` (o endpoint próprio — `TRASH` não pode ser *posta* por `batchModify`) |
/// | Sinalizada | `STARRED` |
/// | Lida | `-UNREAD` |
///
/// Ator, e não struct, por causa de uma coisa só: o id do rótulo `Depois`.
/// Descobri-lo custa uma chamada, criá-lo custa outra, e as duas têm de
/// acontecer **uma vez** por conta — não uma vez por operação. O cache é estado
/// mutável compartilhado entre operações concorrentes, e ator é o que o torna
/// seguro sem cadeado à mão.
public actor GmailMirror: MailMirror {
    private let client: GmailClient
    private var laterLabelID: String?

    public init(client: GmailClient) {
        self.client = client
    }

    public func apply(_ operation: MailOperation, targets: [MessageCoordinate]) async throws {
        let ids = targets.compactMap { alvo -> String? in
            guard case .gmail(let serverID) = alvo else { return nil }
            return serverID
        }

        switch operation {
        case .setRead(let isRead, _):
            // Não existe rótulo `READ` no Gmail: lida é a **ausência** de
            // `UNREAD`. A regra é a mesma que `TriageProjection.isRead` lê na
            // entrada, agora escrita na saída.
            try await client.batchModify(
                ids: ids,
                addLabelIDs: isRead ? [] : ["UNREAD"],
                removeLabelIDs: isRead ? ["UNREAD"] : []
            )

        case .setFlagged(let isFlagged, _):
            try await client.batchModify(
                ids: ids,
                addLabelIDs: isFlagged ? ["STARRED"] : [],
                removeLabelIDs: isFlagged ? [] : ["STARRED"]
            )

        case .move(let bruto, _):
            guard let bucket = TriageBucket(rawValue: bruto) else {
                throw SyncError.resposta("Caixa de triagem desconhecida na fila: \(bruto).")
            }
            // Mover para a Lixeira é o endpoint próprio, e não uma label posta
            // à mão — a mesma rota do `delete` abaixo.
            guard bucket != .trash else {
                try await client.trash(ids: ids)
                return
            }
            // O id do rótulo só é pedido (e o rótulo só é criado) quando a
            // operação de fato precisa dele — arquivar não cria pasta nenhuma
            // em quem nunca usou Depois.
            let depois = try await idDoDepois(criandoSePreciso: bucket == .later)
            // Voltar para Hoje é o caminho por onde uma mensagem **sai** da
            // Lixeira ("restaurar"), e tirar `TRASH` por `batchModify` é
            // justamente o que a API não garante. `untrash` é o inverso
            // canônico do `trash`, e é inofensivo em quem nunca esteve lá.
            if bucket == .today { try await client.untrash(ids: ids) }
            try await client.batchModify(
                ids: ids,
                addLabelIDs: bucket == .later ? [depois].compactMap { $0 } : (bucket == .today ? ["INBOX"] : []),
                removeLabelIDs: removidos(para: bucket, depois: depois)
            )

        case .delete:
            try await client.trash(ids: ids)

        case .deletePermanently:
            try await client.batchDelete(ids: ids)

        case .emptyTrash:
            // Os ids **do servidor**, e não os nossos: a linha local já foi
            // apagada na transação do enfileiramento, e uma lixeira esvaziada
            // noutro cliente desde então não pode fazer esta operação falhar.
            // Perguntar ao servidor o que está na lixeira agora é a leitura
            // certa e a que torna a operação repetível.
            var restantes = try await client.messageIDs(query: "in:trash", pageToken: nil)
            var todos = restantes.ids
            while let proxima = restantes.nextPageToken {
                restantes = try await client.messageIDs(query: "in:trash", pageToken: proxima)
                todos.append(contentsOf: restantes.ids)
            }
            try await client.batchDelete(ids: todos)
        }
    }

    private func removidos(para bucket: TriageBucket, depois: String?) -> [String] {
        switch bucket {
        case .later: ["INBOX"]
        case .today: [depois].compactMap { $0 }
        case .archived: ["INBOX"] + [depois].compactMap { $0 }
        // A Lixeira nunca chega aqui: ela sai por `messages.trash`, acima.
        case .trash: []
        // `todos` é uma visão, não um estado — não há para onde mover.
        case .all: []
        }
    }

    /// O id de `OkamiUNI/Depois`, criando-o no primeiro uso.
    ///
    /// **Uma vez só, e provado por teste.** O cache responde de graça da segunda
    /// operação em diante; e mesmo com o cache frio (app reaberto, executor
    /// novo), a lista vem antes da criação — então um rótulo que já existe de
    /// uma instalação anterior é reaproveitado em vez de duplicado. O `409` da
    /// criação (`createLabel` devolvendo `nil`) é a terceira rede de segurança,
    /// para a corrida entre dois clientes da mesma conta.
    private func idDoDepois(criandoSePreciso criar: Bool) async throws -> String? {
        if let laterLabelID { return laterLabelID }
        let rotulos = try await client.labels()
        if let existente = TriageProjection.laterLabelID(in: rotulos) {
            laterLabelID = existente
            return existente
        }
        guard criar else { return nil }
        if let novo = try await client.createLabel(name: MirrorNames.later) {
            laterLabelID = novo
            return novo
        }
        // Criou e o servidor disse que já existia: relê e acha o id de verdade.
        let releitura = try await client.labels()
        laterLabelID = TriageProjection.laterLabelID(in: releitura)
        return laterLabelID
    }
}
