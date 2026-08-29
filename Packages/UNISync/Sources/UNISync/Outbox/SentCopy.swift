import Foundation
import UNICore

/// A mensagem que saiu, virada linha da caixa Enviadas.
///
/// **É projeção, como a da entrada**, e mora fora do executor pela mesma razão
/// que `TriageProjection` mora fora do `InitialLoader`: uma regra escrita
/// dentro do laço da fila não tem como ser testada sem banco nem rede, e a
/// próxima pessoa a precisar dela a copiaria em vez de a herdar.
///
/// ## Por que a coordenada do servidor é obrigatória
///
/// O id da linha **não** é inventado aqui: ele sai de `MessageIdentity`, a
/// partir de onde o servidor de fato guardou a cópia — o id da `messages.send`
/// no Gmail, o `APPENDUID` no IMAP. É o mesmo id que a sincronização daria à
/// mesma mensagem quando a trouxer da pasta de Enviadas, e é isso que faz o
/// `save` (upsert) escrever **por cima** em vez de criar uma segunda linha.
///
/// Com um id nosso — `conta:enviada:message-id`, por exemplo — a linha local e
/// a sincronizada seriam duas, e a pessoa veria cada mensagem que mandou duas
/// vezes na própria caixa. A chave natural é a do servidor.
enum SentCopy {
    /// A pasta e a mensagem a gravar. A pasta vem junto porque `message` tem
    /// chave estrangeira para ela, e no primeiro envio de uma conta IMAP a
    /// pasta de Enviadas pode ainda não estar no banco: ela nunca foi
    /// carregada se a conta é nova, e a transação inteira cairia.
    static func linhas(
        _ mensagem: OutgoingMessage,
        gravadaEm coordenada: MessageCoordinate,
        accountID: String,
        now: Date
    ) -> (folder: FolderRecord, message: Message) {
        let pasta: FolderRecord
        let id: String
        let serverID: String
        let uidValidity: Int64?

        switch coordenada {
        case .gmail(let servidor):
            pasta = FolderRecord.gmail(accountID: accountID)
            id = MessageIdentity.gmail(accountID: accountID, serverID: servidor)
            serverID = servidor
            uidValidity = nil
        case .imap(let nomeDaPasta, let geracao, let uid):
            pasta = FolderRecord(
                id: FolderRecord.id(accountID: accountID, serverName: nomeDaPasta),
                accountID: accountID, serverName: nomeDaPasta,
                role: .sent, displayName: nomeDaPasta
            )
            id = MessageIdentity.imap(
                accountID: accountID, folderID: pasta.id, uidValidity: geracao, uid: uid
            )
            serverID = String(uid)
            uidValidity = geracao
        }

        let corpo = paragrafos(mensagem.plainText)
        let nossa = Message(
            id: id, accountID: accountID,
            from: Contact(name: mensagem.from.name, address: mensagem.from.address),
            receivedAt: now,
            subject: mensagem.subject,
            // Sem corpo, a prévia é o assunto — a mesma saída da carga IMAP
            // quando o corpo ainda não desceu.
            snippet: corpo.first ?? mensagem.subject,
            body: corpo, tags: [], bucket: .sent,
            // Lida, sempre: você acabou de escrevê-la. Uma cópia da própria
            // mensagem chegando "não lida" faria um contador subir sem nada
            // novo ter chegado — a mesma razão pela qual o `APPEND` do IMAP
            // manda `\Seen`.
            isRead: true,
            summary: nil, detectedEvent: nil,
            // `to` e `cc`, e **não** a cópia oculta: `Bcc` fica de fora do que
            // se lê e do que "Responder a todos" semeia, que é o que a torna
            // oculta. `to` é também o que a linha da lista escreve na primeira
            // linha em Enviadas — ver `Message.listHeadline`.
            to: mensagem.to.map { Contact(name: $0.name, address: $0.address) },
            cc: mensagem.cc.map { Contact(name: $0.name, address: $0.address) },
            isFlagged: false,
            serverID: serverID, uidValidity: uidValidity
        )
        return (pasta, nossa)
    }

    /// O texto simples partido em parágrafos, que é como `Message.body` é
    /// modelado (e como o leitor os desenha, com 16 de respiro entre eles).
    ///
    /// Linha em branco separa parágrafo — o inverso exato de
    /// `ContextMenus.bodyText`, que os junta com uma linha em branco no meio.
    static func paragrafos(_ texto: String) -> [String] {
        texto.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
